# FlowTrace as agent memory

An MCP server, so an agent can ask what FlowTrace knows *mid-session* rather than being told once at startup.

Not part of Tier 0. This is adoption work on the loop that already pays: `docs/strategy/2026-09-04-habit-and-adoption.md` finds that Loop A (write a note) has not formed even for the author — 4 notes ever, 0 project notes, against 1,181 ambient rows — while Loop B (see what you forgot) is already populated with no user behaviour at all. Every tool below is built from Loop B. It requires the user to change nothing.

## Problem

FlowTrace already feeds agents, once, in one direction. `Scripts/install-hook.sh` registers a `SessionStart` hook that runs `flowtrace brief --format hook --quiet`, and `ResumeBrief.hookPayload()` hands the result to Claude Code as `additionalContext`. That is a push: it fires before the session, it fires whether or not the model needs it, and it cannot answer anything the model thinks of afterwards.

Three questions arrive *during* a session and have no answer today:

1. **"What was I doing in this repository?"** — asked after a compact, or an hour in, or when the user says "carry on with the thing from Tuesday". The hook's context is by then thousands of tokens back and may have been summarised away. `BriefBuilder` can answer in under a second and nobody can ask it.
2. **"Is there unfinished work anywhere else?"** — the sharp edge, per `docs/strategy/2026-09-04-sharpness-positioning-and-market.md`: "cross-repository discovery, not single-repository recall". `flowtrace scan` reads 175 sessions across 23 repositories in 0.5 s. An agent asked to "tidy up the loose ends" has no way to reach it, and neither does an agent that should have said "you have 8 unpushed commits in a repo you stopped 38 days ago".
3. **"What is already running?"** — `flowtrace now` finds 8 servers, 7 of them forgotten. An agent about to start a dev server on port 3000 does not know that a process started in `tulu/frontend` is already holding it. This is not memory; it is collision avoidance, and it is the one answer here that changes what an agent *does* rather than what it says.

The distribution argument is the same one the strategy doc already makes — "the CLI is the product that spreads, the app is the product that retains" — carried one step further. An MCP server bypasses the GUI, the code-signing story and the quarantine flag entirely: it is a subcommand on a binary the user has already installed.

There is one thing standing in the way, and it is not a small one. **MCP is the first FlowTrace surface where a redaction failure leaves the device.** Every prior consumer is local — SQLite, the timeline, terminal output. `Redaction.swift:10-12` already names the exception: "This matters most for the brief, which is injected into an agent's context: a key that leaks there travels further than one sitting in a local database." This spec creates three more surfaces like the brief, and one of them reads from a path that is *not* redacted today.

## Approach

`flowtrace mcp` — a new subcommand speaking JSON-RPC 2.0 over stdio, exposing **three read-only tools and no write tool**, with every emitted string passing through one redaction choke point in `FlowTraceCore`.

Stdio, because the privacy properties fall out of the process model rather than being configured on top of it. The client spawns the server; the server's lifetime is the client's; there is no port, no bearer token, no CORS decision, no keychain read, and nothing for another process on the machine to connect to. The existing loopback server needs all four of those and they are each a place to be wrong — `LocalServerRoutes.swift:15-19` gates every route but `/health` on a keychain token, and `HTTP.serialize` had to learn to echo only extension origins after a wildcard `Access-Control-Allow-Origin` on `/health` let any web page fingerprint the install (`ServerTests.swift:150-153`). Stdio has no equivalent surface to get wrong.

The protocol layer is one line in, zero or one lines out, with no I/O of its own — the same shape as `LocalServer.route(_:) -> Response`, and for the same reason: `ServerTests.swift:4-5` exercises "the real request handling without binding a socket, so they're deterministic and don't need a free port". Framing and dispatch belong in `FlowTraceCore` so the Core-only `TestKit` harness can reach them; `Sources/flowtrace/MCP.swift` is a read loop and nothing else.

Alternatives considered and rejected:

