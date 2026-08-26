import Foundation
import FlowTraceCore

/// A real git repository in a temp directory, so the detector is exercised
/// against actual `git` output rather than a mock of it.
final class TempRepo {
    let root: URL

    init(name: String) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flowtrace-tests-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main")
        git("config", "user.email", "test@flowtrace.local")
        git("config", "user.name", "FlowTrace Tests")
        git("config", "commit.gpgsign", "false")
    }

    var path: String { root.path }

    func subdirectory(_ relative: String) throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    func write(_ relative: String, _ contents: String = "x") {
        let url = root.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Commits everything staged, backdated by `daysAgo`.
    func commit(_ message: String, daysAgo: Int) {
        git("add", "-A")
        let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        let stamp = ISO8601DateFormatter().string(from: date)
        git("commit", "-q", "-m", message, env: [
            "GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp,
        ])
    }

    func checkout(_ branch: String) { git("checkout", "-q", "-b", branch) }

    @discardableResult
    func git(_ arguments: String..., env: [String: String] = [:]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment.merge(env) { _, new in new }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    deinit {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

/// Test repositories live under the temp directory, which the shipping config
/// treats as noise. Tests that aren't about filtering opt out of it.
func testConfig(
    coldDays: Int = 2,
    deadDays: Int = 90,
    maxProposals: Int = 40
) -> DetectorConfig {
    DetectorConfig(
        coldDays: coldDays, deadDays: deadDays,
        maxProposals: maxProposals, noisePathFragments: []
    )
}

/// Feeds the detector a fixed set of sessions, so scoring can be tested without
/// depending on anything in the user's home directory.
struct StubAdapter: AgentAdapter {
    let agent: AgentName
    let sessions: [AgentSession]
    var searchPaths: [String] { [] }
    var isAvailable: Bool { true }
    func discoverSessions(cache: SessionCache?) throws -> [AgentSession] { sessions }
}

private func session(
    id: String = UUID().uuidString,
    agent: AgentName = .claudeCode,
    cwd: String,
    title: String? = nil,
    first: String? = "start the thing",
    last: String? = "now finish the thing",
    daysAgo: Int = 10
) -> AgentSession {
    AgentSession(
        id: id, agent: agent, cwd: cwd, branch: nil, title: title,
        firstPrompt: first, lastPrompt: last, lastSubstantivePrompt: last,
        startedAt: Date().addingTimeInterval(-Double(daysAgo) * 86_400),
        lastActivityAt: Date().addingTimeInterval(-Double(daysAgo) * 86_400),
        filePath: "/dev/null", messageCount: 2
    )
}

func runDetectorTests() {
    TestKit.suite("Detector — what counts as abandoned")

    TestKit.test("dirty and cold is proposed, with its evidence attached") {
        let repo = try TempRepo(name: "acme")
        repo.write("README.md", "hello")
        repo.commit("initial", daysAgo: 30)
        repo.write("src/auth.ts", "unfinished")

        let detector = AbandonedWorkDetector(adapters: [
            StubAdapter(agent: .claudeCode, sessions: [
                session(cwd: repo.path, title: "Add Google OAuth", daysAgo: 30),
            ]),
        ])
        let result = try detector.scan(config: testConfig())

        expectEqual(result.proposals.count, 1, "proposals")
        let proposal = try unwrap(result.proposals.first)
        expectEqual(proposal.evidence.repositoryName, "acme")
        expectEqual(proposal.evidence.dirtyFileCount, 1)
        expect(proposal.evidence.daysSinceLastCommit >= 29, "days cold")
        // The repository is the identity you recognise; the agent's session title
        // describes what you were doing inside it and rides along as context.
        expectEqual(proposal.suggestedTitle, "acme", "repo name is the title")
        expectEqual(proposal.evidence.sessionTitle, "Add Google OAuth", "session title kept")
        expectEqual(proposal.suggestedNextStep, "now finish the thing")
    }

    // A clean, pushed, cold repository is finished work, not abandoned work.
    // Proposing it would be the fastest way to make the detector untrustworthy.
    TestKit.test("clean and committed is never proposed, however cold") {
        let repo = try TempRepo(name: "tidy")
        repo.write("README.md", "hello")
        repo.commit("initial", daysAgo: 400)

        let detector = AbandonedWorkDetector(adapters: [
            StubAdapter(agent: .claudeCode, sessions: [session(cwd: repo.path, daysAgo: 200)]),
        ])
        expectEqual(try detector.scan(config: testConfig()).proposals.count, 0, "proposals")
    }

    TestKit.test("work touched today is not abandoned yet") {
        let repo = try TempRepo(name: "current")
        repo.write("README.md", "hello")
        repo.commit("initial", daysAgo: 0)
        repo.write("wip.ts", "in progress")

        let detector = AbandonedWorkDetector(adapters: [
            StubAdapter(agent: .claudeCode, sessions: [session(cwd: repo.path, daysAgo: 0)]),
        ])
        expectEqual(try detector.scan(config: testConfig()).proposals.count, 0, "proposals")
    }

    // The original probe of this machine reported 16 abandoned repositories, but
    // three of them were subfolders of a single monorepo. Collapsing working
    // directories onto their git root is what makes the count honest.
    TestKit.test("subfolders of one monorepo collapse into one proposal") {
        let repo = try TempRepo(name: "mono")
        repo.write("packages/web/index.ts", "a")
        repo.write("packages/api/index.ts", "b")
        repo.commit("initial", daysAgo: 40)
        repo.write("packages/web/next.ts", "dirty")

        let web = try repo.subdirectory("packages/web")
        let api = try repo.subdirectory("packages/api")

        let detector = AbandonedWorkDetector(adapters: [
            StubAdapter(agent: .claudeCode, sessions: [
                session(cwd: web, daysAgo: 40),
                session(cwd: api, daysAgo: 38),
                session(cwd: repo.path, daysAgo: 36),
            ]),
        ])
        let result = try detector.scan(config: testConfig())

        expectEqual(result.proposals.count, 1, "one repository, one proposal")
        expectEqual(result.proposals.first?.evidence.sessionCount, 3, "all sessions credited")
        expectEqual(result.repositoriesProbed, 1, "repositories probed")
    }

    TestKit.test("working directories that no longer exist are counted, not proposed") {
        let detector = AbandonedWorkDetector(adapters: [
            StubAdapter(agent: .codex, sessions: [
                session(cwd: "/Users/dev/deleted-project", daysAgo: 20),
                session(cwd: "/Users/dev/also-gone", daysAgo: 25),
            ]),
        ])
        let result = try detector.scan(config: testConfig())
        expectEqual(result.proposals.count, 0, "proposals")
        expectEqual(result.missingPaths, 2, "missing paths")
    }

    TestKit.test("a repository the user ignored is skipped") {
        let repo = try TempRepo(name: "ignored")
        repo.write("README.md", "hello")
        repo.commit("initial", daysAgo: 30)
        repo.write("dirty.ts", "x")

        // The ignore is stored with the path spelling the user's picker gave us,
        // which on macOS is often /var/... while git reports /private/var/...
        let detector = AbandonedWorkDetector(
            adapters: [StubAdapter(agent: .claudeCode, sessions: [session(cwd: repo.path, daysAgo: 30)])],
            ignoredPaths: [repo.path]
        )
        expectEqual(try detector.scan(config: testConfig()).proposals.count, 0, "proposals")
    }

    // The original build ranked by staleness, which pushed six-month-old repos to
    // the top — the least resumable work presented most prominently. Value peaks a
    // week or two out: long enough to have lost the thread, recent enough to care.
    TestKit.test("recent unfinished work outranks stale work") {
        let recent = try TempRepo(name: "recent")
        recent.write("a.ts", "x"); recent.commit("initial", daysAgo: 9); recent.write("b.ts", "dirty")
        let stale = try TempRepo(name: "stale")
        stale.write("a.ts", "x"); stale.commit("initial", daysAgo: 75); stale.write("b.ts", "dirty")

        let detector = AbandonedWorkDetector(adapters: [
            StubAdapter(agent: .claudeCode, sessions: [
                session(cwd: recent.path, daysAgo: 9),
                session(cwd: stale.path, daysAgo: 75),
            ]),
        ])
        let proposals = try detector.scan(config: testConfig()).proposals
        expectEqual(proposals.count, 2, "proposals")
        expectEqual(proposals.first?.evidence.repositoryName, "recent", "recent work first")
    }

    // Past a few months it isn't paused, it's over. Listing it is a reproach, not
    // a prompt to act.
    TestKit.test("work older than the dead threshold is dropped entirely") {
        let ancient = try TempRepo(name: "ancient")
        ancient.write("a.ts", "x"); ancient.commit("initial", daysAgo: 200)
        ancient.write("b.ts", "dirty")

        let detector = AbandonedWorkDetector(adapters: [
            StubAdapter(agent: .claudeCode, sessions: [session(cwd: ancient.path, daysAgo: 200)]),
        ])
        expectEqual(try detector.scan(config: testConfig()).proposals.count, 0, "proposals")
    }

    // A tree dirty only with lockfiles is what `npm install` left behind.
    TestKit.test("a repository dirty only with generated files is not work") {
        let repo = try TempRepo(name: "installed")
        repo.write("src/main.ts", "x"); repo.commit("initial", daysAgo: 20)
        repo.write("package-lock.json", "{}")

        let detector = AbandonedWorkDetector(adapters: [
            StubAdapter(agent: .claudeCode, sessions: [
                session(cwd: repo.path, first: nil, last: nil, daysAgo: 20),
            ]),
        ])
        expectEqual(try detector.scan(config: testConfig()).proposals.count, 0, "proposals")
    }

    // Agent orchestrators and tutorials generate transcripts and dirty files, but
    // they are never work you intend to come back to.
    TestKit.test("agent scratch worktrees are filtered out") {
        let repo = try TempRepo(name: "scratch")
        repo.write("a.ts", "x"); repo.commit("initial", daysAgo: 20); repo.write("b.ts", "dirty")

        let detector = AbandonedWorkDetector(adapters: [
            StubAdapter(agent: .codex, sessions: [session(cwd: repo.path, daysAgo: 20)]),
        ])
        // The temp directory stands in for any path fragment on the noise list.
        let config = DetectorConfig(noisePathFragments: ["/var/folders/", "/private/var/folders/"])
        expectEqual(try detector.scan(config: config).proposals.count, 0, "proposals")
    }

    TestKit.test("the changed files you recognise come before generated ones") {
        let evidence = DetectionEvidence(
            repositoryPath: "/tmp/x", repositoryName: "x", branch: "main",
            dirtyFileCount: 3, daysSinceLastCommit: 5, unpushedCommitCount: 0,
            sessionCount: 1, agents: [.claudeCode],
            changedFiles: ["pnpm-lock.yaml", "src/IntentTrace.jsx", "dist/bundle.min.js"]
        )
        expectContains(evidence.fileSummary, "IntentTrace.jsx")
        expectNotContains(evidence.fileSummary, "pnpm-lock.yaml")
    }

    TestKit.suite("Detector — proposals become threads")

    TestKit.test("a dismissed proposal is not offered again on rescan") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        let proposal = ThreadProposal(
            repositoryPath: "/Users/dev/acme", branch: "main",
            suggestedTitle: "Finish OAuth", score: 5, evidence: sampleEvidence()
        )
        _ = try store.mergeProposals([proposal])
        let pending = try store.pendingProposals()
        expectEqual(pending.count, 1)

        try store.dismiss(proposal: try unwrap(pending.first))
        // Same finding, rediscovered by a later scan.
        _ = try store.mergeProposals([proposal])
        expectEqual(try store.pendingProposals().count, 0, "dismissed stays dismissed")
    }

    TestKit.test("accepting creates a thread with the repository and evidence attached") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        _ = try store.mergeProposals([ThreadProposal(
            repositoryPath: "/Users/dev/acme", branch: "feat/oauth",
            suggestedTitle: "Finish OAuth",
            suggestedIntent: "add google oauth to the login page",
            suggestedNextStep: "now add refresh token rotation",
            score: 6, evidence: sampleEvidence()
        )])
        let proposal = try unwrap(try store.pendingProposals().first)

        let thread = try store.accept(proposal: proposal)
        expectEqual(thread.origin, .detected)
        expectEqual(thread.nextStep, "now add refresh token rotation")
        expectNotNil(thread.detectionEvidence, "evidence kept on the thread")

        expectEqual(try store.codeContexts(threadId: thread.id).count, 1, "repository attached")
        expect(try store.timeline(threadId: thread.id).map(\.type).contains(.detected))
        expectEqual(try store.pendingProposals().count, 0, "accepted leaves the queue")
    }

    // The proposal is a suggestion. What gets stored is what the user approved.
    TestKit.test("edits made during review are what get stored") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        _ = try store.mergeProposals([ThreadProposal(
            repositoryPath: "/Users/dev/acme", branch: "main",
            suggestedTitle: "Machine guess", score: 4, evidence: sampleEvidence()
        )])
        let proposal = try unwrap(try store.pendingProposals().first)

        let thread = try store.accept(proposal: proposal, edited: (
            title: "Ship refund flow",
            intent: "Customers can't self-serve refunds.",
            nextStep: "Add the confirmation dialog"
        ))
        expectEqual(thread.title, "Ship refund flow")
        expectEqual(thread.intent, "Customers can't self-serve refunds.")
    }

    TestKit.test("evidence reads back as plain sentences") {
        let reasons = sampleEvidence().reasons
        expect(reasons.contains("4 uncommitted files"), "\(reasons)")
        expect(reasons.contains("2 unpushed commits"), "\(reasons)")
        expect(reasons.contains("last commit 12d ago"), "\(reasons)")
    }
}
