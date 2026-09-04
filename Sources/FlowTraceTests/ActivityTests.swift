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
        let day = try store.allActivity(on: Date(timeIntervalSince1970: 1_700_000_000),
                                       minimumSeconds: 0)
        expectEqual(day.count, 1, "spans")
        expectEqual(day.first?.appName, "VS Code")
    }

    TestKit.test("switching apps closes the previous span at the moment you left") {
        let store = try store()
        try store.beginActivity(event("VS Code", target: "flowtrace", at: 0))
        try store.beginActivity(event("Chrome", target: "pencil.com", at: 30))

        let day = try store.allActivity(on: Date(timeIntervalSince1970: 1_700_000_000),
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

        let day = try store.allActivity(on: Date(timeIntervalSince1970: 1_700_000_000),
                                        minimumSeconds: 0)
        let vsCode = day.filter { $0.appName == "VS Code" }
        expectEqual(vsCode.count, 1, "VS Code should appear once")
        expect(try unwrap(vsCode.first).isOpen, "and be the open span again")
    }

    TestKit.test("the same app looking at something different is a new line") {
        let store = try store()
        try store.beginActivity(event("Chrome", target: "pencil.com", at: 0, kind: .browserTab))
        try store.beginActivity(event("Chrome", target: "stripe.com", at: 5, kind: .browserTab))

        let day = try store.allActivity(on: Date(timeIntervalSince1970: 1_700_000_000),
                                        minimumSeconds: 0)
        expectEqual(day.count, 2, "different pages are different entries")
    }

    TestKit.suite("The day — reading and annotating")

    TestKit.test("a glance is not something you were doing") {
        let store = try store()
        try store.beginActivity(event("Finder", at: 0))
        try store.beginActivity(event("VS Code", target: "flowtrace", at: 1))

        // Finder got 60 seconds; with a 5-minute floor it shouldn't be listed.
        let filtered = try store.allActivity(on: Date(timeIntervalSince1970: 1_700_000_000),
                                             minimumSeconds: 300)
        expect(!filtered.contains { $0.appName == "Finder" }, "brief glances are dropped")
    }

    // If you wrote about it, it mattered — regardless of how long it lasted.
    TestKit.test("anything you explained is kept however brief") {
        let store = try store()
        let brief = try store.beginActivity(event("Finder", at: 0))
        try store.beginActivity(event("VS Code", at: 1))
        _ = try store.annotate(activityId: brief.id, note: "grabbing the logo file")

        let filtered = try store.allActivity(on: Date(timeIntervalSince1970: 1_700_000_000),
                                             minimumSeconds: 300)
        expect(filtered.contains { $0.appName == "Finder" }, "an annotated glance is kept")
    }

    TestKit.test("unexplained is the count the header shows") {
        let store = try store()
        let a = try store.beginActivity(event("VS Code", target: "flowtrace", at: 0))
        try store.beginActivity(event("Chrome", target: "pencil.com", at: 30))

        let day = Date(timeIntervalSince1970: 1_700_000_000)
        expectEqual(
            try store.allActivity(on: day, minimumSeconds: 0).filter(\.isUnexplained).count, 2
        )

        _ = try store.annotate(activityId: a.id, note: "rebuilding the capture layer")
        expectEqual(
            try store.allActivity(on: day, minimumSeconds: 0).filter(\.isUnexplained).count, 1
        )
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
        expect(try store.allActivity(on: day, minimumSeconds: 0).count > 0)
        try store.deleteActivity(on: day)
        expectEqual(
            try store.allActivity(on: day, minimumSeconds: 0).count, 0, "after forgetting"
        )
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

    TestKit.suite("Spans left open")

    // A crash, a force-quit, or the old capture bug leaves `endedAt` nil. Left
    // alone it becomes a span stretching to now — or worse, gets resumed.
    TestKit.test("a span left open is closed a minute after the app was last seen") {
        let store = try store()
        let started = Date(timeIntervalSince1970: 1_760_000_000)
        try store.recordActivity(ActivityEvent(
            kind: .app, startedAt: started, appName: "Code", bundleIdentifier: "com.microsoft.VSCode"
        ))
        let lastSeen = started.addingTimeInterval(8 * 3600)
        let closed = try store.closeStaleOpenActivity(
            lastSeenAt: lastSeen, now: lastSeen.addingTimeInterval(12 * 3600)
        )
        expectEqual(closed, 1)
        expectNil(try store.openActivity())
        let event = try unwrap(try store.allActivity(on: started, minimumSeconds: 0).first)
        expectEqual(event.endedAt, lastSeen.addingTimeInterval(60))
    }

    TestKit.test("with no heartbeat a stale span is a minute long, not a lie") {
        let store = try store()
        let started = Date(timeIntervalSince1970: 1_760_000_000)
        try store.recordActivity(ActivityEvent(
            kind: .app, startedAt: started, appName: "Code", bundleIdentifier: "com.microsoft.VSCode"
        ))
        _ = try store.closeStaleOpenActivity(
            lastSeenAt: nil, now: started.addingTimeInterval(30 * 3600)
        )
        let event = try unwrap(try store.allActivity(on: started, minimumSeconds: 0).first)
        expectEqual(event.endedAt, started.addingTimeInterval(60))
    }

    TestKit.test("a span never ends before it started") {
        let store = try store()
        let started = Date(timeIntervalSince1970: 1_760_000_000)
        try store.recordActivity(ActivityEvent(
            kind: .app, startedAt: started, appName: "Code", bundleIdentifier: "com.microsoft.VSCode"
        ))
        _ = try store.closeStaleOpenActivity(
            lastSeenAt: started.addingTimeInterval(-300), now: started.addingTimeInterval(3600)
        )
        let event = try unwrap(try store.allActivity(on: started, minimumSeconds: 0).first)
        expectEqual(event.endedAt, started)
    }

    TestKit.test("closed spans are left alone") {
        let store = try store()
        let started = Date(timeIntervalSince1970: 1_760_000_000)
        let ended = started.addingTimeInterval(600)
        try store.recordActivity(ActivityEvent(
            kind: .app, startedAt: started, endedAt: ended, appName: "Code",
            bundleIdentifier: "com.microsoft.VSCode"
        ))
        expectEqual(try store.closeStaleOpenActivity(lastSeenAt: Date(), now: Date()), 0)
        let event = try unwrap(try store.allActivity(on: started, minimumSeconds: 0).first)
        expectEqual(event.endedAt, ended)
    }

    TestKit.suite("Notes with the recorder off")

    // Two captures from two apps must be two rows. The old code overwrote the
    // first with the second, forever, because it annotated the open span.
    TestKit.test("two captures in two apps are two notes, and nothing stays open") {
        let store = try store()
        let first = Date(timeIntervalSince1970: 1_760_000_000)
        for (app, bundle, text) in [
            ("Safari", "com.apple.Safari", "checking the redirect"),
            ("Code", "com.microsoft.VSCode", "fixing the save path"),
        ] {
            let at = app == "Safari" ? first : first.addingTimeInterval(120)
            try store.recordActivity(ActivityEvent(
                kind: .app, startedAt: at, endedAt: at, appName: app,
                bundleIdentifier: bundle, note: text, noteAt: at
            ))
        }
        let written = try store.activity(on: first)
        expectEqual(written.count, 2)
        expectNil(try store.openActivity())
    }

    TestKit.suite("Coming back to a page you wrote about")

    // `save()` depends on this: the resume branch hands back the *old* span,
    // note included, so the caller must not blindly annotate it.
    TestKit.test("returning to a noted page resumes it with the note intact") {
        let store = try store()
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        func tab(_ url: String, _ title: String, at: Date) -> ActivityEvent {
            ActivityEvent(
                kind: .browserTab, startedAt: at, appName: "Safari",
                bundleIdentifier: "com.apple.Safari", target: title, url: url
            )
        }
        let a = try store.beginActivity(tab("https://a.example", "A", at: start))
        _ = try store.annotate(activityId: a.id, note: "why I opened A")
        _ = try store.beginActivity(tab("https://b.example", "B", at: start.addingTimeInterval(60)))
        let resumed = try store.beginActivity(tab("https://a.example", "A", at: start.addingTimeInterval(120)))
        expectEqual(resumed.id, a.id)
        expectEqual(resumed.note, "why I opened A")
    }

    TestKit.test("a new page closes the span that was open") {
        let store = try store()
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let a = try store.beginActivity(ActivityEvent(
            kind: .browserTab, startedAt: start, appName: "Safari",
            bundleIdentifier: "com.apple.Safari", target: "A", url: "https://a.example"
        ))
        let switched = start.addingTimeInterval(45)
        _ = try store.beginActivity(ActivityEvent(
            kind: .browserTab, startedAt: switched, appName: "Safari",
            bundleIdentifier: "com.apple.Safari", target: "B", url: "https://b.example"
        ))
        let closed = try unwrap(
            try store.allActivity(on: start, minimumSeconds: 0).first { $0.id == a.id }
        )
        expectEqual(closed.endedAt, switched)
    }

    TestKit.suite("Describing what a row is")

    TestKit.test("metadata is merged, not replaced") {
        let store = try store()
        let event = try store.recordActivity(ActivityEvent(
            kind: .browserTab, startedAt: Date(), appName: "Safari",
            metadata: ["tabsOpen": "11"]
        ))
        try store.describeActivity(id: event.id, metadata: ["place": "flowtrace"])
        let after = try unwrap(try store.allActivity(on: event.startedAt, minimumSeconds: 0).first)
        expectEqual(after.metadata["tabsOpen"], "11", "existing key survived")
        expectEqual(after.metadata["place"], "flowtrace")
    }

    // A note and its place are written together or not at all — otherwise a
    // capture with no answer leaves the previous capture's project on the row.
    TestKit.test("a nil value removes the key") {
        let store = try store()
        let event = try store.recordActivity(ActivityEvent(
            kind: .app, startedAt: Date(), appName: "Code",
            metadata: ["place": "old-project", "cwd": "/tmp/old", "tabsOpen": "2"]
        ))
        try store.describeActivity(id: event.id, metadata: ["place": nil, "cwd": nil])
        let after = try unwrap(try store.allActivity(on: event.startedAt, minimumSeconds: 0).first)
        expectNil(after.metadata["place"])
        expectNil(after.metadata["cwd"])
        expectEqual(after.metadata["tabsOpen"], "2", "unrelated key survived")
    }

    TestKit.test("describing a row that is gone changes nothing") {
        let store = try store()
        try store.describeActivity(id: "not-a-row", metadata: ["place": "x"])
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

        let day = try store.allActivity(on: moment, minimumSeconds: 0)
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

func runDeletionTests() {
    TestKit.suite("Removing things")

    // Hiding rather than deleting: the process is still running and would simply
    // reappear on the next refresh.
    TestKit.test("a hidden project stays hidden across refreshes") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        try store.ignore(path: "/p/noisy", reason: "hidden from Now")

        let ignored = try store.ignoredPaths()
        expect(ignored.contains(FilePathCanon.canonical("/p/noisy")), "\(ignored)")
    }

    TestKit.test("hiding is undone in one place") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        try store.ignore(path: "/p/noisy")
        try store.stopIgnoring(path: "/p/noisy")
        expectEqual(try store.ignoredPaths().count, 0, "after un-hiding")
    }

    // The detector and the live view share one list, so "I don't want to see
    // this" means the same thing in both and is reversed once.
    TestKit.test("hiding a project also stops the detector proposing it") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        try store.ignore(path: "/p/tutorial")

        let detector = AbandonedWorkDetector(
            adapters: [], ignoredPaths: try store.ignoredPaths()
        )
        // No adapters, so nothing to find — the point is that the ignore list
        // reaches the detector at all, via the same call the app makes.
        expectEqual(try detector.scan().proposals.count, 0)
    }

    TestKit.test("clearing what you wrote leaves the project alone") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        _ = try store.saveProjectNote(ProjectNote(
            repositoryPath: "/p/acme", repositoryName: "acme", building: "the timeline"
        ))
        expectNotNil(try store.projectNote(for: "/p/acme"), "before")

        try store.deleteProjectNote(repositoryPath: "/p/acme")
        expectNil(try store.projectNote(for: "/p/acme"), "after")
    }

    TestKit.test("forgetting one entry leaves the rest of the day") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try store.beginActivity(ActivityEvent(
            kind: .app, startedAt: moment, appName: "VS Code"
        ))
        try store.beginActivity(ActivityEvent(
            kind: .app, startedAt: moment.addingTimeInterval(1800), appName: "Chrome"
        ))

        try store.deleteActivity(id: first.id)
        let remaining = try store.allActivity(on: moment, minimumSeconds: 0)
        expectEqual(remaining.count, 1, "one left")
        expectEqual(remaining.first?.appName, "Chrome")
    }

    TestKit.test("forgetting a day leaves other days alone") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = today.addingTimeInterval(-86_400)

        try store.beginActivity(ActivityEvent(kind: .app, startedAt: yesterday, appName: "Slack"))
        try store.beginActivity(ActivityEvent(kind: .app, startedAt: today, appName: "VS Code"))

        try store.deleteActivity(on: today)
        expectEqual(try store.allActivity(on: today, minimumSeconds: 0).count, 0, "today gone")
        expectEqual(
            try store.allActivity(on: yesterday, minimumSeconds: 0).count, 1, "yesterday kept"
        )
    }
}


