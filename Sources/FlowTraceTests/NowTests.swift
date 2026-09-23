import Foundation
import FlowTraceCore

/// What Now is allowed to claim.
///
/// Every case here came from a reading taken on a real machine, where the
/// screen listed a project called `/`, a project called `~`, and a project
/// called `aum` that was sitting in the Trash — each with a timestamp, each
/// inviting the user to pick work back up that they had never started or had
/// deliberately thrown away.
func runNowTests() {
    let home = "/Users/dev"

    TestKit.suite("Human-first Now sections")

    func attentionProject(
        _ name: String,
        humanDaysAgo: Double?,
        machineMinutesAgo: Double = 1,
        prompt: String? = nil,
        serverPort: UInt16? = nil
    ) -> LiveProject {
        let agent = humanDaysAgo.map { days in
            LiveAgent(
                pid: Int32.random(in: 1_000...9_999), agent: .claudeCode,
                workingDirectory: "/p/\(name)", projectRoot: "/p/\(name)",
                repositoryName: name, lastPrompt: prompt,
                lastActivityAt: Date().addingTimeInterval(-machineMinutesAgo * 60),
                lastHumanActivityAt: Date().addingTimeInterval(-days * 86_400),
                state: .working
            )
        }
        let servers = serverPort.map {
            [LiveServer(pid: 9_999, port: $0, processName: "node",
                        workingDirectory: "/p/\(name)", projectRoot: "/p/\(name)",
                        projectName: name)]
        } ?? []
        return LiveProject(path: "/p/\(name)", name: name,
                           agents: agent.map { [$0] } ?? [], servers: servers)
    }

    TestKit.test("machine activity alone never becomes work to continue") {
        let machineOnly = attentionProject("server", humanDaysAgo: nil, serverPort: 3000)
        let sections = AttentionRanker(now: Date()).rank([machineOnly])
        expect(sections.continueWork.isEmpty)
        expect(sections.recent.isEmpty)
        expectEqual(sections.background.count, 1)
    }

    TestKit.test("recent human attention outranks a fresher machine heartbeat") {
        let human = attentionProject("human", humanDaysAgo: 1, machineMinutesAgo: 60,
                                     prompt: "finish the launch brief")
        let machine = attentionProject("machine", humanDaysAgo: 5, machineMinutesAgo: 0)
        let sections = AttentionRanker(now: Date()).rank([machine, human])
        expectEqual(sections.continueWork.first?.name, "human")
    }

    TestKit.test("Continue has two places and Recently has the next six without duplicates") {
        let projects = (0..<10).map {
            attentionProject("p\($0)", humanDaysAgo: Double($0) + 0.1)
        }
        let sections = AttentionRanker(now: Date()).rank(projects)
        expectEqual(sections.continueWork.count, 2)
        expectEqual(sections.recent.count, 6)
        expect(Set(sections.continueWork.map(\.path)).isDisjoint(with: sections.recent.map(\.path)))
    }

    TestKit.test("work older than thirty days is background, not recent") {
        let old = attentionProject("old", humanDaysAgo: 31)
        let sections = AttentionRanker(now: Date()).rank([old])
        expect(sections.continueWork.isEmpty)
        expect(sections.recent.isEmpty)
        expectEqual(sections.background.map(\.name), ["old"])
    }

    TestKit.suite("How long is long enough")

    let thresholds = ActivityThresholds.default

    TestKit.test("an age lands in exactly one state") {
        expectEqual(thresholds.state(forAge: 0), .working)
        expectEqual(thresholds.state(forAge: 119), .working)
        expectEqual(thresholds.state(forAge: 120), .waiting, "the boundary belongs to the calmer state")
        expectEqual(thresholds.state(forAge: 3_599), .waiting)
        expectEqual(thresholds.state(forAge: 3_600), .quiet)
        expectEqual(thresholds.state(forAge: 43_199), .quiet)
        expectEqual(thresholds.state(forAge: 43_200), .forgotten)
        expectEqual(thresholds.state(forAge: 86_400 * 30), .forgotten)
    }

    // The split that the whole screen turns on. Before it, two hours and four
    // days were the same word, so genuinely forgotten work sat in a list next
    // to work somebody had stepped away from for lunch.
    TestKit.test("stepping away for an hour is not the same as forgetting") {
        expectEqual(thresholds.state(forAge: 2 * 3_600), .quiet)
        expectEqual(thresholds.state(forAge: 20 * 3_600), .forgotten)
        expect(!LiveAgent.State.quiet.isActive)
        expect(!LiveAgent.State.forgotten.isActive)
        expect(LiveAgent.State.working.isActive)
        expect(LiveAgent.State.waiting.isActive)
    }

    // The thresholds are a hypothesis, so they have to be movable without
    // touching anything that reads them.
    TestKit.test("the boundaries can be moved without editing the reader") {
        let impatient = ActivityThresholds(working: 10, waiting: 60, quiet: 300)
        expectEqual(impatient.state(forAge: 120), .quiet)
        expectEqual(impatient.state(forAge: 600), .forgotten)
    }

    TestKit.suite("What counts as a place you work")

    func place(_ cwd: String, repo: String? = nil) -> WorkPlace {
        WorkPlace.resolve(workingDirectory: cwd, repositoryRoot: repo, home: home)
    }

    TestKit.test("a repository under your home folder is a project") {
        let resolved = place("\(home)/venture/flowtrace/Sources", repo: "\(home)/venture/flowtrace")
        expect(resolved.isProject)
        expectEqual(resolved.name, "flowtrace")
        expectEqual(resolved.path, "\(home)/venture/flowtrace", "grouped at the repository root")
    }

    // Found live: a Codex process started from the filesystem root produced a
    // project named `/` sitting in the list beside real work.
    TestKit.test("the filesystem root is not a project") {
        let resolved = place("/")
        expect(!resolved.isProject)
        expectEqual(resolved.rejection, .notADirectoryAnyoneWorksIn)
    }

    // Found live: two agents launched from the home directory were grouped
    // into one place called `~`, which is really "everything else".
    TestKit.test("the home folder itself is not a project") {
        expectEqual(place(home).rejection, .homeDirectory)
    }

    // Found live: a repository in the Trash was offered as work to resume.
    TestKit.test("work in the Trash has already been thrown away") {
        expectEqual(place("\(home)/.Trash/aum").rejection, .discarded)
        expectEqual(place("\(home)/.Trash/aum/src", repo: "\(home)/.Trash/aum").rejection, .discarded,
                    "a repository in the Trash is still in the Trash")
    }

    TestKit.test("a project that merely sounds like rubbish is kept") {
        expect(place("\(home)/code/trash-panda").isProject, "matched on whole path components")
        expect(place("\(home)/code/.Trashcan-ui").isProject)
    }

    TestKit.test("directories outside your own folders are not projects") {
        expectEqual(place("/tmp/scratch").rejection, .systemDirectory)
        expectEqual(place("/private/var/folders/x").rejection, .systemDirectory)
        expectEqual(place("\(home)/Library/Caches/thing").rejection, .systemDirectory)
    }

    TestKit.suite("Grouping work into places")

    func agent(
        _ name: String, root: String, state: LiveAgent.State,
        agent kind: AgentName = .claudeCode, minutesAgo: Double = 5,
        hidden: Bool = false, pid: Int32 = 1
    ) -> LiveAgent {
        LiveAgent(
            pid: pid, agent: kind, workingDirectory: root, projectRoot: root,
            repositoryName: name,
            lastActivityAt: hidden ? nil : Date().addingTimeInterval(-minutesAgo * 60),
            state: state, transcriptHidden: hidden
        )
    }

    // The CLI spawns helper processes that share a working directory, and each
    // one used to become a separate row, so one piece of work looked like four.
    TestKit.test("several processes in one place are one piece of work") {
        let state = LiveState(agents: [
            agent("acme", root: "/p/acme", state: .working, pid: 1),
            agent("acme", root: "/p/acme", state: .working, pid: 2),
            agent("acme", root: "/p/acme", state: .working, pid: 3),
        ])
        expectEqual(state.projects().count, 1)
    }

    // Two different agents in the same repository are two pieces of work, and
    // collapsing them would hide that one of them has been forgotten.
    TestKit.test("two different agents in one place stay distinct") {
        let project = LiveState(agents: [
            agent("acme", root: "/p/acme", state: .working, agent: .claudeCode),
            agent("acme", root: "/p/acme", state: .forgotten, agent: .codex, minutesAgo: 2_000),
        ]).projects().first
        expectEqual(project?.agents.count, 2)
        expectEqual(project?.state, .working, "the place is judged by the strongest thing in it")
        expect(!(project?.isForgotten ?? true), "something here is still moving")
    }

    TestKit.test("worktrees of one repository are separate places") {
        // Each worktree has its own root and its own session, and treating them
        // as one project would merge four live pieces of work into one row.
        let state = LiveState(agents: [
            agent("docs-2", root: "/w/docs/docs-2", state: .working),
            agent("docs-3", root: "/w/docs/docs-3", state: .waiting),
        ])
        expectEqual(state.projects().count, 2)
    }

    TestKit.suite("What is surfaced as forgotten")

    TestKit.test("a place quiet for half a day is forgotten") {
        let project = try unwrap(
            LiveState(agents: [agent("old", root: "/p/old", state: .forgotten, minutesAgo: 2_000)])
                .projects().first
        )
        expect(project.isForgotten)
        expect(!project.isQuiet, "forgotten and quiet are never both true")
    }

    TestKit.test("a place quiet for two hours is not") {
        let project = try unwrap(
            LiveState(agents: [agent("lunch", root: "/p/lunch", state: .quiet, minutesAgo: 120)])
                .projects().first
        )
        expect(!project.isForgotten, "stepping away is not forgetting")
        expect(project.isQuiet)
    }

    TestKit.test("one moving agent keeps the whole place off the list") {
        let project = try unwrap(
            LiveState(agents: [
                agent("mixed", root: "/p/mixed", state: .forgotten, minutesAgo: 3_000),
                agent("mixed", root: "/p/mixed", state: .working, agent: .codex),
            ]).projects().first
        )
        expect(!project.isForgotten)
    }

    // "Forgotten" is a claim about work. Made from agents nobody was allowed to
    // look at, it would be a claim about permission wearing the same colour.
    TestKit.test("an unread agent is never counted as forgotten") {
        let state = LiveState(agents: [
            agent("hidden", root: "/p/hidden", state: .forgotten, hidden: true),
        ])
        expectEqual(state.forgottenAgents.count, 0)
        expect(!(try unwrap(state.projects().first).isForgotten))
        expectEqual(try unwrap(state.projects().first).statusLabel, "not reading transcripts")
    }

    TestKit.test("the headline leads with what was forgotten") {
        let forgotten = LiveState(agents: [
            agent("a", root: "/p/a", state: .forgotten, minutesAgo: 3_000),
            agent("b", root: "/p/b", state: .working),
        ])
        expectEqual(forgotten.headline, "2 agents running · 1 forgotten")

        let busy = LiveState(agents: [agent("b", root: "/p/b", state: .working)])
        expectEqual(busy.headline, "1 agent running")
    }

    TestKit.suite("When the context is missing")

    // A process that pgrep found but whose history is nowhere on disk. The old
    // reader called that `.idle`, which filed a session started ten seconds ago
    // as days-old work.
    TestKit.test("a running agent with no history is waiting, not forgotten") {
        var live = agent("fresh", root: "/p/fresh", state: .waiting)
        live.lastActivityAt = nil
        live.activityIsKnown = false

        expect(live.state != .forgotten, "never claimed as forgotten")
        expectEqual(live.lastActivityLabel, "running, no history yet")
        expectEqual(LiveState(agents: [live]).forgottenAgents.count, 0)
    }

    TestKit.test("an unread agent says so rather than guessing") {
        let hidden = agent("x", root: "/p/x", state: .quiet, hidden: true)
        expectEqual(hidden.lastActivityLabel, "not reading this one")
    }

    TestKit.test("a place with only a server keeps its own label") {
        let project = LiveProject(
            path: "/p/c", name: "c", agents: [],
            servers: [LiveServer(pid: 2, port: 5_173, processName: "node")]
        )
        expectEqual(project.statusLabel, "server only")
        expect(!project.isForgotten, "a port held open is not a forgotten session")
    }

    TestKit.test("a census exposes forgotten work for persistent surfaces") {
        let state = LiveState(agents: [
            agent("old", root: "/p/old", state: .forgotten, minutesAgo: 3_000),
            agent("busy", root: "/p/busy", state: .working),
        ])
        let census = LiveCensus(projects: state.projects())

        expectEqual(census.forgottenWorkCount, 1)
        expectEqual(census.firstForgottenProject?.name, "old")
        expectEqual(census.menuBarStatusText, "1 forgotten")
    }
}

