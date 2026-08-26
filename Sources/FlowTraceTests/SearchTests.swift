import Foundation
import FlowTraceCore

func runSearchTests() {
    TestKit.suite("Search")

    func populated() throws -> Store {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        let auth = try store.create(WorkThread(
            title: "Authentication rebuild",
            intent: "Move off session cookies before the audit.",
            nextStep: "Add refresh token rotation",
            tags: ["security", "backend"]
        ))
        _ = try store.attach(tabs: [
            BrowserContext(browser: "Chrome", pageTitle: "OAuth 2.0 spec",
                           url: "https://oauth.net/2/", note: "canonical reference"),
        ], to: auth.id)
        _ = try store.attach(code: CodeContext(
            agentName: .openCode, repositoryName: "acme-api",
            repositoryPath: "/Users/dev/acme-api", branch: "feat/oauth",
            note: "OpenCode session on the token service"
        ), to: auth.id)

        var landing = try store.create(WorkThread(
            title: "Landing page refresh",
            intent: "The hero does not say what we do.",
            nextStep: "Rewrite hero copy"
        ))
        landing.blocker = "Waiting on the new logo from design"
        _ = try store.update(landing)
        _ = try store.addNote(Note(
            workThreadId: landing.id,
            content: "Decided to keep the pricing table above the fold.",
            isDecision: true
        ))
        return store
    }

    // The examples the product spec calls out by name.
    TestKit.test("finds threads by intent, blocker, url, repo and agent name") {
        let store = try populated()
        expect(try !store.search("authentication").isEmpty, "authentication")
        expect(try !store.search("landing page").isEmpty, "landing page")
        expect(try !store.search("blocked").isEmpty, "blocked")
        expect(try !store.search("oauth.net").isEmpty, "url")
        expect(try !store.search("acme-api").isEmpty, "repository")
        expect(try !store.search("pricing table").isEmpty, "note text")
    }

    TestKit.test("partial words match — 'auth' finds authentication") {
        let store = try populated()
        expect(try !store.search("auth").isEmpty, "prefix match")
        expect(try !store.search("refre").isEmpty, "prefix match mid-field")
    }

    // "OpenCode" is one token; searching "code" is a substring, not a prefix,
    // so the FTS prefix query misses it and the fallback has to catch it.
    TestKit.test("substring inside a word still matches via fallback") {
        let store = try populated()
        expect(try !store.search("Code").isEmpty, "substring of OpenCode")
    }

    TestKit.test("punctuation and operators can't break the query") {
        let store = try populated()
        _ = try store.search("auth OR \"")
        _ = try store.search("C++ *")
        _ = try store.search("   ")
        expectEqual(try store.search("").count, 0, "empty query")
    }

    TestKit.test("every hit points at the thread to open") {
        let store = try populated()
        let hits = try store.search("oauth")
        expect(!hits.isEmpty)
        for hit in hits {
            expectNotNil(try store.thread(id: hit.threadId), "hit \(hit.kind) target")
        }
    }

    TestKit.test("edits are reflected immediately") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        var thread = try store.create(WorkThread(title: "Placeholder"))
        expectEqual(try store.search("kubernetes").count, 0)

        thread.nextStep = "Migrate the worker to kubernetes"
        _ = try store.update(thread)
        expect(try !store.search("kubernetes").isEmpty, "after edit")
    }
}
