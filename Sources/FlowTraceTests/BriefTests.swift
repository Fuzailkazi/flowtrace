import Foundation
import FlowTraceCore

func runBriefTests() {
    TestKit.suite("Redaction")

    // A scan of ~/.claude/projects on the machine this was written on found five
    // live API keys sitting in prompts. The brief is injected into an agent's
    // context, so a key that survives here travels further than one in a database.
    TestKit.test("removes credentials while leaving the sentence readable") {
        let cases: [(String, String)] = [
            ("update the chatgpt key with this key sk-proj-AbCdEf0123456789XyZw", "api key"),
            ("use AIzaSyD-abcdefghijklmnopqrstuvwxyz012345 for maps", "api key"),
            ("my token is ghp_AbCdEf0123456789AbCdEf0123456789", "token"),
            ("set AKIAIOSFODNN7EXAMPLE as the id", "aws key"),
            ("connect to postgres://admin:hunter2@db.internal:5432/app", "connection string"),
            // Matches the VAR=value rule before the provider-prefix one, so it is
            // labelled "secret". Which marker wins doesn't matter; removal does.
            ("export STRIPE_SECRET_KEY=sk_live_0123456789abcdef", "secret"),
        ]
        for (input, expectedMarker) in cases {
            let result = Redaction.redact(input)
            expect(result.redactionCount >= 1, "nothing redacted in: \(input)")
            expectContains(result.text, "[\(expectedMarker) removed]")
            // The words around it have to survive, or the memory aid is destroyed.
            let firstWord = String(input.split(separator: " ").first ?? "")
            expectContains(result.text, firstWord)
        }
    }

    TestKit.test("ordinary prompts are left completely alone") {
        for text in [
            "now add refresh token rotation before we ship",
            "raise a pr for cyan color update",
            "the commit is 9f3c1a20b4e5d6 — revert it",
            "what env should i share w vercel fr deployment",
        ] {
            let result = Redaction.redact(text)
            expectEqual(result.redactionCount, 0, "false positive on: \(text)")
            expectEqual(result.text, text)
        }
    }

    // "[api key removed]" is not a memory aid.
    TestKit.test("a prompt that was only a pasted key is dropped, not shown as a marker") {
        let result = Redaction.redact("sk-proj-AbCdEf0123456789XyZwAbCdEf0123")
        expect(Redaction.isOnlyRedactions(result), "should be recognised as content-free")

        let mixed = Redaction.redact("swap the key for sk-proj-AbCdEf0123456789XyZw please")
        expect(!Redaction.isOnlyRedactions(mixed), "a real sentence should survive")
    }

    TestKit.suite("Resume brief")

    func sampleBrief(days: Int = 3, dirty: Int = 3, prompts: [String] = ["fix the auth redirect"]) -> ResumeBrief {
        ResumeBrief(
            repositoryName: "acme", repositoryPath: "/tmp/acme", branch: "feat/oauth",
            daysSinceActivity: days, hoursSinceActivity: days * 24,
            changedFiles: ["src/IntentTrace.jsx", "pnpm-lock.yaml", "src/intent.js"],
            uncommittedCount: dirty, unpushedCount: 2,
            lastCommitSubject: "Expand support-mcp to 20 tools",
            recentPrompts: prompts, sessionTitle: "Add Google OAuth"
        )
    }

    TestKit.test("reads as prose an agent can resume from") {
        let text = sampleBrief().render()
        expectContains(text, "You worked on acme 3 days ago, on branch feat/oauth")
        expectContains(text, "Add Google OAuth")
        expectContains(text, "3 uncommitted files")
        expectContains(text, "2 commits not yet pushed")
        expectContains(text, "Expand support-mcp to 20 tools")
        expectContains(text, "fix the auth redirect")
    }

    // A lockfile in the "here's what you were editing" list wastes the one glance
    // the reader gives it.
    TestKit.test("names source files, not generated ones") {
        let text = sampleBrief().render()
        expectContains(text, "IntentTrace.jsx")
        expectContains(text, "intent.js")
        expectNotContains(text, "pnpm-lock.yaml")
    }

    TestKit.test("elapsed time reads the way people say it") {
        expectContains(sampleBrief(days: 1).render(), "yesterday")
        expectContains(sampleBrief(days: 5).render(), "5 days ago")
        var sameDay = sampleBrief(days: 0)
        sameDay.hoursSinceActivity = 4
        expectContains(sameDay.render(), "4 hours ago")
    }

    TestKit.test("stays inside its context budget") {
        let brief = sampleBrief(prompts: [
            "the first thing I asked which was reasonably long and detailed",
            "the second thing I asked, also fairly long and quite specific",
            "the third and final thing I asked before wandering off entirely",
        ])
        expect(brief.estimatedTokens < 400, "brief was ~\(brief.estimatedTokens) tokens")
    }

    TestKit.test("the hook payload carries the right event name") {
        let payload = sampleBrief().hookPayload()
        let data = try unwrap(payload.data(using: .utf8))
        let json = try unwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let output = try unwrap(json["hookSpecificOutput"] as? [String: Any])
        expectEqual(output["hookEventName"] as? String, "SessionStart")
        expectContains(output["additionalContext"] as? String, "You worked on acme")
    }

    TestKit.suite("Brief — when to say nothing")

    let builder = BriefBuilder()

    // A hook that fires on every session becomes noise, and noise gets uninstalled.
    TestKit.test("silent when you were just here") {
        let repo = try TempRepo(name: "warm")
        repo.write("a.ts", "x"); repo.commit("initial", daysAgo: 0)
        repo.write("b.ts", "dirty")
        expectNil(builder.build(repositoryPath: repo.path), "should be silent")
    }

    TestKit.test("silent when the tree is clean and nothing recent happened") {
        let repo = try TempRepo(name: "tidy")
        repo.write("a.ts", "x"); repo.commit("initial", daysAgo: 30)
        expectNil(builder.build(repositoryPath: repo.path), "should be silent")
    }

    TestKit.test("silent for work that is over rather than paused") {
        let repo = try TempRepo(name: "ancient")
        repo.write("a.ts", "x"); repo.commit("initial", daysAgo: 400)
        repo.write("b.ts", "dirty")
        expectNil(builder.build(repositoryPath: repo.path), "should be silent")
    }

    TestKit.test("silent for agent scratch worktrees") {
        let repo = try TempRepo(name: "scratch")
        repo.write("a.ts", "x"); repo.commit("initial", daysAgo: 10)
        repo.write("b.ts", "dirty")

        var config = BriefConfig()
        config.noisePathFragments = ["/var/folders/", "/private/var/folders/"]
        expectNil(builder.build(repositoryPath: repo.path, config: config), "should be silent")
    }

    TestKit.test("speaks up for cold work with loose ends") {
        let repo = try TempRepo(name: "paused")
        repo.write("src/auth.ts", "x"); repo.commit("wire up oauth", daysAgo: 6)
        repo.write("src/refresh.ts", "half done")

        var config = BriefConfig()
        config.noisePathFragments = []
        let brief = try unwrap(builder.build(repositoryPath: repo.path, config: config))

        expectEqual(brief.repositoryName, "paused")
        expectEqual(brief.uncommittedCount, 1)
        expectEqual(brief.lastCommitSubject, "wire up oauth")
        expectContains(brief.render(), "refresh.ts")
    }

    TestKit.test("a repository's own slug never swallows a longer neighbour") {
        // ~/armor/vid must not match ~/armor/videos.
        let short = ClaudeCodeAdapter.projectSlug(for: "/Users/dev/armor/vid")
        let long = ClaudeCodeAdapter.projectSlug(for: "/Users/dev/armor/videos")
        expect(long.hasPrefix(short), "precondition: the naive prefix does collide")
        expect(!long.hasPrefix(short + "-"), "separator-anchored match must not collide")
    }
}