- *Extend the existing loopback server with an MCP endpoint.* Three costs, each disqualifying on its own. The client would need the bearer token, which means copying a keychain secret into `~/.claude.json` in plaintext — strictly worse than having no secret to copy. The app or `flowtrace serve` would have to be running, whereas `Brief.run()` deliberately survives a missing database (`Brief.swift:43-46`: "a hook that fails because a database is missing is a hook that breaks `claude` for everyone who never opened the app") and MCP should inherit that. And it would turn a socket whose only current readers are a browser extension and the CLI into an authenticated *read* surface for transcript content.
- *A separate `flowtrace-mcp` binary.* Another executable to build, sign, notarise and tell people to install. A subcommand rides the install path that already exists, and appears in `FlowTraceCLI.configuration.subcommands` beside the nine verbs the user already has.
- *MCP resources rather than tools.* Resources are content a client browses and caches by URI. All three answers here are computed, cheap, and stale within minutes; a client that caches `flowtrace://brief` shows yesterday's brief. Tools only — the server declares `{"tools": {}}` and no other capability.
- *Adopt the official MCP Swift SDK.* It would track protocol revisions for us, which is real value — see the honest uncertainty in "Decisions to confirm". Rejected for now because the subset needed is `initialize`, `notifications/initialized`, `tools/list`, `tools/call` over newline-delimited JSON, which is roughly 250 lines against `JSONSerialization` — already the project's JSON tool everywhere from `hookPayload()` to `LocalServerRoutes` — and because "Two dependencies: GRDB for SQLite and Swift Argument Parser for the CLI. Nothing else" is a claim the README makes and the strategy doc treats as part of the moat. This is the weakest recommendation in the spec.
- *A `note` write tool.* Rejected on the product's own rules — the argument is in "Out of scope", because the position is that it should not be built rather than that it should be built later.

## Design

### 1. `MCPServer` (new, `Sources/FlowTraceCore/MCP/MCPServer.swift`)

```swift
/// One JSON-RPC line in, zero or one lines out. No sockets and no stdio, so the
/// whole protocol is testable the way `LocalServer.route` is.
///
/// Not `Sendable`, and deliberately: it is driven from exactly one thread — the
/// read loop in `Sources/flowtrace/MCP.swift` — which is why it needs no locking.
public final class MCPServer {
    public init(name: String, version: String, instructions: String, tools: [MCPTool])

    /// Nil for a notification, which JSON-RPC forbids replying to. Every other
    /// input produces exactly one line, including malformed JSON.
    public func respond(to line: String) -> String?
}

public struct MCPTool {
    public var name: String
    public var description: String
    /// JSON Schema, emitted verbatim by `tools/list`.
    public var inputSchema: [String: Any]
    /// Arguments in, one block of text out. Throwing produces a tool result with
    /// `isError: true` — never a JSON-RPC error, because a client that receives a
    /// protocol error is entitled to drop the server.
    public var call: (_ arguments: [String: Any]) throws -> String
}
```

Error handling splits on whether the *call* was well-formed:

| input | reply |
|---|---|
| unparseable JSON | `-32700 Parse error`, `id: null` |
| no `method`, or `jsonrpc != "2.0"` | `-32600 Invalid Request` |
| unknown method | `-32601 Method not found` |
| `tools/call` naming a tool that does not exist | `-32602 Invalid params` — there is no tool, so there is no tool result |
| a known tool that throws | `result` with `isError: true` and the message as text |
| any notification (no `id`) | nothing at all, even on failure |

The last row is the framing bug most hand-written servers ship, and it has a test.

`initialize` returns `protocolVersion`, `capabilities: {"tools": {}}`, `serverInfo`, and `instructions`. The instructions string is the one place a one-time framing is cheap, and it is where silence gets explained:

> FlowTrace reports what this machine already wrote down: git state, coding-agent transcripts, listening ports. It is read-only and local. A short answer such as "Nothing waiting" is the normal and correct result, not a failure — do not retry it.

