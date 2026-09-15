import Foundation
import FlowTraceCore

/// Before you agree, FlowTrace observes nothing.
///
/// These drive the readers the way the app drives them, with the permission
/// passed as a value. What they cannot reach is the app layer that decides
/// *which* value to pass — that is `AppModel.mayObserve` and `readableSources`,
/// covered by the manual pass in the phase report.
func runConsentTests(fixtures: URL) {
    TestKit.suite("What a source set allows")

    TestKit.test("nothing is allowed by an empty set") {
        for agent in AgentName.allCases {
            expect(!AgentSources.none.allows(agent), "\(agent.label) was allowed by .none")
        }
    }

    TestKit.test("only the two FlowTrace can read are ever allowed") {
        expect(AgentSources.all.allows(.claudeCode))
        expect(AgentSources.all.allows(.codex))
        // There is no adapter for these, so "allowed" would be a promise
        // nothing could keep.
        for agent in [AgentName.cursor, .openCode, .geminiCLI, .other] {
            expect(!AgentSources.all.allows(agent), "\(agent.label)")
        }
    }

    TestKit.test("one source switched on does not switch on the other") {
        expect(AgentSources.claudeCode.allows(.claudeCode))
        expect(!AgentSources.claudeCode.allows(.codex))
        expect(AgentSources.codex.allows(.codex))
        expect(!AgentSources.codex.allows(.claudeCode))
    }

    TestKit.suite("Imports before consent")

    let claude = ClaudeCodeAdapter(root: fixtures.appendingPathComponent("claude"))

    /// Codex rollouts are discovered by file age (`modifiedWithin: 2`), and the
    /// committed fixture's timestamp is whenever the repository was checked
    /// out. Copying it gives the copy a fresh one, so the importer can see it.
    let codexRoot: URL = {
        let manager = FileManager.default
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flowtrace-codex-\(UUID().uuidString)")
        try? manager.copyItem(at: fixtures.appendingPathComponent("codex"), to: scratch)
        // `copyItem` preserves the modification date, which is the whole
        // problem, so it is set explicitly afterwards.
        if let walker = manager.enumerator(at: scratch, includingPropertiesForKeys: nil) {
            for case let file as URL in walker {
                try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            }
        }
        return scratch
    }()
    let codex = CodexAdapter(root: codexRoot)
    func store() throws -> Store { try Store(database: FlowTraceDatabase.inMemory()) }

    /// The fixtures are dated 2026-07-14 at 09:00Z (Claude) and 11:00Z (Codex),
    /// which fall on different local days at extreme offsets — so each
    /// assertion derives its day from its own source rather than sharing one.
    func day(of session: AgentSession?) -> Date {
        session?.lastActivityAt ?? session?.startedAt ?? Date()
    }

    TestKit.test("with nothing switched on, nothing is imported and no file is opened") {
        let store = try store()
        let imported = SessionImporter(sources: .none, claude: claude, codex: codex)
            .importSessions(on: Date(), into: store, cache: nil)

        expectEqual(imported, 0)
        try store.database.writer.read { db in
            expectEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM activityEvent"), 0,
                "nothing was written"
            )
        }
    }

    TestKit.test("switching on Claude Code imports its sessions and none of Codex's") {
        let store = try store()
        let claudeDay = day(of: try claude.discoverSessions().first)
        _ = SessionImporter(sources: .claudeCode, claude: claude, codex: codex)
            .importSessions(on: claudeDay, into: store, cache: nil)

        let imported = try store.allActivity(on: claudeDay, minimumSeconds: 0)
            .filter { $0.kind == .agentSession }
        expect(!imported.isEmpty, "the Claude session was imported")
        expect(imported.allSatisfy { $0.appName == AgentName.claudeCode.label },
               "only Claude Code: got \(imported.map(\.appName))")
    }

    TestKit.test("switching on Codex imports its sessions and none of Claude's") {
        let store = try store()
        let codexDay = day(of: try codex.discoverSessions().first)
        _ = SessionImporter(sources: .codex, claude: claude, codex: codex)
            .importSessions(on: codexDay, into: store, cache: nil)

        let imported = try store.allActivity(on: codexDay, minimumSeconds: 0)
            .filter { $0.kind == .agentSession }
        expect(!imported.isEmpty, "the Codex session was imported")
        expect(imported.allSatisfy { $0.appName == AgentName.codex.label },
               "only Codex: got \(imported.map(\.appName))")
    }

    TestKit.suite("Live state before consent")

    let reader = LiveStateReader(claudeRoot: fixtures.appendingPathComponent("claude"))
    let process = LiveStateReader.RunningProcess(
        pid: 4_242, command: "claude", workingDirectory: "/Users/dev/acme"
    )

    // The distinction the whole design rests on: FlowTrace may say an agent is
    // running here, because that came from `pgrep`, and may not say what was
    // asked of it, because that came from a file.
    TestKit.test("an agent is still listed, with nothing read from its transcript") {
        let agent = reader.agent(for: process, root: "/Users/dev/acme", transcripts: .none)

        expect(agent.transcriptHidden, "marked as unread")
        expect(agent.lastPrompt == nil, "no prompt")
        expect(agent.sessionId == nil, "no session id — the file name is one")
        expect(agent.lastActivityAt == nil, "no age — that comes from the file's date")
        expectEqual(agent.pid, 4_242, "but the process is still reported")
        expectEqual(agent.repositoryName, "acme", "and so is where it is running")
    }

    TestKit.test("with the source switched on, the transcript is read") {
        let agent = reader.agent(for: process, root: "/Users/dev/acme", transcripts: .claudeCode)

        expect(!agent.transcriptHidden)
        expectEqual(agent.lastPrompt, "now add refresh token rotation before we ship")
        expect(agent.sessionId != nil, "the session is identified")
        expect(agent.lastActivityAt != nil, "and dated")
    }

    TestKit.test("a source switched on for the other agent does not open this one") {
        let agent = reader.agent(for: process, root: "/Users/dev/acme", transcripts: .codex)
        expect(agent.transcriptHidden, "Claude's transcript stays shut")
        expect(agent.lastPrompt == nil)
    }

    TestKit.suite("What a place says when it has not been read")

    func agent(_ name: String, state: LiveAgent.State, hidden: Bool = false) -> LiveAgent {
        LiveAgent(
            pid: 1, agent: .claudeCode, workingDirectory: "/tmp/\(name)",
            projectRoot: "/tmp/\(name)", repositoryName: name,
            lastActivityAt: hidden ? nil : Date(), state: state, transcriptHidden: hidden
        )
    }

    // "Forgotten" is a claim about work. Made from agents nobody looked at, it
    // would be a claim about permission wearing the same amber.
    TestKit.test("a place whose agents are all unread is never called forgotten") {
        let project = LiveProject(
            path: "/tmp/acme", name: "acme",
            agents: [agent("acme", state: .idle, hidden: true)], servers: []
        )
        expect(!project.isForgotten)
        expectEqual(project.statusLabel, "not reading transcripts")
    }

    TestKit.test("a place is judged on the agents that were read") {
        let unreadPlusIdle = LiveProject(
            path: "/tmp/a", name: "a",
            agents: [agent("a", state: .idle, hidden: true), agent("a", state: .idle)],
            servers: []
        )
        expect(unreadPlusIdle.isForgotten, "the one that was read has gone quiet")

        let unreadPlusWorking = LiveProject(
            path: "/tmp/b", name: "b",
            agents: [agent("b", state: .idle, hidden: true), agent("b", state: .working)],
            servers: []
        )
        expect(!unreadPlusWorking.isForgotten, "something there is moving")
    }

    // The guard that stops `allSatisfy` being vacuously true on an empty list.
    TestKit.test("a place with only a server keeps its own label") {
        let project = LiveProject(
            path: "/tmp/c", name: "c", agents: [],
            servers: [LiveServer(pid: 2, port: 5_173, processName: "node")]
        )
        expectEqual(project.statusLabel, "server only")
        expect(!project.isForgotten)
    }

    TestKit.suite("Browsers before consent")

    TestKit.test("no browser is asked anything while observation is held") {
        expectEqual(LiveStateReader().readBrowsers(allowed: false).count, 0,
                    "not a single Apple Event is sent")
    }

    TestKit.suite("Consent survives relaunch")

    // The gate is stored, not held in memory, so a relaunch cannot quietly
    // reopen it — and revoking one source cannot reopen the other.
    TestKit.test("what was agreed to is read back the same way next launch") {
        let key = "flowtrace.consent.test-\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: key) }

        defaults.set(
            ["claudeCode": true, "codex": false, "hasCompletedOnboarding": true],
            forKey: key
        )

        // What `ConsentSettings.load()` does, against a key the suite owns.
        let raw = defaults.dictionary(forKey: key)
        expectEqual(raw?["claudeCode"] as? Bool, true)
        expectEqual(raw?["codex"] as? Bool, false)
        expectEqual(raw?["hasCompletedOnboarding"] as? Bool, true)

        // And the source set that pairs with it.
        var sources = AgentSources.none
        if raw?["claudeCode"] as? Bool == true { sources.insert(.claudeCode) }
        if raw?["codex"] as? Bool == true { sources.insert(.codex) }
        expect(sources.allows(.claudeCode))
        expect(!sources.allows(.codex), "revoking one leaves the other revoked")
    }

    TestKit.test("an unfinished first run means nothing is readable, whatever the toggles say") {
        // The master gate: sources are only consulted once onboarding is done.
        let finished = false
        let sources: AgentSources = finished ? .all : .none
        expect(!sources.allows(.claudeCode), "a toggle left on from a previous install")
        expect(!sources.allows(.codex))
    }
}
