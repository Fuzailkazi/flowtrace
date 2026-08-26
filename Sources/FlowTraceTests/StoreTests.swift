import Foundation
import FlowTraceCore

func runStoreTests() {
    TestKit.suite("Store — threads")

    TestKit.test("creating a thread opens its timeline") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        let thread = try store.create(WorkThread(
            title: "Build personal context app",
            intent: "Reduce the time I spend reconstructing my work.",
            nextStep: "Build the browser tab capture flow."
        ))

        let stored = try unwrap(try store.thread(id: thread.id))
        expectEqual(stored.title, "Build personal context app")
        expectEqual(stored.status, .active)

        let events = try store.timeline(threadId: thread.id)
        expectEqual(events.count, 1, "timeline entries")
        expectEqual(events.first?.type, .created)
    }

    TestKit.test("a detected thread records that it was detected") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        let thread = try store.create(WorkThread(
            title: "Finish OAuth",
            origin: .detected,
            detectionEvidence: sampleEvidence()
        ))
        let events = try store.timeline(threadId: thread.id)
        expectEqual(events.first?.type, .detected)
        expectEqual(events.first?.metadata["repository"], "/Users/dev/acme")
    }

    // Only fields that carry intent produce timeline entries — not every keystroke.
    TestKit.test("editing records next step, intent and blocker changes") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        var thread = try store.create(WorkThread(title: "Ship landing page"))

        thread.nextStep = "Write the hero copy"
        thread.blocker = "Waiting on final logo"
        thread = try store.update(thread)

        let types = try store.timeline(threadId: thread.id).map(\.type)
        expect(types.contains(.nextStepUpdated), "expected nextStepUpdated in \(types)")
        expect(types.contains(.blockerSet), "expected blockerSet in \(types)")
        expect(thread.isBlocked)

        thread.blocker = nil
        thread = try store.update(thread)
        expect(try store.timeline(threadId: thread.id).map(\.type).contains(.blockerCleared))
        expect(!thread.isBlocked)
    }

    TestKit.test("resuming a paused thread reactivates it and stamps the time") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        let created = try store.create(WorkThread(title: "Refund flow"))
        _ = try store.setStatus(.paused, threadId: created.id)

        let resumed = try unwrap(try store.resume(threadId: created.id))
        expectEqual(resumed.status, .active)
        expectNotNil(resumed.lastResumedAt, "lastResumedAt")
        expect(try store.timeline(threadId: created.id).map(\.type).contains(.resumed))
    }

    TestKit.suite("Store — captures")

    TestKit.test("attaching tabs links them and logs one timeline entry") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        let thread = try store.create(WorkThread(title: "OAuth research"))

        let saved = try store.attach(tabs: [
            BrowserContext(browser: "Chrome", pageTitle: "OAuth 2.0 spec",
                           url: "https://oauth.net/2/", note: "the actual spec"),
            BrowserContext(browser: "Chrome", pageTitle: "PKCE explained",
                           url: "https://example.com/pkce"),
        ], to: thread.id)

        expectEqual(saved.count, 2, "saved tabs")
        expectEqual(try store.tabs(threadId: thread.id).count, 2, "linked tabs")

        let attachEvents = try store.timeline(threadId: thread.id)
            .filter { $0.type == .tabAttached }
        expectEqual(attachEvents.count, 1, "one entry for a batch")
        expectEqual(attachEvents.first?.metadata["count"], "2")
    }

    TestKit.test("a tab knows which thread it belongs to") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        let thread = try store.create(WorkThread(title: "Pricing research"))
        _ = try store.attach(tabs: [
            BrowserContext(browser: "Brave", pageTitle: "Stripe pricing",
                           url: "https://stripe.com/pricing"),
        ], to: thread.id)

        let found = try store.threadForURL("https://stripe.com/pricing")
        expectEqual(found?.id, thread.id)
        expectNil(try store.threadForURL("https://example.com/never-seen"))
    }

    TestKit.test("attaching a repository snapshots its git state") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        let thread = try store.create(WorkThread(title: "API work"))
        _ = try store.attach(code: CodeContext(
            agentName: .claudeCode,
            repositoryName: "acme",
            repositoryPath: "/Users/dev/acme",
            branch: "feat/oauth",
            latestCommit: "abc123",
            dirtyFileCount: 4
        ), to: thread.id)

        expectEqual(try store.codeContexts(threadId: thread.id).count, 1)

        // A later probe with different state reports what moved.
        let later = RepoSnapshot(
            repositoryPath: "/Users/dev/acme", branch: "main",
            headSha: "def456", dirtyFileCount: 6
        )
        let change = try unwrap(try store.change(for: "/Users/dev/acme", against: later))
        expect(change.newCommits)
        expectEqual(change.dirtyDelta, 2)
        expectEqual(change.branchChanged?.to, "main")
    }

    TestKit.test("deleting a thread removes everything hanging off it") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        let thread = try store.create(WorkThread(title: "Throwaway"))
        _ = try store.attach(tabs: [
            BrowserContext(browser: "Chrome", pageTitle: "Doc", url: "https://x.test"),
        ], to: thread.id)
        _ = try store.addNote(Note(workThreadId: thread.id, content: "a note"))

        try store.delete(threadId: thread.id)

        expectNil(try store.thread(id: thread.id))
        expectEqual(try store.tabs(threadId: thread.id).count, 0, "orphan tabs")
        expectEqual(try store.notes(threadId: thread.id).count, 0, "orphan notes")
        expectEqual(try store.search("Doc").count, 0, "orphan search entries")
    }
}

func sampleEvidence() -> DetectionEvidence {
    DetectionEvidence(
        repositoryPath: "/Users/dev/acme",
        repositoryName: "acme",
        branch: "feat/oauth",
        dirtyFileCount: 4,
        daysSinceLastCommit: 12,
        unpushedCommitCount: 2,
        sessionCount: 3,
        agents: [.claudeCode],
        lastPrompt: "now add refresh token rotation"
    )
}
