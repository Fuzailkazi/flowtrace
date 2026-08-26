import Foundation
import FlowTraceCore

func runActivityTests() {
    TestKit.suite("The day — coalescing")

    func store() throws -> Store { try Store(database: FlowTraceDatabase.inMemory()) }

    func event(
        _ app: String, target: String? = nil, at minutes: Int, kind: ActivityKind = .app
    ) -> ActivityEvent {
        ActivityEvent(
            kind: kind,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(minutes) * 60),
            appName: app, target: target
        )
    }

    // Forty alt-tabs must not become forty lines. This is the single rule that
    // decides whether a day is readable.
    TestKit.test("staying in the same place keeps one span, not many") {
        let store = try store()
        for minute in 0..<10 {
            try store.beginActivity(event("VS Code", target: "flowtrace", at: minute))
        }
        let day = try store.activity(on: Date(timeIntervalSince1970: 1_700_000_000),
                                    minimumSeconds: 0)
        expectEqual(day.count, 1, "spans")
        expectEqual(day.first?.appName, "VS Code")
    }

    TestKit.test("switching apps closes the previous span at the moment you left") {
        let store = try store()
        try store.beginActivity(event("VS Code", target: "flowtrace", at: 0))
        try store.beginActivity(event("Chrome", target: "pencil.com", at: 30))

        let day = try store.activity(on: Date(timeIntervalSince1970: 1_700_000_000),
                                     minimumSeconds: 0)
        expectEqual(day.count, 2, "spans")
        let first = try unwrap(day.first)
        expectNotNil(first.endedAt, "first span should be closed")
        expectEqual(first.duration, 1800, "30 minutes")
        expect(try unwrap(day.last).isOpen, "the current span stays open")
    }

    // Nipping to Slack and back is one sitting, not three.
    TestKit.test("returning within a few minutes resumes the span rather than splitting it") {
        let store = try store()
        try store.beginActivity(event("VS Code", target: "flowtrace", at: 0))
        try store.beginActivity(event("Slack", at: 10))
        try store.beginActivity(event("VS Code", target: "flowtrace", at: 12))

        let day = try store.activity(on: Date(timeIntervalSince1970: 1_700_000_000),
                                     minimumSeconds: 0)
        let vsCode = day.filter { $0.appName == "VS Code" }
        expectEqual(vsCode.count, 1, "VS Code should appear once")
        expect(try unwrap(vsCode.first).isOpen, "and be the open span again")
    }

    TestKit.test("the same app looking at something different is a new line") {
        let store = try store()
        try store.beginActivity(event("Chrome", target: "pencil.com", at: 0, kind: .browserTab))
        try store.beginActivity(event("Chrome", target: "stripe.com", at: 5, kind: .browserTab))

        let day = try store.activity(on: Date(timeIntervalSince1970: 1_700_000_000),
                                     minimumSeconds: 0)
        expectEqual(day.count, 2, "different pages are different entries")
    }

    TestKit.suite("The day — reading and annotating")

    TestKit.test("a glance is not something you were doing") {
        let store = try store()
        try store.beginActivity(event("Finder", at: 0))
        try store.beginActivity(event("VS Code", target: "flowtrace", at: 1))

        // Finder got 60 seconds; with a 5-minute floor it shouldn't be listed.
        let filtered = try store.activity(on: Date(timeIntervalSince1970: 1_700_000_000),
                                          minimumSeconds: 300)
        expect(!filtered.contains { $0.appName == "Finder" }, "brief glances are dropped")
    }

    // If you wrote about it, it mattered — regardless of how long it lasted.
    TestKit.test("anything you explained is kept however brief") {
        let store = try store()
        let brief = try store.beginActivity(event("Finder", at: 0))
        try store.beginActivity(event("VS Code", at: 1))
        _ = try store.annotate(activityId: brief.id, note: "grabbing the logo file")

        let filtered = try store.activity(on: Date(timeIntervalSince1970: 1_700_000_000),
                                          minimumSeconds: 300)
        expect(filtered.contains { $0.appName == "Finder" }, "an annotated glance is kept")
    }

    TestKit.test("unexplained is the count the header shows") {
        let store = try store()
        let a = try store.beginActivity(event("VS Code", target: "flowtrace", at: 0))
        try store.beginActivity(event("Chrome", target: "pencil.com", at: 30))

        let day = Date(timeIntervalSince1970: 1_700_000_000)
        expectEqual(try store.activity(on: day, minimumSeconds: 0).filter(\.isUnexplained).count, 2)

        _ = try store.annotate(activityId: a.id, note: "rebuilding the capture layer")
        expectEqual(try store.activity(on: day, minimumSeconds: 0).filter(\.isUnexplained).count, 1)
    }

    TestKit.test("an empty note clears the reason rather than storing blankness") {
        let store = try store()
        let e = try store.beginActivity(event("VS Code", at: 0))
        _ = try store.annotate(activityId: e.id, note: "something")
        let cleared = try unwrap(try store.annotate(activityId: e.id, note: "   "))
        expectNil(cleared.note, "note")
        expect(cleared.isUnexplained)
    }

    // The delete control that makes ambient capture liveable.
    TestKit.test("forgetting a day removes it entirely") {
        let store = try store()
        try store.beginActivity(event("VS Code", at: 0))
        try store.beginActivity(event("Chrome", at: 30))

        let day = Date(timeIntervalSince1970: 1_700_000_000)
        expect(try store.activity(on: day, minimumSeconds: 0).count > 0)
        try store.deleteActivity(on: day)
        expectEqual(try store.activity(on: day, minimumSeconds: 0).count, 0, "after forgetting")
    }

    TestKit.test("durations read the way people say them") {
        var e = event("VS Code", at: 0)
        e.endedAt = e.startedAt.addingTimeInterval(3840)
        expectEqual(e.durationLabel, "1h 04m")
        e.endedAt = e.startedAt.addingTimeInterval(720)
        expectEqual(e.durationLabel, "12m")
        e.endedAt = e.startedAt.addingTimeInterval(20)
        expectEqual(e.durationLabel, "under a minute")
    }
}