### 2. `AgentDigest` (new, `Sources/FlowTraceCore/MCP/AgentDigest.swift`)

The single place any fact becomes text bound for a model. Redaction, path abbreviation and the token budget all live here, for the reason `docs/superpowers/specs/2026-09-03-redact-at-the-choke-point-design.md` gives: sprinkling redaction across consumers is how the current gaps happened.

```swift
public enum AgentDigest {
    public static func brief(_ brief: ResumeBrief?, repositoryPath: String, budget: Int = 400) -> String
    public static func unfinished(_ result: ScanResult, limit: Int, budget: Int = 600) -> String
    public static func running(_ projects: [LiveProject], budget: Int = 300) -> String

    /// Every string that enters a digest goes through here. Redacts, then drops
    /// the string entirely when nothing but markers is left — the same rule and
    /// the same order as `BriefBuilder.promptArc` (`BriefBuilder.swift:134-138`),
    /// so an agent sees exactly what the brief would have shown it.
    static func safe(_ text: String?) -> String?

    /// `/Users/you/code/acme` → `~/code/acme`, via `String.abbreviatingHome`.
    static func place(_ path: String) -> String

    /// Whole lines that fit the budget, then one honest line about the rest.
    /// Never truncates an entry: half a repository name is worse than a count.
    static func fit(_ entries: [[String]], budget: Int, elided: (Int) -> String) -> String
}
```

`fit` estimates with `count / 4`, the same proxy as `ResumeBrief.estimatedTokens` (`ResumeBrief.swift:148`), so the three budgets are comparable with the number the brief has always reported. It is a character proxy and under-counts dense text; the real figure is measured by hand in the manual steps, not asserted here.

Output is prose, not JSON. `ResumeBrief` says why (`ResumeBrief.swift:5-8`): "Deliberately prose, not a table: this is injected into a model's context as the opening of a session, and prose is what a model resumes from. The human rendering is the same text — if it doesn't read well to you, it won't work as a prompt either." A JSON object of the same facts costs more tokens and reads worse. `brief` therefore emits `ResumeBrief.render()` verbatim; the other two get renderers in Core because `Scan.printBrief` and `Now.run` build coloured terminal layouts inside the CLI target and are not reusable. No `structuredContent`, one `{"type": "text"}` block per call.

### 3. The three tools

Names are prefixed because not every client namespaces them (Claude Code exposes these as `mcp__flowtrace__*`; others do not). Descriptions are written to be read by a model deciding whether to call, and are kept short because they are resident in every turn — see §6.

**`flowtrace_brief`** — `BriefBuilder.build(repositoryPath:config:cache:)`, the same call `flowtrace brief` makes.

> Where this repository was left: branch, uncommitted and unpushed work, and the last few things the user asked a coding agent here. Use when resuming work, or when the user refers to earlier work you have no record of.

```json
{"type": "object",
 "properties": {"repository_path": {"type": "string",
   "description": "Absolute path inside the repository. Defaults to this server's working directory, which was fixed when the client launched it — pass the path explicitly if the user has moved."}},
 "additionalProperties": false}
```

The default deserves the warning in its own description. A stdio server's working directory is set by the client at spawn and never changes, even if the user moves around inside the session.

**`flowtrace_unfinished`** — `AbandonedWorkDetector.scan(config:)` with `maxProposals: limit`, ordered by the existing score.

> Repositories across this machine with work started and not finished — uncommitted files, unpushed commits, and what the user was asking an agent to do there. Use when the user asks what they have left hanging, or before suggesting new work.

```json
{"type": "object",
 "properties": {"limit": {"type": "integer", "minimum": 1, "maximum": 10, "default": 5,
   "description": "How many repositories to report, highest-scoring first."}},
 "additionalProperties": false}
```

Default 5, not `Scan.limit`'s 25. `cold_days` is deliberately not exposed: it earns nothing a model would use well and costs schema tokens in every turn.

**`flowtrace_running`** — `LiveStateReader().read()` then `LiveState.projects(notes:)` with `Store.allProjectNotes()`.