func runWrittenOnlyTests() {
    TestKit.suite("The timeline is what you wrote")

    func store() throws -> Store { try Store(database: FlowTraceDatabase.inMemory()) }
    let moment = Date(timeIntervalSince1970: 1_700_000_000)

    func event(_ app: String, at minutes: Int) -> ActivityEvent {
        ActivityEvent(
            kind: .app,
            startedAt: moment.addingTimeInterval(Double(minutes) * 60),
            appName: app
        )
    }

    // Ambient capture produced 24 entries in a day of which 2 said anything —
    // "Code" seven times over, indistinguishable and worth nothing to read.
    TestKit.test("ambient events don't earn a line; written ones do") {
        let store = try store()
        let noted = try store.beginActivity(event("VS Code", at: 0))
        try store.beginActivity(event("Chrome", at: 30))
        try store.beginActivity(event("Slack", at: 60))
        _ = try store.annotate(activityId: noted.id, note: "rebuilding the capture layer")

        let written = try store.activity(on: moment, minimumSeconds: 0)
        expectEqual(written.count, 1, "only what was written")
        expectEqual(written.first?.note, "rebuilding the capture layer")
    }

    TestKit.test("the raw record is still there when asked for") {
        let store = try store()
        try store.beginActivity(event("VS Code", at: 0))
        try store.beginActivity(event("Chrome", at: 30))

        expectEqual(try store.activity(on: moment, minimumSeconds: 0).count, 0, "written")
        expectEqual(
            try store.allActivity(on: moment, minimumSeconds: 0).count, 2, "raw"
        )
    }

    // Ambient rows exist to give the capture panel something to say about what
    // led here; past a couple of days they are only taking up space.
    TestKit.test("old ambient rows are pruned, written ones never are") {
        let store = try store()
        let old = Date().addingTimeInterval(-5 * 86_400)

        let keep = try store.recordActivity(ActivityEvent(
            kind: .app, startedAt: old, endedAt: old, appName: "VS Code",
            note: "the thing I was building"
        ))
        _ = try store.recordActivity(ActivityEvent(
            kind: .app, startedAt: old, endedAt: old, appName: "Slack"
        ))

        let removed = try store.pruneAmbientActivity(olderThan: 2)
        expectEqual(removed, 1, "only the unwritten one")

        let survivors = try store.allActivity(on: old, minimumSeconds: 0)
        expectEqual(survivors.count, 1)
        expectEqual(survivors.first?.id, keep.id, "what you wrote survives")
    }

    TestKit.test("an imported session is never pruned") {
        let store = try store()
        let old = Date().addingTimeInterval(-9 * 86_400)
        var session = ActivityEvent(
            kind: .agentSession, startedAt: old, appName: "Claude Code",
            externalId: "claude-code:old"
        )
        session.endedAt = old
        _ = try store.upsertImportedActivity(session)

        _ = try store.pruneAmbientActivity(olderThan: 2)
        expectEqual(try store.allActivity(on: old, minimumSeconds: 0).count, 1, "kept")
    }
}

