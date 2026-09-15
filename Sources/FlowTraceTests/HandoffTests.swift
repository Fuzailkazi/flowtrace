import Foundation
import FlowTraceCore

/// Two things the validation pass found, and the assertions that keep them
/// fixed.
func runHandoffTests() {
    TestKit.suite("Saying only what the evidence supports")

    func brief(hours: Int, days: Int = 0, human: Bool) -> ResumeBrief {
        ResumeBrief(
            repositoryName: "gtm", repositoryPath: "/p/gtm", branch: "main",
            daysSinceActivity: days, hoursSinceActivity: hours, elapsedIsHuman: human
        )
    }

    // The case that started this. `gtm` was last written to by a weekly
    // scheduled task, and the recall screen reported that as "You were last
    // here 22 hours ago" — a claim about the user backed by a cron job.
    TestKit.test("a scheduled task's write is never reported as your attention") {
        let machine = brief(hours: 22, human: false)
        let sentence = machine.openingSentence

        expect(!sentence.hasPrefix("You were last here"),
               "must not put the user in the subject: \(sentence)")
        expect(sentence.contains("Something last wrote here"), sentence)
        expect(sentence.contains("22 hours ago"), "the number itself is still true")
        expect(sentence.contains("Nothing in the transcript says when you were last here"),
               "and the gap is stated rather than left for the reader to assume")
    }

    TestKit.test("the same wording carries into the text handed to an agent") {
        let rendered = brief(hours: 22, human: false).render()
        expect(rendered.contains("not necessarily you"), rendered)
        expect(!rendered.contains("You worked on gtm 22 hours ago"))
    }

    // The strong claim is still made when it is earned, because hedging
    // everything would make the honest case worthless.
    TestKit.test("a real human turn still gets the plain sentence") {
        let human = brief(hours: 0, days: 4, human: true)
        expectEqual(human.openingSentence, "You were last here 4 days ago, on branch main.")
        expect(human.render().hasPrefix("You worked on gtm 4 days ago"))
    }

    TestKit.test("no human timestamp is ever invented") {
        // The flag is the only thing that changes; the measured numbers are
        // identical either way.
        let machine = brief(hours: 22, human: false)
        let person = brief(hours: 22, human: true)
        expectEqual(machine.elapsedPhrase, person.elapsedPhrase)
        expectEqual(machine.hoursSinceActivity, person.hoursSinceActivity)
    }

    TestKit.suite("Now and recall agreeing about a place")

    func project(_ name: String, state: LiveAgent.State = .forgotten) -> LiveProject {
        LiveProject(
            path: "/p/\(name)", name: name,
            agents: [LiveAgent(
                pid: 1, agent: .claudeCode, workingDirectory: "/p/\(name)",
                projectRoot: "/p/\(name)", repositoryName: name,
                lastActivityAt: Date().addingTimeInterval(-70_000),
                lastHumanActivityAt: Date().addingTimeInterval(-70_000), state: state
            )],
            servers: []
        )
    }

    // Opening a row must not change what that row said. Before the handoff the
    // recall screen had no census at all on a fresh launch, so the same place
    // looked different depending on how you reached it.
    TestKit.test("the reading Now took is the reading recall sees") {
        let census = LiveCensus(projects: [project("acme"), project("other")])
        let found = try unwrap(census.project(at: "/p/acme"))
        expectEqual(found.name, "acme")
        expect(found.isForgotten, "and carries the same verdict, not a fresh guess")
    }

    TestKit.test("a path is matched however it is spelled") {
        let census = LiveCensus(projects: [project("acme")])
        expect(census.project(at: "/p/acme/") != nil, "trailing separator")
        expect(census.project(at: "/p/./acme") != nil, "unnormalised")
        expect(census.project(at: "/p/elsewhere") == nil, "and no false match")
    }

    // "Nothing has been read yet" and "nothing is running" are different
    // answers, and only one of them means the screen should stay quiet.
    TestKit.test("never having looked is not the same as finding nothing") {
        expect(!LiveCensus.none.hasBeenTaken)
        expect(!LiveCensus.none.isFresh)
        expect(!LiveCensus.none.isStale, "an unread census is neither fresh nor stale")
        expect(LiveCensus.none.takenLabel == nil, "and claims no age")

        let empty = LiveCensus(projects: [])
        expect(empty.hasBeenTaken, "a census that found nothing was still taken")
        expect(empty.isFresh)
    }

    TestKit.test("an old reading is offered, but dated rather than passed off as now") {
        let old = LiveCensus(
            projects: [project("acme")], capturedAt: Date().addingTimeInterval(-1_800)
        )
        expect(old.hasBeenTaken)
        expect(!old.isFresh, "half an hour is not now")
        expect(old.isStale)
        expect(old.project(at: "/p/acme") != nil, "still shown — stale beats blank")
        expectEqual(old.takenLabel, "30 minutes ago", "and says so")
    }

    TestKit.test("a reading from seconds ago is simply current") {
        let fresh = LiveCensus(projects: [project("acme")])
        expect(fresh.isFresh)
        expectEqual(fresh.takenLabel, "a moment ago")
    }

    TestKit.test("a census is not held when observation was never permitted") {
        let refused = LiveCensus.recorded([project("acme")], permitted: false)
        expect(!refused.hasBeenTaken, "nothing recorded")
        expect(refused.project(at: "/p/acme") == nil, "and nothing readable back")
        expect(refused.projects.isEmpty)
    }

    TestKit.test("switching observation off drops a reading taken while it was on") {
        var census = LiveCensus.recorded([project("acme")], permitted: true)
        expect(census.project(at: "/p/acme") != nil)
        // The next recording, with the permission withdrawn, replaces it.
        census = .recorded(census.projects, permitted: false)
        expect(census.project(at: "/p/acme") == nil, "the old reading did not survive")
    }

    // The census is memory and nothing else. Writing it down would outlive the
    // processes it describes and become a slower, wronger source of truth.
    TestKit.test("a census is never persisted, so a relaunch starts from nothing") {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flowtrace-census-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }

        let store = try Store(database: try FlowTraceDatabase(url: file))
        let tables = try store.database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }
        for name in tables {
            expect(!name.lowercased().contains("census"),
                   "a census table exists, which it must not: \(name)")
            expect(!name.lowercased().contains("liveproject"), name)
        }

        // And nothing carried in memory survives a new value.
        var census = LiveCensus(projects: [project("acme")])
        census = .none
        expect(!census.hasBeenTaken, "a relaunch begins with no reading")
    }
}

