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
        let result = try detector.scan()

        expectEqual(result.proposals.count, 1, "proposals")
        let proposal = try unwrap(result.proposals.first)
        expectEqual(proposal.evidence.repositoryName, "acme")
        expectEqual(proposal.evidence.dirtyFileCount, 1)
        expect(proposal.evidence.daysSinceLastCommit >= 29, "days cold")
        expectContains(proposal.suggestedTitle, "Add Google OAuth")
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
        expectEqual(try detector.scan().proposals.count, 0, "proposals")
    }

    TestKit.test("work touched today is not abandoned yet") {
        let repo = try TempRepo(name: "current")
        repo.write("README.md", "hello")
        repo.commit("initial", daysAgo: 0)
        repo.write("wip.ts", "in progress")

        let detector = AbandonedWorkDetector(adapters: [
            StubAdapter(agent: .claudeCode, sessions: [session(cwd: repo.path, daysAgo: 0)]),
        ])
        expectEqual(try detector.scan().proposals.count, 0, "proposals")
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
        let result = try detector.scan()

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
        let result = try detector.scan()
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
        expectEqual(try detector.scan().proposals.count, 0, "proposals")
    }

    TestKit.test("older, colder work outranks newer work") {
        let old = try TempRepo(name: "old")
        old.write("a.ts", "x"); old.commit("initial", daysAgo: 120); old.write("b.ts", "dirty")
        let recent = try TempRepo(name: "recent")
        recent.write("a.ts", "x"); recent.commit("initial", daysAgo: 9); recent.write("b.ts", "dirty")

        let detector = AbandonedWorkDetector(adapters: [
            StubAdapter(agent: .claudeCode, sessions: [
                session(cwd: old.path, daysAgo: 120),
                session(cwd: recent.path, daysAgo: 9),
            ]),
        ])
        let proposals = try detector.scan().proposals
        expectEqual(proposals.count, 2, "proposals")
        expectEqual(proposals.first?.evidence.repositoryName, "old", "highest scoring first")
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
