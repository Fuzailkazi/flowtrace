import Foundation

/// Reads what is running on this machine right now.
///
/// Everything here comes from process inspection and files the agents already
/// wrote — no permission, no injection, nothing attached to a running process.
/// `lsof` is called once for all processes rather than once per process, which
/// is the difference between 40ms and two seconds.
public struct LiveStateReader: Sendable {
    private let git: GitProbe
    private let claudeRoot: URL

    /// Anything written to more recently than this is actively working.
    private let workingWindow: TimeInterval = 120
    /// Beyond this, it is not waiting for you — it has been forgotten.
    private let waitingWindow: TimeInterval = 3600

    public init(git: GitProbe = GitProbe(), claudeRoot: URL? = nil) {
        self.git = git
        self.claudeRoot = claudeRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public func read() -> LiveState {
        LiveState(agents: readAgents(), servers: readServers(), capturedAt: Date())
    }

    // MARK: - Agents

    public func readAgents() -> [LiveAgent] {
        let processes = runningProcesses(named: ["claude", "codex"])
        var agents: [LiveAgent] = []
        // Several agents usually sit in the same handful of repositories, and
        // each resolution is a subprocess.
        var topLevels: [String: String] = [:]

        for process in processes {
            let agent: AgentName = process.command.contains("codex") ? .codex : .claudeCode
            let top: String?
            if let memo = topLevels[process.workingDirectory] {
                top = memo
            } else {
                top = git.topLevel(of: process.workingDirectory)
                if let top { topLevels[process.workingDirectory] = top }
            }
            let root = top ?? process.workingDirectory

            var live = LiveAgent(
                pid: process.pid,
                agent: agent,
                workingDirectory: process.workingDirectory,
                projectRoot: FilePathCanon.canonical(root),
                repositoryName: SessionImporter.folderLabel(for: root),
                state: .idle
            )

            if let transcript = newestTranscript(for: process.workingDirectory) {
                live.lastActivityAt = transcript.modifiedAt
                live.sessionId = (transcript.path as NSString)
                    .lastPathComponent
                    .replacingOccurrences(of: ".jsonl", with: "")

                let age = Date().timeIntervalSince(transcript.modifiedAt)
                live.state = age < workingWindow ? .working
                           : age < waitingWindow ? .waiting
                           : .idle

                if let prompt = lastPrompt(in: transcript.path) {
                    // A dragged file pastes its path as the prompt; the sentence
                    // after it is the part worth showing.
                    let stripped = AgentSession.withoutLeadingPath(prompt)
                    // Prompts are free text and routinely contain pasted keys.
                    let redacted = Redaction.redact(stripped.isEmpty ? prompt : stripped)
                    if !Redaction.isOnlyRedactions(redacted), !redacted.isEmpty {
                        live.lastPrompt = AgentSession.condense(redacted.text, limit: 90)
                    }
                }
            }

            agents.append(live)
        }

        // Several processes share one working directory — the CLI spawns helpers —
        // so collapse to one entry per place you are actually working.
        var seen: Set<String> = []
        return agents
            .sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
            .filter { seen.insert("\($0.agent.rawValue):\($0.workingDirectory)").inserted }
    }

    // MARK: - Servers

    public func readServers() -> [LiveServer] {
        // lsof exits non-zero whenever any selection matches nothing — with two
        // process names and only one of them running, a successful read reports
        // failure. The output is the signal here, not the status code.
        let result = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"])
        guard !result.stdout.isEmpty else { return [] }

        var servers: [LiveServer] = []
        var pid: Int32 = 0
        var command = ""
        var seenPorts: Set<String> = []

        for line in result.stdout.split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                guard let port = Self.port(from: value) else { continue }
                guard seenPorts.insert("\(pid):\(port)").inserted else { continue }
                servers.append(LiveServer(
                    pid: pid, port: port, processName: command
                ))
            default: break
            }
        }