func runSessionImportTests() {
    TestKit.suite("Sessions on the day")

    // A session resumed across a week has a first timestamp days before its last.
    // Rendering that as a 181-hour span — which it did — is nonsense on a timeline.
    TestKit.test("a session is a point in time, not a span across days") {
        var event = ActivityEvent(
            kind: .agentSession,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appName: "Claude Code",
            metadata: ["messages": "14"]
        )
        event.endedAt = event.startedAt
        expectEqual(event.durationLabel, "14 messages", "size is what was said")
    }

    TestKit.test("one message reads as one message") {
        var event = ActivityEvent(
            kind: .agentSession, startedAt: Date(), appName: "Codex",
            metadata: ["messages": "1"]
        )
        event.endedAt = event.startedAt
        expectEqual(event.durationLabel, "1 message")
    }

    // The home directory's last path component is the user's short name, and
    // labelling a session "fu2ail" tells them nothing about where they were.
    TestKit.test("the home directory is shown as ~") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        expectEqual(SessionImporter.folderLabel(for: home), "~")
        expectEqual(SessionImporter.folderLabel(for: "/Users/dev/code/acme"), "acme")
    }

    TestKit.test("re-importing the same session updates it rather than duplicating") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        let moment = Date(timeIntervalSince1970: 1_700_000_000)

        func session(about: String) -> ActivityEvent {
            var e = ActivityEvent(
                kind: .agentSession, startedAt: moment, appName: "Claude Code",
                target: "acme", metadata: ["about": about],
                externalId: "claude-code:abc123"
            )
            e.endedAt = moment
            return e
        }

        _ = try store.upsertImportedActivity(session(about: "First title"))
        _ = try store.upsertImportedActivity(session(about: "Revised title"))

        let day = try store.activity(on: moment, minimumSeconds: 0)
        expectEqual(day.count, 1, "one session, imported twice")
        expectEqual(day.first?.metadata["about"], "Revised title", "latest wins")
    }

    // The machine may revise what it observed; what you wrote is yours.
    TestKit.test("re-importing never overwrites your own note") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        var event = ActivityEvent(
            kind: .agentSession, startedAt: moment, appName: "Claude Code",
            target: "acme", externalId: "claude-code:xyz"
        )
        event.endedAt = moment

        let stored = try store.upsertImportedActivity(event)
        _ = try store.annotate(activityId: stored.id, note: "figuring out the redesign")
        _ = try store.upsertImportedActivity(event)

        let day = try store.activity(on: moment, minimumSeconds: 0)
        expectEqual(day.first?.note, "figuring out the redesign", "the note survives")
    }
}