/// Associating a running process with the work it is doing.
///
/// Driven through the public reader with fixture roots, because the association
/// is the part that was wrong: a running Codex process had no readable history
/// at all, so it was reported as `waiting` with no age for as long as it ran.
func runAssociationTests(fixtures: URL) {
    TestKit.suite("Finding the session a process belongs to")

    /// Discovery is bounded by file age, and a committed fixture's timestamp is
    /// whenever the repository was checked out. Copying and touching gives the
    /// copy a date the reader will look at.
    func freshCopy(of name: String) -> URL {
        let manager = FileManager.default
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flowtrace-now-\(UUID().uuidString)")
        try? manager.copyItem(at: fixtures.appendingPathComponent(name), to: scratch)
        if let walker = manager.enumerator(at: scratch, includingPropertiesForKeys: nil) {
            for case let file as URL in walker {
                try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            }
        }
        return scratch
    }

    let claudeRoot = fixtures.appendingPathComponent("claude")
    let codexRoot = freshCopy(of: "codex").appendingPathComponent("sessions")

    func reader(thresholds: ActivityThresholds = .default) -> LiveStateReader {
        LiveStateReader(
            claudeRoot: claudeRoot,
            codexRoot: codexRoot,
            // A database that does not exist, so OpenCode contributes nothing
            // and cannot make another agent's assertion pass by accident.
            openCodeDatabase: URL(fileURLWithPath: "/nonexistent/opencode.db"),
            thresholds: thresholds
        )
    }

    func process(_ command: String, cwd: String, pid: Int32 = 900) -> LiveStateReader.RunningProcess {
        LiveStateReader.RunningProcess(pid: pid, command: command, workingDirectory: cwd)
    }

    // The bug this whole pass started from. `LiveStateReader` knew only how to
    // find a Claude Code transcript, so a Codex process fell into the "nothing
    // on disk" branch and sat at `waiting` with no age for as long as it ran.
    TestKit.test("a running Codex process finds its own rollout") {
        let agent = reader().agent(
            for: process("codex", cwd: "/Users/dev/acme/packages/api"),
            root: "/Users/dev/acme",
            transcripts: .codex
        )
        expectEqual(agent.agent, .codex)
        expect(agent.sessionId != nil, "the rollout was identified")
        expect(agent.lastActivityAt != nil, "and dated, so its age is measured rather than guessed")
        expect(agent.activityIsKnown)
    }

    // The rollout records `/Users/dev/acme/packages/api`; the process could
    // equally have been started at the repository root.
    TestKit.test("a Codex process elsewhere in the repository still finds it") {
        let agent = reader().agent(
            for: process("codex", cwd: "/Users/dev/acme"),
            root: "/Users/dev/acme",
            transcripts: .codex
        )
        expect(agent.sessionId != nil, "found by repository rather than by exact directory")
    }

    // Association must not reach across repositories to find something recent.
    TestKit.test("a Codex process in another repository finds nothing") {
        let agent = reader().agent(
            for: process("codex", cwd: "/Users/dev/unrelated"),
            root: "/Users/dev/unrelated",
            transcripts: .codex
        )
        expect(agent.sessionId == nil, "no session borrowed from a different project")
        expectEqual(agent.state, .waiting, "running, activity unknown")
        expect(!agent.activityIsKnown)
    }

    TestKit.test("a Claude process finds its transcript by path") {
        let agent = reader().agent(
            for: process("claude", cwd: "/Users/dev/acme"),
            root: "/Users/dev/acme",
            transcripts: .claudeCode
        )
        expect(agent.sessionId != nil)
        expect(agent.lastPrompt != nil, "and the last thing that was asked of it")
    }

    // Each agent gets its own lookup, so a switched-on source must not answer
    // for a different agent.
    TestKit.test("one agent's history is never handed to another") {
        let codexAsClaude = reader().agent(
            for: process("claude", cwd: "/Users/dev/acme/packages/api"),
            root: "/Users/dev/acme",
            transcripts: .all
        )
        // The Claude fixture lives under the repository root, so the fallback
        // finds it; what matters is that it is a Claude session, not the Codex
        // rollout sitting in the same directory.
        expect(codexAsClaude.sessionId != "019cc2c5-f44e-7f03-9ea4-ca5653d3cb30",
               "did not pick up the Codex rollout")
    }

    TestKit.test("a source that is switched off opens nothing, however findable") {
        let agent = reader().agent(
            for: process("codex", cwd: "/Users/dev/acme/packages/api"),
            root: "/Users/dev/acme",
            transcripts: .claudeCode
        )
        expect(agent.transcriptHidden, "Codex stays shut when only Claude is allowed")
        expect(agent.sessionId == nil)
        expect(agent.lastActivityAt == nil)
    }

    // The state has to come from the measured age, not from a default.
    TestKit.test("a freshly touched session reads as working") {
        let agent = reader().agent(
            for: process("codex", cwd: "/Users/dev/acme/packages/api"),
            root: "/Users/dev/acme",
            transcripts: .codex
        )
        expectEqual(agent.state, .working, "touched a moment ago")
    }

    // A session whose file has not been touched since yesterday. This is the
    // case the screen exists for, so it is measured end to end — from the file
    // on disk to the verdict — rather than only at the threshold function.
    TestKit.test("a session last written yesterday reads as forgotten") {
        let stale = freshCopy(of: "codex").appendingPathComponent("sessions")
        let twentyHoursAgo = Date().addingTimeInterval(-20 * 3_600)
        if let walker = FileManager.default.enumerator(at: stale, includingPropertiesForKeys: nil) {
            for case let file as URL in walker {
                try? FileManager.default.setAttributes(
                    [.modificationDate: twentyHoursAgo], ofItemAtPath: file.path
                )
            }
        }
        let aged = LiveStateReader(
            claudeRoot: claudeRoot, codexRoot: stale,
            openCodeDatabase: URL(fileURLWithPath: "/nonexistent/opencode.db")
        )
        let agent = aged.agent(
            for: process("codex", cwd: "/Users/dev/acme/packages/api"),
            root: "/Users/dev/acme",
            transcripts: .codex
        )
        expectEqual(agent.state, .forgotten)
        expect(agent.lastActivityLabel.hasSuffix("h ago"), "and says how long: \(agent.lastActivityLabel)")
    }

    // The same file, three hours old, is somebody who stepped away — not
    // somebody who forgot. This is the distinction the fourth state exists for.
    TestKit.test("the same session three hours old is merely quiet") {
        let recent = freshCopy(of: "codex").appendingPathComponent("sessions")
        let threeHoursAgo = Date().addingTimeInterval(-3 * 3_600)
        if let walker = FileManager.default.enumerator(at: recent, includingPropertiesForKeys: nil) {
            for case let file as URL in walker {
                try? FileManager.default.setAttributes(
                    [.modificationDate: threeHoursAgo], ofItemAtPath: file.path
                )
            }
        }
        let agent = LiveStateReader(
            claudeRoot: claudeRoot, codexRoot: recent,
            openCodeDatabase: URL(fileURLWithPath: "/nonexistent/opencode.db")
        ).agent(
            for: process("codex", cwd: "/Users/dev/acme/packages/api"),
            root: "/Users/dev/acme",
            transcripts: .codex
        )
        expectEqual(agent.state, .quiet, "the file is three hours old")
        // The fixture's own human turn is dated July, and that is the clock
        // attention runs on — so the agent looks recently active while the
        // person has been gone for months. Exactly the divergence the attention
        // model exists to express.
        expectEqual(agent.attentionState(), .forgotten,
                    "judged by when somebody last said something here")
    }

    TestKit.suite("Places that are not projects")

    // Found live: a Codex process started from `/` became a project called `/`.
    TestKit.test("a process started outside any project claims no place") {
        let agent = reader().agent(
            for: process("codex", cwd: "/"), root: "/", transcripts: .codex
        )
        expectEqual(agent.place?.rejection, .notADirectoryAnyoneWorksIn)
        expectEqual(LiveState(agents: [agent]).projects().count, 0, "no row invented for it")
        expectEqual(LiveState(agents: [agent]).unplacedAgents.count, 1, "but still counted as running")
    }
}