> Coding agents and local servers running on this machine right now, grouped by project, with the ports servers are holding. Use before starting a dev server or a long-running process, and when the user asks what is still running.

```json
{"type": "object", "properties": {}, "additionalProperties": false}
```

No inputs at all. Emission rule: **every** project holding a listening port, plus up to five more agent-only projects, in `projects()`' existing liveness-then-recency order (`LiveProject.swift:92-97`). A held port changes what the agent does next, so it is never the thing elided. `LiveProject.note` rides along where the user has written one — which is how project notes reach an agent without a tool of their own.

### 4. Consent, and exactly what is refused

**No new read is introduced by this spec.** The tools read the union of what `flowtrace brief`, `flowtrace scan` and `flowtrace now` already read: four read-only git commands, `~/.claude/projects/**.jsonl` and Codex rollouts, `pgrep` plus one batched `lsof`, and three tables (`projectNote`, `ignoredPath`, `scanCache`).

**Browser tabs are refused outright.** `LiveStateReader.readBrowsers()` is never called. It costs roughly half a second across three browsers, and per `docs/superpowers/specs/2026-09-03-nothing-is-read-before-you-say-so-design.md` §5 there is no non-prompting permission check today — so it would raise "FlowTrace wants to control Safari" from a process the user cannot see, spawned by their agent, where dismissing is a permanent deny. That is the worst place on the machine to ask for a permission. It also keeps `Redaction.redactURL` — which does not exist yet (spec C §3) — off the export path entirely, along with the real URL in the author's database carrying `token=` and `X-Amz-Signature=`.

**Also refused:** file contents (`changedFiles` contribute last path components only, via `ResumeBrief.notableFiles`); transcript bodies (at most the last three *user* prompts, condensed to 120 characters, never assistant text or tool output); absolute paths (`AgentDigest.place`); `LiveAgent.sessionId` and any transcript path, on spec B's reasoning that a session id lets the caller go and read the transcript itself; and every write.

**The consent state is unreachable from this process, and the spec does not pretend otherwise.** `ConsentSettings` is declared in `Sources/FlowTraceApp/AppModel.swift:45` and persisted to `UserDefaults` under `"flowtrace.consent"` (`:52`) — the app's defaults domain, which a CLI binary does not share. So:

- `flowtrace mcp --sources <all|claude|codex|none>` (default `all`), written into the client's config by the installer from what the user chose there. It selects which adapters are constructed, and `none` means `brief` and `unfinished` fall back to git state alone.
- The consent record therefore lives in plain text in a file the user owns and can read — `~/.claude.json`, `~/.codex/config.toml`, `~/.cursor/mcp.json` — which is *more* auditable than a `UserDefaults` key, not less.
- Spec B's justification for its `.all` default is "running `flowtrace now` *is* the consent". **That argument does not transfer.** A human typed the CLI command; an agent calls a tool on its own schedule, possibly with the user reading nothing. Which is why the flag exists rather than a bare default, and why the installer must disclose before it writes (§9).
- When spec B lands, `ConsentSettings` should move into Core and persist in the SQLite file both binaries already share — WAL, `busyMode = .timeout(5)` (`Database.swift:29-32`) — and `flowtrace mcp` must then intersect the flag with the stored consent and take the narrower. That move belongs to B, not here.

### 5. Redaction — and why `flowtrace_unfinished` cannot ship naively

Two of the three sources are already clean. `BriefBuilder.promptArc` redacts and drops keys-only prompts (`BriefBuilder.swift:134-138`). `LiveStateReader.readAgents` does the same for `lastPrompt` (`LiveStateReader.swift:73-74`).

The third is not. `AbandonedWorkDetector.evaluate` copies prompts into `evidence.lastPrompt` (`:245`), `promptArc` (`:249-253`), `suggestedIntent` (`:261`) and `suggestedNextStep` (`:262`) with `AgentSession.condense` and **no `Redaction` call anywhere**. Spec C names this as gap 2, unfixed, and reports the measurement: 188 `scanCache` rows on the author's real database, **two payloads containing `sk-` keys, zero containing `[api key removed]`**. A naive wrapper around `ScanResult` would put live API keys into a request body bound for a model provider.