/// The `gtm` case, from the machine it was found on.
///
/// A repository whose last human turn was a fortnight before a weekly
/// scheduled task ran in it. The scheduled task arrives in the user slot, is
/// long enough to pass every substantive-text check, and moved both the file's
/// modification time and the session's last-activity time — so the recall
/// screen told the user they had been working there twenty-two hours ago.
func runScheduledTaskTests(fixtures: URL) {
    TestKit.suite("A scheduled task is not you")

    let adapter = ClaudeCodeAdapter(root: fixtures.appendingPathComponent("claude-scheduled"))

    TestKit.test("the session dates the human turn, not the robot's") {
        let session = try unwrap(try adapter.discoverSessions().first)

        let human = try unwrap(session.lastHumanActivityAt)
        let any = try unwrap(session.lastActivityAt)
        expect(human < any, "the scheduled task is later, and is not counted as you")

        // 2026-07-01, the day the person actually typed.
        let day = Calendar(identifier: .gregorian)
        var utc = day
        utc.timeZone = try unwrap(TimeZone(identifier: "UTC"))
        expectEqual(utc.component(.day, from: human), 1, "the human turn")
        expectEqual(utc.component(.day, from: any), 14, "the scheduled task")
    }

    TestKit.test("the thing the scheduled task said is never quoted back as your prompt") {
        let session = try unwrap(try adapter.discoverSessions().first)
        for prompt in session.recentPrompts {
            expect(!prompt.contains("scheduled-task"), "got: \(prompt)")
        }
        expect(
            session.recentPrompts.contains { $0.contains("positioning section") },
            "and what the person did type is still there: \(session.recentPrompts)"
        )
    }

    TestKit.test("a session with only a scheduled task can date no human at all") {
        // The state that must produce the hedged wording rather than a guess.
        let robotOnly = AgentSession(
            id: "x", agent: .claudeCode, cwd: "/Users/dev/gtm",
            lastActivityAt: Date(), lastHumanActivityAt: nil, filePath: "/tmp/x"
        )
        expect(robotOnly.lastHumanActivityAt == nil, "nothing invented")
    }
}

/// Opening the workspace from the menu bar.
///
/// The failure was invisible: SwiftUI's `NSApplicationDelegateAdaptor` installs
/// its own delegate and forwards callbacks to ours, so
/// `NSApp.delegate as? AppLifecycle` returned nil. Optional chaining turned
/// every call on that nil into a no-op, so the activation-policy change and the
/// activation were both skipped and nothing was even logged. Clicking "Open
/// FlowTrace" did nothing at all, silently.
///
/// The window-identity half is what these can reach: `AppLifecycle` lives in
/// the app target, which this suite does not link, so the delegate reference
/// itself is covered by the manual pass.
func runWorkspaceWindowTests() {
    TestKit.suite("Naming the workspace window")

    // Observed on the running app: SwiftUI stamps the window group's id onto
    // the window it builds, as `<id>-AppWindow-1`.
    let identifier = "flowtrace.main"

    func isWorkspace(_ raw: String?) -> Bool {
        raw?.hasPrefix(identifier) == true
    }

    TestKit.test("the window SwiftUI builds is recognised") {
        expect(isWorkspace("flowtrace.main-AppWindow-1"))
        expect(isWorkspace("flowtrace.main-AppWindow-2"), "a second instance is still the workspace")
    }

    // The old test was "anything that can become main and is not the capture
    // panel or Settings" — a description of what the workspace happens to be
    // rather than of what it is, which left every transient window a candidate
    // for the close watcher to act on.
    TestKit.test("nothing else is mistaken for it") {
        expect(!isWorkspace(nil), "the status item carries no identifier")
        expect(!isWorkspace("com_apple_SwiftUI_Settings_window"))
        expect(!isWorkspace("SwiftUI.MenuBarExtraWindow"))
        expect(!isWorkspace("flowtrace-capture-panel"), "a near-miss name is still a miss")
    }
}