func runLiveProjectTests() {
    TestKit.suite("Now — grouped by place")

    func agent(
        _ name: String, root: String, state: LiveAgent.State = .idle, minutesAgo: Double = 60
    ) -> LiveAgent {
        LiveAgent(
            pid: Int32.random(in: 1000...9999),
            agent: .claudeCode,
            workingDirectory: root,
            projectRoot: root,
            repositoryName: name,
            lastActivityAt: Date().addingTimeInterval(-minutesAgo * 60),
            state: state
        )
    }

    func server(_ port: UInt16, root: String, name: String) -> LiveServer {
        LiveServer(
            pid: Int32.random(in: 1000...9999), port: port, processName: "node",
            workingDirectory: root, projectRoot: root, projectName: name
        )
    }

    // The first version listed agents and servers separately, which hid that one
    // project could have an abandoned agent *and* a server still holding a port.
    TestKit.test("an agent and a server in one place become one entry") {
        let state = LiveState(
            agents: [agent("tulu", root: "/p/tulu")],
            servers: [server(3000, root: "/p/tulu", name: "tulu")]
        )
        let projects = state.projects()
        expectEqual(projects.count, 1, "one place")
        expectEqual(projects.first?.agents.count, 1)
        expectEqual(projects.first?.servers.count, 1)
    }

    // A server started in tulu/frontend belongs to tulu.
    TestKit.test("subdirectories fold into the repository root") {
        var sub = server(5173, root: "/p/tulu/frontend", name: "tulu")
        sub.projectRoot = "/p/tulu"
        let state = LiveState(agents: [agent("tulu", root: "/p/tulu")], servers: [sub])
        expectEqual(state.projects().count, 1, "still one place")
    }

    TestKit.test("what is moving sorts above what is forgotten") {
        let state = LiveState(agents: [
            agent("stale", root: "/p/stale", state: .idle, minutesAgo: 5760),
            agent("live", root: "/p/live", state: .working, minutesAgo: 1),
        ])
        expectEqual(state.projects().first?.name, "live", "active first")
    }

    // The case worth surfacing: quiet, but still running and still costing you.
    TestKit.test("a place whose agents have all gone quiet is forgotten") {
        let forgotten = LiveState(agents: [agent("old", root: "/p/old", state: .idle)])
        expect(try unwrap(forgotten.projects().first).isForgotten)

        let busy = LiveState(agents: [agent("new", root: "/p/new", state: .working)])
        expect(!(try unwrap(busy.projects().first).isForgotten))
    }

    TestKit.test("a project carries the note you wrote for it") {
        let note = ProjectNote(
            repositoryPath: "/p/tulu", repositoryName: "tulu",
            building: "genz landing page for the loom video"
        )
        let state = LiveState(agents: [agent("tulu", root: "/p/tulu")])
        let projects = state.projects(notes: [note.repositoryPath: note])
        expectEqual(projects.first?.note?.building, "genz landing page for the loom video")
    }

    TestKit.test("a port is read off an lsof address, IPv6 included") {
        expectEqual(LiveStateReader.port(from: "127.0.0.1:3000"), 3000)
        expectEqual(LiveStateReader.port(from: "*:8080"), 8080)
        expectEqual(LiveStateReader.port(from: "[::1]:5432"), 5432)
    }
}