So: `AgentDigest.safe` is the only way a string becomes digest text, and it is not optional per tool. It applies to `unfinished` even after spec C lands, because the boundary is where "off this machine" actually happens.

Two limits, stated rather than glossed:

- **This is best-effort, not a guarantee.** Spec C lists patterns `Redaction` does not match today: `sk_live_`/`sk_test_`/`rk_live_`, `github_pat_`, `glpat-`, `xapp-`, `ya29.`, `hf_`, `npm_`, `SG.`, and private-key *bodies* (only the header line matches). A key in one of those shapes will reach an agent's context. Spec C is the fix and is a genuine prerequisite for calling this surface safe.
- `Redaction.isOnlyRedactions` hard-codes its marker list (`Redaction.swift:79-80`) instead of deriving it from `patterns.map(\.name)`, so any pattern added later is silently missed by the drop rule. Cosmetic rather than dangerous — the marker survives as text, the credential does not.

MCP uses `StoreSessionCache` the way `Scan` does, because it is the difference between 0.5 s and several seconds on `unfinished`. That does not worsen spec C's storage gap — `flowtrace scan` already writes those rows — but it does not improve it either, and the honest reading is that this spec should not be called done while `scanCache` holds unredacted payloads.

### 6. Token budget

Two costs, and the one usually forgotten is the larger.

**Resident.** Three names, three descriptions and three schemas sit in the model's context on *every turn of every session*, whether or not a tool is called. Estimated 220–280 tokens; measured for real in the manual steps. This is the whole argument for three tools rather than six, and for cutting `cold_days`.

**Per call.** `brief` 400, matching `ResumeBrief.render()`'s existing cap ("every token spent here is one taken from the work itself", `ResumeBrief.swift:82-83`). `unfinished` 600. `running` 300. An agent that calls all three spends roughly 1,300 tokens plus the resident cost — a number worth being able to say out loud when someone asks what this costs.

`AgentDigest.fit` accumulates whole entries until the next one would exceed the budget, then appends one line: `"3 more repositories not shown."` Entries are already score-sorted for `unfinished` and liveness-sorted for `running`, so the prefix that fits is the right prefix.

### 7. Silence

`BriefBuilder` returns nil when there is nothing worth saying, and that rule is load-bearing: "a hook that produces noise gets uninstalled" (`BriefConfig` doc comment). A tool cannot return nothing, so the rule has to be translated rather than copied — and the asymmetry is the point. **The hook is pushed, so silence means spend nothing. A tool call is pulled: the tokens are already spent and a question has been asked.** The cheapest correct answer is therefore one terminal sentence — never an error, which makes a model retry or apologise, and never an empty result, which makes it guess.

| condition | reply, exactly |
|---|---|
| `BriefBuilder.build` returns nil, path is a repository | `Nothing to resume here — this repository was touched recently, or has nothing outstanding.` |
| `GitProbe().probe(path)` returns nil | `~/x is not inside a git repository.` |
| `ScanResult.proposals` empty | `Nothing waiting. Everything you started is committed or pushed.` |
| no agents and no servers | `No agents and no servers running.` |

The third is `Scan.swift:67` verbatim, because the CLI and the tool answering the same question differently would be a bug in one of them. The repository check is one extra `GitProbe` call on the failure path only, and it is worth it: `build` returns nil for both cases and a model told "nothing to resume" when it actually passed a bad path will happily continue on a wrong premise.

`isError: true` is reserved for a call that is genuinely broken — a non-string `repository_path`, an unreadable path — and never for an empty answer.

### 8. The CLI (`Sources/flowtrace/MCP.swift`)