        // A dev server is one you started from your own project. Everything
        // else listening on this machine is the operating system going about
        // its business, and listing it is noise.
        let cwds = workingDirectories(for: Set(servers.map(\.pid)))
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        return servers.compactMap { server in
            guard let cwd = cwds[server.pid], cwd.hasPrefix(home) else { return nil }
            var server = server
            server.workingDirectory = cwd
            let root = git.topLevel(of: cwd) ?? cwd
            server.projectRoot = FilePathCanon.canonical(root)
            server.projectName = SessionImporter.folderLabel(for: root)
            return server
        }
        .sorted { $0.port < $1.port }
    }

    public static func port(from address: String) -> UInt16? {
        guard let colon = address.lastIndex(of: ":") else { return nil }
        return UInt16(address[address.index(after: colon)...])
    }

    // MARK: - Process inspection

    struct RunningProcess {
        var pid: Int32
        var command: String
        var workingDirectory: String
    }

    /// Finds every running agent, then resolves their working directories.
    ///
    /// Two calls, not seventeen. `pgrep` is used for discovery because `lsof -c`
    /// only reported four of seventeen running agents — it cannot inspect every
    /// process — whereas `pgrep` lists them all and a batched `lsof -p` then
    /// resolves the directories it can.
    func runningProcesses(named names: [String]) -> [RunningProcess] {
        var byPid: [Int32: String] = [:]
        for name in names {
            let result = Shell.run("/usr/bin/pgrep", ["-x", name])
            for line in result.stdout.split(separator: "\n") {
                guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)) else { continue }
                byPid[pid] = name
            }
        }
        guard !byPid.isEmpty else { return [] }

        let directories = workingDirectories(for: Set(byPid.keys))
        return byPid.compactMap { pid, command in
            guard let cwd = directories[pid] else { return nil }
            return RunningProcess(pid: pid, command: command, workingDirectory: cwd)
        }
    }

    private func workingDirectories(for pids: Set<Int32>) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let result = Shell.run(
            "/usr/sbin/lsof",
            ["-a", "-d", "cwd", "-Fpn", "-p", pids.map(String.init).joined(separator: ",")]
        )
        guard !result.stdout.isEmpty else { return [:] }

        var directories: [Int32: String] = [:]
        var pid: Int32 = 0
        for line in result.stdout.split(separator: "\n") {
            let value = String(line.dropFirst())
            if line.first == "p" { pid = Int32(value) ?? 0 }
            if line.first == "n", value.hasPrefix("/") { directories[pid] = value }
        }
        return directories
    }

    // MARK: - Transcripts

    private struct Transcript {
        var path: String
        var modifiedAt: Date
    }

    private func newestTranscript(for workingDirectory: String) -> Transcript? {
        let slug = ClaudeCodeAdapter.projectSlug(for: workingDirectory)
        let directory = claudeRoot.appendingPathComponent(slug)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        return files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> Transcript? in
                guard let meta = FileMeta.stat(url.path) else { return nil }
                return Transcript(path: url.path, modifiedAt: meta.modifiedAt)
            }
            .max { $0.modifiedAt < $1.modifiedAt }
    }

    /// The last thing you typed, read from the tail of the transcript.
    ///
    /// Only the final stretch of the file is read. Transcripts run to megabytes
    /// and this refreshes continuously, so reading each one end-to-end cost two
    /// seconds across eleven agents — most of it spent parsing history nobody
    /// asked for.
    private func lastPrompt(in path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        // Widening until a prompt is found: a long agent turn can put megabytes of
        // tool output between you and the last thing you said, and 256KB reached
        // back past the prompt in most live sessions. Reading the whole file was
        // the alternative, and that cost two seconds across eleven agents.
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        var last: String?

        for tailBytes in [512 * 1024, 4 * 1024 * 1024] {
            try? handle.seek(toOffset: UInt64(max(0, size - tailBytes)))
            guard let data = try? handle.readToEnd() else { break }
            last = Self.lastPrompt(inTail: data)
            if last != nil || tailBytes >= size { break }
        }
        return last
    }

    /// Scans a tail of transcript for the last thing the user typed.
    ///
    /// The first line is very likely truncated mid-JSON; parsing simply fails on
    /// it and it is skipped, which is exactly the behaviour wanted.
    private static func lastPrompt(inTail data: Data) -> String? {
        var last: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let line = String(line)
            guard line.contains("\"type\":\"user\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["isSidechain"] as? Bool != true,
                  object["isMeta"] as? Bool != true,
                  let text = ClaudeCodeAdapter.userText(from: object["message"]),
                  AgentSession.isSubstantive(text)
            else { continue }
            last = text
        }
        return last
    }
}
