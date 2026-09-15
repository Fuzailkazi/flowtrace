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
    private let thresholds: ActivityThresholds
    private let codexRoot: URL?
    private let openCodeDatabase: URL?

    public init(
        git: GitProbe = GitProbe(),
        claudeRoot: URL? = nil,
        codexRoot: URL? = nil,
        openCodeDatabase: URL? = nil,
        thresholds: ActivityThresholds = .default
    ) {
        self.git = git
        self.claudeRoot = claudeRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        self.codexRoot = codexRoot
        self.openCodeDatabase = openCodeDatabase
        self.thresholds = thresholds
    }

    /// Where each agent's history lives. One per reading, so the Codex session
    /// directory is walked at most once and only when a Codex process exists.
    private func makeIndex() -> TranscriptIndex {
        TranscriptIndex(
            claudeRoot: claudeRoot, codexRoot: codexRoot, openCodeDatabase: openCodeDatabase
        )
    }

    /// What is running, and — for the agents whose transcripts may be read —
    /// what was last asked of each.
    ///
    /// `transcripts` is the permission, passed in rather than looked up. With
    /// `.none` this still reports every running agent and server: those come
    /// from `pgrep` and `lsof`, which open no file. What it will not do is read
    /// a single transcript, or even list the directory they live in, since the
    /// file names are session identifiers.
    public func read(transcripts: AgentSources = .all) -> LiveState {
        LiveState(
            agents: readAgents(transcripts: transcripts),
            servers: readServers(),
            capturedAt: Date()
        )
    }

    /// Why a census could not be taken. Reported rather than rounded down to
    /// zero: "nothing is running" and "I could not look" are different claims,
    /// and only one of them is ever true by accident.
    public struct CensusUnavailable: LocalizedError, Sendable {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    /// How much is running, without opening a single transcript.
    ///
    /// `readAgents()` answers the same question better, but it gets its answer
    /// by reading the files consent is about. This counts processes and
    /// listening sockets and stops there, so first run can say something true
    /// before the user has agreed to anything.
    ///
    /// Counts processes whether or not their working directory resolves, which
    /// `runningProcesses(named:)` drops — for a count, an agent whose cwd `lsof`
    /// cannot see is still an agent.
    public func readCensus() throws -> (agents: Int, servers: Int) {
        var pids = Set<Int32>()
        var asked = false
        var failure = "pgrep could not be run"

        for name in ["claude", "codex", "opencode"] {
            let result = Shell.run("/usr/bin/pgrep", ["-x", name])
            // 0 = matches, 1 = no matches; both are answers. Anything negative
            // is this process failing to ask the question at all.
            guard result.status >= 0 else {
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !stderr.isEmpty { failure = stderr }
                continue
            }
            asked = true
            for line in result.stdout.split(separator: "\n") {
                if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) { pids.insert(pid) }
            }
        }

        guard asked else { throw CensusUnavailable(reason: failure) }
        return (pids.count, readServers().count)
    }

    // MARK: - Agents

    public func readAgents(transcripts: AgentSources = .all) -> [LiveAgent] {
        let processes = runningProcesses(named: ["claude", "codex", "opencode"])
        let index = makeIndex()
        var agents: [LiveAgent] = []
        // Several agents usually sit in the same handful of repositories, and
        // each resolution is a subprocess.
        var places: [String: WorkPlace] = [:]

        for process in processes {
            let place: WorkPlace
            if let memo = places[process.workingDirectory] {
                place = memo
            } else {
                place = WorkPlace.resolve(
                    workingDirectory: process.workingDirectory,
                    repositoryRoot: git.topLevel(of: process.workingDirectory)
                )
                places[process.workingDirectory] = place
            }
            agents.append(agent(
                for: process, place: place, transcripts: transcripts, index: index
            ))
        }

        // Several processes share one working directory — the CLI spawns
        // helpers — so collapse to one entry per place you are actually
        // working. Keyed on the resolved place rather than the raw directory,
        // so an agent in `repo` and another in `repo/api` are one row for the
        // repository rather than two rows that look like two pieces of work.
        var seen: Set<String> = []
        return agents
            .sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
            .filter { seen.insert("\($0.agent.rawValue):\($0.projectRoot)").inserted }
    }

    /// Resolves one running process into what is known about it.
    ///
    /// Public so the permission can be tested without live processes. `root` is
    /// supplied rather than resolved here because the caller memoises git
    /// top-levels across processes.
    public func agent(
        for process: RunningProcess, root: String, transcripts: AgentSources
    ) -> LiveAgent {
        agent(
            for: process,
            place: WorkPlace.resolve(workingDirectory: process.workingDirectory, repositoryRoot: root),
            transcripts: transcripts,
            index: makeIndex()
        )
    }

    func agent(
        for process: RunningProcess,
        place: WorkPlace,
        transcripts: AgentSources,
        index: TranscriptIndex
    ) -> LiveAgent {
        let agent: AgentName
        if process.command.contains("codex") {
            agent = .codex
        } else if process.command.contains("opencode") {
            agent = .openCode
        } else {
            agent = .claudeCode
        }

        var live = LiveAgent(
            pid: process.pid,
            agent: agent,
            workingDirectory: process.workingDirectory,
            projectRoot: place.path,
            repositoryName: place.name,
            state: .quiet,
            place: place
        )

        guard transcripts.allows(agent) else {
            // Not allowed to look. Nothing is opened and the directory is
            // not even listed — its file names are session identifiers.
            live.transcriptHidden = true
            return live
        }

        // The repository root is used for the lookup whether or not the place
        // is one FlowTrace will show. Whether work is worth listing and where
        // its history lives are separate questions, and conflating them meant
        // an agent in a rejected place also lost its history.
        guard let entry = index.entry(
            for: agent,
            workingDirectory: process.workingDirectory,
            repositoryRoot: place.path
        ) else {
            // The process is running right now (pgrep found it) but nothing on
            // disk belongs to it. Claiming `.forgotten` would file a session
            // started ten seconds ago as days-old work; `.waiting` says
            // honestly: running, sitting there, activity unknown.
            live.state = .waiting
            live.activityIsKnown = false
            return live
        }

        live.lastActivityAt = entry.modifiedAt
        live.lastHumanActivityAt = entry.lastHumanAt
        live.sessionId = entry.sessionId
        live.state = thresholds.state(forAge: Date().timeIntervalSince(entry.modifiedAt))
        live.lastPrompt = entry.lastPrompt
        return live
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
            let place = WorkPlace.resolve(
                workingDirectory: cwd, repositoryRoot: git.topLevel(of: cwd)
            )
            // A server started outside any project has nowhere to be grouped,
            // and inventing a place called `/` for it helps nobody.
            guard place.isProject else { return nil }
            server.projectRoot = place.path
            server.projectName = place.name
            return server
        }
        .sorted { $0.port < $1.port }
    }

    public static func port(from address: String) -> UInt16? {
        guard let colon = address.lastIndex(of: ":") else { return nil }
        return UInt16(address[address.index(after: colon)...])
    }

    // MARK: - Process inspection

    public struct RunningProcess: Sendable {
        public var pid: Int32
        public var command: String
        public var workingDirectory: String

        public init(pid: Int32, command: String, workingDirectory: String) {
            self.pid = pid
            self.command = command
            self.workingDirectory = workingDirectory
        }
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
}
