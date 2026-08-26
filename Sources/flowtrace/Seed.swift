import Foundation
import ArgumentParser
import FlowTraceCore

/// Fills a database with realistic threads for development and screenshots.
///
/// Writes to a throwaway file by default so it can never land on top of real
/// work; `--into-real-database` is the deliberate opt-in.
struct Seed: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create realistic sample data for development."
    )

    @Flag(name: .long, help: "Seed the real FlowTrace database instead of a scratch copy.")
    var intoRealDatabase = false

    @Flag(name: .long, help: "Remove everything first.")
    var reset = false

    func run() throws {
        let url = intoRealDatabase
            ? FlowTraceDatabase.defaultURL
            : FlowTraceDatabase.supportDirectory.appendingPathComponent("seed.sqlite")

        let store = try Store(url: url)
        if reset { try store.deleteAllData() }

        let now = Date()
        func daysAgo(_ days: Int) -> Date { now.addingTimeInterval(-Double(days) * 86_400) }

        // 1. The canonical example from the brief.
        var app = try store.create(WorkThread(
            title: "Build personal context app",
            intent: "I want to test whether I can reduce the time I spend reconstructing my work.",
            nextStep: "Build the browser tab capture flow.",
            blocker: "Need to decide whether to use Electron or Tauri.",
            priority: .high,
            tags: ["tooling", "spike"],
            createdAt: daysAgo(9)
        ))
        _ = try store.attach(tabs: [
            BrowserContext(browser: "Google Chrome", pageTitle: "Tauri vs Electron — bundle size",
                           url: "https://tauri.app/start/", note: "the comparison I keep re-reading",
                           capturedAt: daysAgo(8)),
            BrowserContext(browser: "Google Chrome", pageTitle: "MenuBarExtra | Apple Developer",
                           url: "https://developer.apple.com/documentation/swiftui/menubarextra",
                           capturedAt: daysAgo(8)),
        ], to: app.id)
        _ = try store.addNote(Note(
            workThreadId: app.id,
            content: "Going native: the app is resident all day and every integration it needs "
                + "is a native API. Revisit only if Windows ever matters.",
            isDecision: true, createdAt: daysAgo(6)
        ))
        app.blocker = nil
        app.nextStep = "Wire the extension to the local endpoint."
        _ = try store.update(app)

        // 2. Blocked, so the dashboard's blocked section has something in it.
        var auth = try store.create(WorkThread(
            title: "Authentication rebuild",
            intent: "Move off session cookies before the security review.",
            nextStep: "Add refresh token rotation",
            priority: .high, tags: ["security", "backend"], createdAt: daysAgo(21)
        ))
        auth.blocker = "Waiting on the SSO tenant from IT"
        _ = try store.update(auth)
        _ = try store.attach(code: CodeContext(
            agentName: .claudeCode, repositoryName: "acme-api",
            repositoryPath: "/Users/dev/acme-api", branch: "feat/oauth",
            latestCommit: "9f3c1a20b4", note: "token service lives in src/auth",
            nextStep: "Rotate refresh tokens", capturedAt: daysAgo(14), dirtyFileCount: 4
        ), to: auth.id)

        // 3. Paused.
        let landing = try store.create(WorkThread(
            title: "Landing page refresh",
            intent: "The hero doesn't say what we actually do.",
            nextStep: "Rewrite the hero copy", status: .paused,
            priority: .medium, tags: ["marketing"], createdAt: daysAgo(30)
        ))
        _ = try store.setStatus(.paused, threadId: landing.id)

        // 4. Detected, so proposal-derived threads are represented too.
        _ = try store.create(WorkThread(
            title: "Replace ChatGPT key with Gemini API key · cap",
            intent: "swap the provider before the trial runs out",
            nextStep: "what env should i share w vercel for deployment",
            priority: .medium, createdAt: daysAgo(23), origin: .detected,
            detectionEvidence: DetectionEvidence(
                repositoryPath: "/Users/dev/projects/cap", repositoryName: "cap",
                branch: "main", dirtyFileCount: 3, daysSinceLastCommit: 23,
                unpushedCommitCount: 0, sessionCount: 2,
                agents: [.claudeCode, .codex],
                lastPrompt: "what env should i share w vercel for deployment",
                lastSessionAt: daysAgo(23)
            )
        ))

        // 5. Completed.
        let shipped = try store.create(WorkThread(
            title: "Refund flow", intent: "Customers couldn't self-serve refunds.",
            nextStep: "", priority: .low, tags: ["billing"], createdAt: daysAgo(60)
        ))
        _ = try store.setStatus(.completed, threadId: shipped.id)

        let counts = try store.counts()
        print("")
        print("  \(Term.green("✓")) seeded \(counts["threads"] ?? 0) threads, "
              + "\(counts["tabs"] ?? 0) tabs, \(counts["repositories"] ?? 0) repositories")
        print("  \(Term.dim(url.path))")
        if !intoRealDatabase {
            print("  \(Term.dim("Scratch database — pass --into-real-database to seed the app's own."))")
        }
        print("")
    }
}