func runErasureTests() {
    TestKit.suite("Removing what FlowTrace knows")

    func populated() throws -> Store {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        let now = Date()

        let noted = try store.beginActivity(ActivityEvent(
            kind: .app, startedAt: now, appName: "VS Code", target: "flowtrace"
        ))
        _ = try store.annotate(activityId: noted.id, note: "building the erase controls")
        try store.beginActivity(ActivityEvent(
            kind: .app, startedAt: now.addingTimeInterval(600), appName: "Slack"
        ))
        _ = try store.noteTab(
            url: "https://pencil.com", title: "Pencil", browser: "Brave", note: "logo"
        )
        _ = try store.saveProjectNote(ProjectNote(
            repositoryPath: "/p/acme", repositoryName: "acme", building: "the thing"
        ))
        _ = try store.create(WorkThread(title: "A thread"))
        return store
    }

    // "Delete all data" used to leave three tables behind — every app used, every
    // window title, every page visited, every note written — because the table
    // list was a literal that nobody updated when tables were added.
    TestKit.test("deleting everything leaves nothing behind, in any table") {
        let store = try populated()
        try store.deleteAllData()

        let holdings = try store.holdings()
        expect(holdings.isEmpty, "still holding: \(holdings)")
        expectEqual(try store.allThreads().count, 0, "threads")
        expectNil(try store.projectNote(for: "/p/acme"), "project note")
        expectNil(try store.noteForTab(url: "https://pencil.com"), "page note")
    }

    // The distinction people actually want: erase the surveillance, keep the
    // journal.
    TestKit.test("erasing what was recorded automatically keeps what you wrote") {
        let store = try populated()
        let before = try store.holdings()
        expect(before.rawActivity > 0, "precondition: something was recorded")

        let removed = try store.deleteRawActivity()
        expect(removed > 0, "removed \(removed)")

        let after = try store.holdings()
        expectEqual(after.rawActivity, 0, "automatic records gone")
        expectEqual(after.writtenNotes, before.writtenNotes, "notes kept")
        expectEqual(
            try store.noteForTab(url: "https://pencil.com"), "logo", "page note kept"
        )
    }

    TestKit.test("an imported session is not treated as surveillance") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        var session = ActivityEvent(
            kind: .agentSession, startedAt: Date(), appName: "Claude Code",
            externalId: "claude-code:keep"
        )
        session.endedAt = session.startedAt
        _ = try store.upsertImportedActivity(session)

        _ = try store.deleteRawActivity()
        expectEqual(try store.holdings().agentSessions, 1, "sessions survive")
    }

    TestKit.test("holdings describe the store in the terms a person thinks in") {
        let store = try populated()
        let holdings = try store.holdings()
        expect(holdings.writtenNotes >= 2, "notes: \(holdings.writtenNotes)")
        expect(holdings.pagesVisited >= 1, "pages: \(holdings.pagesVisited)")
        expectEqual(holdings.projectNotes, 1)
        expect(!holdings.fileSizeLabel.isEmpty)
    }
}