```swift
struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Answer an agent's questions over MCP, on stdin and stdout."
    )

    @Option(name: .long, help: "Which agent transcripts may be read: all, claude, codex, none.")
    var sources: String = "all"

    func run() throws
}
```

Added to `FlowTraceCLI.configuration.subcommands`. The loop is `while let line = readLine(strippingNewline: true)`, blocking on the main thread, which is exactly right for a stdio server; EOF means the client has gone, so exit 0.

**Stdout is the transport, so nothing else may touch it.** Three things make that hold, and all three are already true: `Diagnostics.log` writes to a file rather than the console (`Diagnostics.swift:7-8`); `Shell.run` gives every subprocess its own `Pipe` for stdout and stderr and `FileHandle.nullDevice` for stdin (`Shell.swift:35-38`), so `git`, `pgrep` and `lsof` cannot leak into the stream; and `Term` — whose `useColor` checks `isatty` — lives in the CLI target and is not referenced by `AgentDigest`. `MCP.run()` must not use `Term` or `print` for anything but protocol lines; diagnostics go to `Diagnostics.log` or `FileHandle.standardError`, the way `Scan.run` already writes "Scanning…" to stderr. `SIGPIPE` is ignored and a failed write exits.

The store is opened with `try?`, following `Brief.swift:43-46`, so a machine that has never opened the app still gets working tools.

**MCP briefs are not written to `briefLog`.**
 `Store.recordBriefShown` feeds the seven-day experiment behind `flowtrace verdict`, whose kill criterion — "fewer than 4 wins in 7 days" — was defined for the hook. Mixing agent-pulled briefs into that denominator would invalidate the experiment mid-flight. `BriefLogEntry` has no `source` column; adding one is the small piece of work that would let MCP be measured the same way, and it is out of scope here.

### 9. Discovery and install (`Scripts/install-mcp.sh`)

`Scripts/install-hook.sh` is the precedent, and it is a good one: it backs the file up before touching it ("a file the user's whole CLI reads"), merges rather than clobbers, drops any previous FlowTrace entry so re-running updates instead of duplicating, and refuses politely when it cannot find the binary. The new script keeps all four properties and adds one, because this one is a disclosure and the hook was not.

**It asks before it writes.** The script prints what becomes readable — git state, Claude Code and Codex transcripts, listening ports, project notes; and what does not — browser tabs, file contents, anything written anywhere — then reads a choice of `all` / `claude` / `codex` / `none`, and puts that choice in the config as `--sources <choice>`. Declining writes nothing. This is the consent event for MCP (§4), so it cannot be a `-y` flag.

Where it writes, per client:

- **Claude Code.** Shell out to `claude mcp add flowtrace -- <binary> mcp --sources <choice>` when `claude` is on `PATH`, and only fall back to printing the JSON block otherwise. MCP servers do not live in `~/.claude/settings.json` alongside the hook — user-scope servers live in `~/.claude.json` and project-scope ones in `.mcp.json` — and hand-editing a file whose schema we do not own is the risk `install-hook.sh` mitigates with a backup. Better to let the tool that owns the file do it.
- **Codex.** A `[mcp_servers.flowtrace]` table in `~/.codex/config.toml`. TOML, and the project has no TOML parser and should not acquire one for this, so the script **prints the block and does not edit the file.** Printing is the honest default for any config we cannot merge safely.
- **Cursor.** `~/.cursor/mcp.json` — same shape as Claude Code's JSON, mergeable with the same `python3` heredoc `install-hook.sh` already uses, with the same backup.

`Scripts/uninstall-mcp.sh` mirrors it: `claude mcp remove flowtrace`, and remove the FlowTrace entry from any JSON file it edited.

The README's "Using it" section gains one line next to the hook, saying what the hook cannot: the hook speaks once at the start of a session; the MCP server answers when asked. Both are worth having, and the hook remains the one to install first because it needs nothing from the model.

## Out of scope

