import Foundation
import FlowTraceCore

func runAdapterTests(fixtures: URL) {
    TestKit.suite("Claude Code adapter")

    TestKit.test("extracts session metadata from a transcript") {
        let adapter = ClaudeCodeAdapter(root: fixtures.appendingPathComponent("claude"))
        let sessions = try adapter.discoverSessions(cache: nil)
        expectEqual(sessions.count, 1, "session count")

        let session = try unwrap(sessions.first, "session")
        expectEqual(session.agent, .claudeCode)
        expectEqual(session.id, "aaaaaaaa-1111-2222-3333-444444444444")
        expectEqual(session.cwd, "/Users/dev/acme")
        expectEqual(session.branch, "feat/oauth")
        expectEqual(session.title, "Add Google OAuth")
        expectEqual(session.firstPrompt, "add google oauth to the login page")
    }

    // Claude Code injects skill bodies and slash-command expansions as user turns
    // flagged `isMeta`. Reading those as intent produced proposals titled
    // "Base directory for this skill: …", which is exactly the kind of thing that
    // destroys trust in a detector.
    TestKit.test("ignores isMeta injections, sidechains and tool results") {
        let adapter = ClaudeCodeAdapter(root: fixtures.appendingPathComponent("claude"))
        let session = try unwrap(try adapter.discoverSessions(cache: nil).first)

        for prompt in [session.firstPrompt, session.lastPrompt, session.lastSubstantivePrompt] {
            expectNotContains(prompt, "Base directory for this skill")
            expectNotContains(prompt, "sidechain probe")
        }
        expectEqual(session.messageCount, 3, "real user turns")
    }

    // "do it" really is the last thing the user said, but it is a useless next
    // step, so the last actual instruction is tracked alongside it.
    TestKit.test("separates a bare acknowledgement from the last instruction") {
        let adapter = ClaudeCodeAdapter(root: fixtures.appendingPathComponent("claude"))
        let session = try unwrap(try adapter.discoverSessions(cache: nil).first)

        expectEqual(session.lastPrompt, "do it")
        expectEqual(session.lastSubstantivePrompt, "now add refresh token rotation before we ship")
        expectEqual(session.resumePrompt, "now add refresh token rotation before we ship")
    }

    TestKit.suite("Codex adapter")

    TestKit.test("reads session_meta and takes its title from session_index") {
        let adapter = CodexAdapter(root: fixtures.appendingPathComponent("codex"))
        let sessions = try adapter.discoverSessions(cache: nil)
        expectEqual(sessions.count, 1, "session count")

        let session = try unwrap(sessions.first)
        expectEqual(session.agent, .codex)
        expectEqual(session.id, "019cc2c5-f44e-7f03-9ea4-ca5653d3cb30")
        expectEqual(session.cwd, "/Users/dev/acme/packages/api")
        expectEqual(session.title, "Wire API routes to OAuth")
        expectEqual(session.firstPrompt, "wire the api routes to the new oauth service")
        expectEqual(session.lastPrompt, "yes")
        expectEqual(session.resumePrompt, "wire the api routes to the new oauth service")
    }

    TestKit.test("skips the replayed environment_context block") {
        let adapter = CodexAdapter(root: fixtures.appendingPathComponent("codex"))
        let session = try unwrap(try adapter.discoverSessions(cache: nil).first)
        expectNotContains(session.firstPrompt, "environment_context")
    }

    TestKit.suite("Prompt classification")

    TestKit.test("acknowledgements are not instructions") {
        expect(!AgentSession.isSubstantive("do it"))
        expect(!AgentSession.isSubstantive("Yes."))
        expect(!AgentSession.isSubstantive("continue"))
        expect(AgentSession.isSubstantive("now add refresh token rotation"))
    }
}
