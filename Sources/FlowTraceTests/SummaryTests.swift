import Foundation
import FlowTraceCore

func runSummaryTests() {
    TestKit.suite("Deterministic summary")

    let summarizer = DeterministicSummarizer()

    TestKit.test("states the intent the user actually wrote") {
        let summary = summarizer.summarize(SummaryInput(thread: WorkThread(
            title: "Authentication rebuild",
            intent: "Move off session cookies before the audit.",
            nextStep: "Add refresh token rotation"
        )))
        expectContains(summary.about, "Move off session cookies before the audit.")
        expectEqual(summary.likelyNextStep, "Add refresh token rotation")
    }

    TestKit.test("a blocker outranks the next step") {
        var thread = WorkThread(title: "Landing page", nextStep: "Rewrite hero copy")
        thread.blocker = "Waiting on the new logo"
        let summary = summarizer.summarize(SummaryInput(thread: thread))
        expectContains(summary.likelyNextStep, "Waiting on the new logo")
    }

    TestKit.test("a detected thread explains what was observed") {
        let thread = WorkThread(
            title: "Finish OAuth", origin: .detected, detectionEvidence: sampleEvidence()
        )
        let summary = summarizer.summarize(SummaryInput(thread: thread))
        expectContains(summary.about, "acme")
        expectContains(summary.about, "4 uncommitted files")
        expectContains(summary.likelyNextStep, "now add refresh token rotation")
    }

    TestKit.test("surfaces repositories that moved since you left") {
        let summary = summarizer.summarize(SummaryInput(
            thread: WorkThread(title: "API work"),
            repoChanges: ["acme-api": RepoChange(
                branchChanged: nil, newCommits: true, dirtyDelta: 3
            )]
        ))
        expect(summary.recently.contains { $0.contains("acme-api") }, "\(summary.recently)")
        expect(summary.recently.contains { $0.contains("new commits") }, "\(summary.recently)")
    }

    TestKit.test("prefers tabs the user bothered to annotate") {
        let thread = WorkThread(title: "OAuth research")
        let summary = summarizer.summarize(SummaryInput(thread: thread, tabs: [
            BrowserContext(browser: "Chrome", pageTitle: "Random SO answer", url: "https://so.test/1"),
            BrowserContext(browser: "Chrome", pageTitle: "OAuth 2.0 spec",
                           url: "https://oauth.net/2/", note: "the canonical reference"),
        ]))
        expect(summary.importantItems.contains { $0.contains("canonical reference") },
               "\(summary.importantItems)")
        expect(!summary.importantItems.contains { $0.contains("Random SO answer") },
               "unannotated tab should not outrank an annotated one")
    }

    // The product principle: the user must always know what a summary is based on.
    TestKit.test("always says what it was built from, and that nothing left the machine") {
        let summary = summarizer.summarize(SummaryInput(
            thread: WorkThread(title: "Anything"),
            tabs: [BrowserContext(browser: "Chrome", pageTitle: "One", url: "https://a.test")],
            code: [CodeContext(repositoryName: "acme", repositoryPath: "/tmp/acme")]
        ))
        expectContains(summary.basedOn, "1 repository")
        expectContains(summary.basedOn, "1 tab")
        expectContains(summary.basedOn, "No network request was made")
    }

    TestKit.test("says so plainly when a thread is empty, rather than inventing") {
        let summary = summarizer.summarize(SummaryInput(thread: WorkThread(title: "Brand new")))
        expectContains(summary.about, "No intent recorded")
        expectContains(summary.likelyNextStep, "No next step recorded")
        expect(summary.recently.contains { $0.contains("Nothing has happened") },
               "\(summary.recently)")
    }

    TestKit.suite("Path canonicalisation")

    // git reports /private/var/... where a folder picker reports /var/...
    // Two spellings of one directory must not read as two repositories.
    TestKit.test("resolves the /var and /private/var spellings to one path") {
        let a = FilePathCanon.canonical("/tmp")
        let b = FilePathCanon.canonical("/private/tmp")
        expectEqual(a, b, "canonical /tmp")
    }

    TestKit.test("a path that no longer exists is still usable") {
        let gone = FilePathCanon.canonical("/Users/dev/deleted-project")
        expect(!gone.isEmpty, "should not drop the path")
    }
}