- **Any write tool** — a `note` tool, a "record what we just decided" tool, or writing a `ThreadProposal`. This is a position, not an omission, and it is the one I hold most firmly. `ActivityEvent` has no provenance column, so the first agent-written note makes "notes written: 4" permanently uncountable and the serif-italic claim on `ActivityEvent.note:48-49` ("your own words … precisely because it is yours and not the system's") retroactively false. Spec A's `CaptureTargeting.mayOverwrite(existing:shown:)` already answers the mechanics: an agent's words are by construction words the user never saw, so `shown == nil` and overwriting is refused. And the habit doc's prescription is "confirm, don't author" — an agent authoring at scale is the exact inversion. A future write tool needs, in order: a provenance column rendered differently from the user's own words; a review queue rather than the timeline (`Store.pendingProposals`/`accept`/`dismiss`, `Store+Proposals.swift:79-176`, is already the right shape and already means "machine found this, human confirms"); and `mayOverwrite` intact.
- **A "why did I open this URL" tool.** `Store.noteForTab(url:)` is a good answer to a real question, and the corpus is 4 notes. A tool that almost always returns nothing gets ignored while still costing schema tokens in every turn. It becomes worth building when the notes corpus exists — and it needs `Redaction.redactURL` first.
- `flowtrace resume`, `list`, `attach` and `verdict` as tools. Thread-shaped, and threads need the app.
- MCP resources, prompts, sampling, roots, and any HTTP or SSE transport.
- Moving `ConsentSettings` into Core (spec B) and the `scanCache` redaction (spec C). Both are named prerequisites, neither is done here.
- A `source` column on `briefLog`.
- Retiring the `SessionStart` hook. It stays, and stays the default: it needs no cooperation from the model, and it works in a session where the model never calls a tool. The two overlap only on `brief`, and that is acceptable — one is push, the other pull.

## Decisions to confirm at review

1. **The protocol revision string.** I believe the current revision is `2025-06-18` and that stdio framing is newline-delimited JSON with no embedded newlines, but I cannot verify that against the specification from here, and revisions move. Confirm before implementing; and prefer echoing a client's requested `protocolVersion` when it is one we support over hard-coding a single string.
2. **Hand-rolled framing versus the official Swift SDK.** I recommend hand-rolled, and item 1 is evidence against my own recommendation: an SDK tracks the thing I am uncertain about. The counterweight is a third dependency in a project whose two-dependency claim is part of its pitch.
3. **Whether `flowtrace_unfinished` ships before spec C.** I argue the boundary redaction in `AgentDigest.safe` makes it safe enough. Spec C's own conclusion is that a second choke point is the wrong architecture. If the reviewer wants one choke point, this tool waits for C and the other two ship without it.
4. **Three tools or two.** I am least confident about `flowtrace_running`. It is the one with no claim to being "memory", and an agent with shell access could get the ports itself from `lsof`. It stays in because the project grouping — "this port belongs to the repo you are in" — is the part `lsof` cannot do, and because it is the only tool whose answer changes an agent's next action.
5. **Not logging MCP briefs to `briefLog`.** Protects the experiment; means this surface is unmeasured until a `source` column exists.
6. **Tool naming.** `flowtrace_*` prefixed, given that Claude Code namespaces them anyway and other clients do not. The prefix costs a few resident tokens per tool.

## Testing

`Sources/FlowTraceTests/MCPTests.swift`, `runMCPTests()` added to the flat list in `main.swift`. Everything below runs against `MCPServer.respond(to:)` and `AgentDigest`, with no process and no stdio — the `ServerTests` pattern. Core readers are all already injectable (`BriefBuilder(git:claude:codex:)`, `AbandonedWorkDetector(adapters:)`, `LiveStateReader(git:claudeRoot:)`), so tests point at `Fixtures/` and never read the real `~/.claude`.