/// Reading OpenCode's own session store.
///
/// OpenCode is the one agent of the three that records where its work happened
/// instead of encoding it in a path slug or a rollout header, so the
/// association is exact. The database here is built by the test rather than
/// borrowed from the machine, so the assertions hold on a machine with no
/// OpenCode installed.
func runOpenCodeTests() {
    TestKit.suite("OpenCode sessions")

    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("flowtrace-opencode-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = directory.appendingPathComponent("opencode.db")

    // A Stripe-shaped secret, assembled at runtime.
    //
    // It is synthetic — invented for this test, never issued by anyone — but it
    // matches the pattern `Redaction` exists to catch, which is the whole point:
    // the test proves a credential-shaped session title is scrubbed before it
    // can reach the screen. GitHub's push protection scans files rather than
    // behaviour, so a literal here blocks the push while making the test no
    // stronger. Split into pieces that mean nothing apart, joined into a value
    // that is caught exactly as a real one would be.
    let stripePrefix = "sk_" + "live_"
    let syntheticStripeKey = stripePrefix + "51H8xQ2eZvKYlo2C" + "abcdefghijklmnopQ"

    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    let yesterday = now - Int64(20 * 3_600 * 1_000)
    let lastWeek = now - Int64(7 * 86_400 * 1_000)

    // The real schema, reduced to the columns FlowTrace reads.
    let sql = """
        CREATE TABLE session (
          id TEXT PRIMARY KEY, project_id TEXT, directory TEXT NOT NULL,
          title TEXT NOT NULL, time_created INTEGER, time_updated INTEGER NOT NULL,
          time_archived INTEGER
        );
        INSERT INTO session VALUES
          ('ses_new','p','/Users/dev/acme','add refresh token rotation',\(lastWeek),\(yesterday),NULL),
          ('ses_old','p','/Users/dev/acme','an earlier go at the same thing',\(lastWeek),\(lastWeek),NULL),
          ('ses_done','p','/Users/dev/finished','shipped and put away',\(lastWeek),\(now),\(now)),
          ('ses_key','p','/Users/dev/keys','use \(syntheticStripeKey) here',\(lastWeek),\(now),NULL);
        """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [database.path, sql]
    try? process.run()
    process.waitUntilExit()

    func reader() -> LiveStateReader {
        LiveStateReader(
            claudeRoot: directory, codexRoot: directory, openCodeDatabase: database
        )
    }
    func running(_ cwd: String) -> LiveStateReader.RunningProcess {
        LiveStateReader.RunningProcess(pid: 700, command: "opencode", workingDirectory: cwd)
    }

    TestKit.test("a running OpenCode process finds the session for its directory") {
        let agent = reader().agent(
            for: running("/Users/dev/acme"), root: "/Users/dev/acme", transcripts: .openCode
        )
        expectEqual(agent.sessionId, "ses_new")
        expectEqual(agent.lastPrompt, "add refresh token rotation",
                    "OpenCode's own title beats anything FlowTrace could infer")
        expectEqual(agent.state, .forgotten, "last touched yesterday")
    }

    // Two sessions in one directory is the normal case, and picking the older
    // one would report work as forgotten that was worked on this morning.
    TestKit.test("the newest session in a directory wins") {
        let agent = reader().agent(
            for: running("/Users/dev/acme"), root: "/Users/dev/acme", transcripts: .openCode
        )
        expect(agent.sessionId != "ses_old", "the earlier session is not the one reported")
    }

    // Resurfacing work somebody deliberately put away is the false positive
    // most likely to make the screen feel like noise.
    TestKit.test("a session the user archived is never resurfaced") {
        let agent = reader().agent(
            for: running("/Users/dev/finished"), root: "/Users/dev/finished",
            transcripts: .openCode
        )
        expect(agent.sessionId == nil, "archived means finished")
        expect(!agent.activityIsKnown)
    }

    // Titles are text from outside FlowTrace and go through the same redaction
    // as a typed prompt.
    // Guards the split above. If the pieces were ever joined wrongly, or the
    // production pattern changed, the test below would pass for the wrong
    // reason — a value nothing recognises as a secret is trivially not leaked.
    TestKit.test("the assembled synthetic key is still recognised as a credential") {
        let result = Redaction.redact(syntheticStripeKey)
        expect(result.redactionCount > 0, "the pattern no longer matches this value")
        expect(Redaction.isOnlyRedactions(result), "it is a key and nothing else")
        expect(!result.text.contains(stripePrefix), "and the prefix does not survive")
    }

    TestKit.test("a key pasted into a session title never reaches the screen") {
        let agent = reader().agent(
            for: running("/Users/dev/keys"), root: "/Users/dev/keys", transcripts: .openCode
        )
        // Checked against the same runtime-built prefix, so there is one
        // source of truth for what a Stripe key looks like in this test.
        let surfaced = agent.lastPrompt ?? ""
        expect(!surfaced.contains(stripePrefix), "the prefix survived: \(surfaced)")
        expect(!surfaced.contains(syntheticStripeKey), "the whole key survived")
        expect(!surfaced.isEmpty, "and the title itself is still shown, redacted")
    }

    TestKit.test("with the source switched off the database is never opened") {
        let agent = reader().agent(
            for: running("/Users/dev/acme"), root: "/Users/dev/acme", transcripts: .claudeCode
        )
        expect(agent.transcriptHidden)
        expect(agent.sessionId == nil)
    }

    TestKit.test("a missing database is no history rather than a failure") {
        let agent = LiveStateReader(
            claudeRoot: directory, codexRoot: directory,
            openCodeDatabase: directory.appendingPathComponent("absent.db")
        ).agent(for: running("/Users/dev/acme"), root: "/Users/dev/acme", transcripts: .openCode)
        expectEqual(agent.state, .waiting, "running, activity unknown")
        expect(!agent.activityIsKnown)
    }
}

/// What the screen puts in front of you.
func runNowOrderingTests() {
    TestKit.suite("What rises to the top")

    func agent(_ name: String, state: LiveAgent.State, minutesAgo: Double) -> LiveAgent {
        LiveAgent(
            pid: Int32.random(in: 1_000...9_999), agent: .claudeCode,
            workingDirectory: "/p/\(name)", projectRoot: "/p/\(name)", repositoryName: name,
            lastActivityAt: Date().addingTimeInterval(-minutesAgo * 60), state: state
        )
    }

    TestKit.test("what is moving still comes first") {
        let order = LiveState(agents: [
            agent("abandoned", state: .forgotten, minutesAgo: 5_760),
            agent("live", state: .working, minutesAgo: 1),
        ]).projects().map(\.name)
        expectEqual(order.first, "live")
    }

    // The ordering bug that made the screen answer the wrong question: sorting
    // everything quiet by recency put lunch above last Tuesday.
    TestKit.test("forgotten work rises above work you merely stepped away from") {
        let order = LiveState(agents: [
            agent("lunch", state: .quiet, minutesAgo: 90),
            agent("tuesday", state: .forgotten, minutesAgo: 5_760),
        ]).projects().map(\.name)
        expectEqual(order, ["tuesday", "lunch"])
    }

    TestKit.test("the longest abandoned comes first among the forgotten") {
        let order = LiveState(agents: [
            agent("yesterday", state: .forgotten, minutesAgo: 20 * 60),
            agent("last-week", state: .forgotten, minutesAgo: 7 * 24 * 60),
        ]).projects().map(\.name)
        expectEqual(order, ["last-week", "yesterday"], "the most surprising first")
    }

    TestKit.test("the most recent comes first among the ones you stepped away from") {
        let order = LiveState(agents: [
            agent("earlier", state: .quiet, minutesAgo: 400),
            agent("just-now", state: .quiet, minutesAgo: 70),
        ]).projects().map(\.name)
        expectEqual(order, ["just-now", "earlier"])
    }
}

/// Whose clock the screen runs on.
///
/// Measured on a real machine before this existed: thirty of forty-four
/// projects had transcript files newer than their last human turn by more than
/// an hour, and the worst was sixty days out — a project abandoned in July
/// whose file had been touched half an hour earlier by a background agent. Now
/// showed four such projects at the top as freshly active, and showed nothing
/// the person had actually walked away from. The screen was measuring the
/// robot's heartbeat and calling it attention.
func runAttentionTests() {
    TestKit.suite("Agent activity is not your attention")

    func agent(
        fileAgeHours: Double, humanAgeHours: Double?, name: String = "acme"
    ) -> LiveAgent {
        let fileAt = Date().addingTimeInterval(-fileAgeHours * 3_600)
        return LiveAgent(
            pid: 1, agent: .claudeCode, workingDirectory: "/p/\(name)",
            projectRoot: "/p/\(name)", repositoryName: name,
            lastActivityAt: fileAt,
            lastHumanActivityAt: humanAgeHours.map { Date().addingTimeInterval(-$0 * 3_600) },
            state: ActivityThresholds.default.state(forAge: fileAgeHours * 3_600)
        )
    }

    // The exact shape found on the real machine: an agent writing minutes ago,
    // a person who has not typed there in a fortnight.
    TestKit.test("an agent running unattended for a fortnight is forgotten work") {
        let unattended = agent(fileAgeHours: 0.01, humanAgeHours: 14 * 24)
        expectEqual(unattended.state, .working, "the agent really is busy")
        expectEqual(unattended.attentionState(), .forgotten, "and you really are gone")
        expect(unattended.isRunningUnattended)

        let project = try unwrap(LiveState(agents: [unattended]).projects().first)
        expect(project.isForgotten, "which is the whole point")
        expect(project.statusLabel.contains("you were last here"),
               "and the row says both facts: \(project.statusLabel)")
    }

    TestKit.test("an agent you are actually working with is not forgotten") {
        let together = agent(fileAgeHours: 0.01, humanAgeHours: 0.01)
        expectEqual(together.attentionState(), .working)
        expect(!together.isRunningUnattended)
        expect(!(try unwrap(LiveState(agents: [together]).projects().first).isForgotten))
    }

    // The inverse, and the reason the old rule hid so much: work you left days
    // ago whose agent is still ticking over.
    TestKit.test("a fresh file does not rescue a project you left in July") {
        let stale = agent(fileAgeHours: 0.5, humanAgeHours: 60 * 24)
        expect(LiveState(agents: [stale]).forgottenAgents.isEmpty == false,
               "counted as forgotten despite the file being half an hour old")
    }

    TestKit.test("how long you have been away is reported in your clock, not the file's") {
        let away = agent(fileAgeHours: 0.5, humanAgeHours: 9 * 24)
        expectEqual(away.awayLabel, "9 days")
        expect(!(away.lastActivityLabel.contains("day")), "the file is minutes old")
    }

    // Not every source can date a human turn. OpenCode's store does not
    // distinguish them, and a session longer than the tail read has none to
    // find. Unknown must not quietly become "recent" or "ancient".
    TestKit.test("when nobody can say, the agent's own reading stands") {
        let unknown = agent(fileAgeHours: 20, humanAgeHours: nil)
        expectEqual(unknown.attentionState(), unknown.state, "falls back rather than guessing")
        expect(unknown.awayLabel == nil, "and does not claim to know")
    }

    TestKit.suite("Turns nobody typed")

    // Scheduled tasks, hooks and background notifications arrive in the user's
    // slot. They are long enough to pass every substantive-text test and are
    // not something a person wrote. Six of forty-four projects had one as the
    // most recent thing in that slot.
    TestKit.test("a scheduled task is not you saying something") {
        expect(ClaudeTail.isMachineAuthored(
            "<scheduled-task name=\"weekly-update\" file=\"/Users/dev/.claude/x\">"
        ))
        expect(ClaudeTail.isMachineAuthored("<task-notification>\n<task-id>abc</task-id>"))
        expect(ClaudeTail.isMachineAuthored("<system-reminder>do the thing</system-reminder>"))
        expect(ClaudeTail.isMachineAuthored("<command-name>/model</command-name>"))
    }

    TestKit.test("something you typed that happens to start with a bracket still counts") {
        expect(!ClaudeTail.isMachineAuthored("<div> is not rendering, can you look at the layout"))
        expect(!ClaudeTail.isMachineAuthored("why does <Foo /> remount on every keystroke"))
        expect(!ClaudeTail.isMachineAuthored("add rate limiting to the webhook handler"))
    }
}