Framing and dispatch:
- `initialize` returns a `protocolVersion`, `capabilities.tools`, `serverInfo.name`, and non-empty `instructions`.
- `notifications/initialized` returns nil — no reply line at all. Same for a notification naming an unknown method, and for one that would have thrown.
- `tools/list` returns exactly three tools; each `inputSchema` is a JSON object with `"type": "object"` and `additionalProperties: false`.
- `tools/call` on each tool returns one `content` block of `"type": "text"`.
- Unknown tool name → `-32602`. Malformed JSON → `-32700` with `id: null`. Missing `method` → `-32600`. Unknown method → `-32601`.
- A request whose `id` is a string, a number, and `null` each echo back in the same JSON type.
- Two requests read as two lines are answered in order, and no reply line contains a literal newline — with a fixture prompt that itself contains one, since that is the case that would break the transport.

Redaction, the tests that matter most:
- A fixture session whose prompt carries `sk-` plus an `AKIA` key plus a JWT: none of the raw values appear in any of the three digests, and `[api key removed]` does.
- A prompt that is *only* a pasted key is dropped entirely, not rendered as `[api key removed]` — matching `BriefBuilder.swift:136-138`.
- No digest contains `FileManager.default.homeDirectoryForCurrentUser.path`; a repository under home renders with a leading `~`.
- No digest contains a `.jsonl` path or a session id.

Budget and silence:
- Thirty synthetic `ThreadProposal`s: the digest estimates at or under 600, ends with the elision line, and contains no partial entry (every emitted repository name matches a proposal exactly).
- `limit: 1` yields one entry; `limit: 11` is rejected by schema validation, and by the handler independently, since a client may not validate.
- Each of the four silence strings, byte-for-byte, from the condition that produces it.
- A brief at the 400 budget is not truncated mid-word.

Not testable here, and honestly so: whether a model chooses to call these tools at the right moment; whether the descriptions cause misuse — calling `unfinished` every turn is 0.5 s and 600 tokens each time; whether the schemas survive three clients' varying strictness; stdout purity under a real client; and the config-file merges of §9's installer.

## Manual verification

With `swift build` and a `flowtrace` on `PATH`:

1. **Stdout purity.** `printf '%s\n' '<initialize>' '<tools/list>' '<tools/call brief>' | flowtrace mcp | while read -r l; do echo "$l" | jq -e . >/dev/null || echo "NOT JSON: $l"; done` — in a repository with uncommitted work, and in one that is clean, and in a directory that is not a repository at all. Nothing but JSON-RPC lines, three lines out for three requests, exit 0 on EOF.
2. **Register it in Claude Code** — `claude mcp add flowtrace -- /usr/local/bin/flowtrace mcp --sources all` — then in a real session confirm the tools appear, and read `/context` before calling anything to get the **resident** schema cost. Write the number into this spec if it exceeds 280 tokens; that would be a reason to cut a tool, not a reason to accept it.
3. Ask "what was I working on here?" in a repository stopped several days ago. The brief arrives, matches `flowtrace brief` word for word, and the model uses it rather than restating it.
4. Ask "anything unfinished elsewhere?" on the author's real machine — the one with 23 repositories and three genuinely abandoned pieces. Five entries, highest-scoring first, an elision line, and every path abbreviated to `~`.
5. **The leak test, on real data.** Before anything else: `grep -l 'sk-' <known transcript>` to confirm a live key is present, then call `flowtrace_unfinished` with that repository in range and grep the raw response for the key's first eight characters. It must not be there. This is the step that decides whether this ships.
6. Start a dev server on 3000, then ask an agent in the same repository to start one. `flowtrace_running` names the port and the project, and the agent picks another port or says so.
7. Silence: in a repository committed and pushed ten minutes ago, all three tools return their one-sentence answers, the model does not retry, and it does not apologise.
8. **Codex and Cursor**, from the config blocks the installer prints. Confirm the server starts, the tools list, and one call succeeds in each — and that a client which does not namespace tool names still shows three distinct ones.
9. `--sources none` in a repository with transcripts: the brief still reports git state, and `debug.log` shows no transcript read.
10. Kill the client mid-call. The server exits rather than lingering; `pgrep -f 'flowtrace mcp'` is empty.
