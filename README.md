# FlowTrace

**You start things and don't finish them. FlowTrace finds those things.**

A macOS menubar app that reads your coding-agent transcripts and git state —
locally, read-only — and works out which pieces of work were started and never
finished. Then it links them to the tabs, repositories and notes that belong
with them, so you can pick one back up without reconstructing it from memory.

```
Read 118 agent sessions across 16 repositories in 3.5s.

9 pieces of unfinished work:

  Redo previous changes · cc
  cc · scn-4    12 uncommitted files  ·  last commit 29d ago  ·  2 Claude Code sessions
  last asked: push to gh
  ~/armor/videos/cc

  Replace ChatGPT key with Gemini API key · cap
  cap · main    3 uncommitted files  ·  last commit 23d ago  ·  2 Claude Code + Codex sessions
  last asked: what env should i share w vercel fr deployment
  ~/projects/nl/cap
```

That output took no configuration and no typing. It's the first thing FlowTrace
shows you.

## Why this exists

The problem isn't too many tabs. It's that the **intention** behind them is
gone. At the moment you open a tab or start an agent session you know exactly
why. Three days later you have fourteen tabs, six repositories with uncommitted
changes, and no idea which belong together.

Most tools in this space ask you to organise your work first. That's the part
nobody does. FlowTrace inverts it: **it proposes, you confirm.** The dashboard
is already full the first time you open it.

## What it does

- **Finds abandoned work.** Cross-references Claude Code and Codex CLI
  transcripts against git state to find repositories that are dirty, unpushed,
  and cold — and tells you the last thing you asked an agent to do there.
- **Work Threads.** The primary object is an intention, not a tab: title, why
  you're doing it, what's next, what's blocking it. Tabs, repositories and agent
  sessions hang off a thread.
- **Explicit capture.** Grab the front browser window's tabs with a reason
  attached. Attach a repository from the app, or `flowtrace attach` from the
  terminal.
- **Resume.** One screen answering: what was I doing, what changed since, what
  comes next.
- **Search.** Full-text across titles, intents, next steps, blockers, notes,
  page titles, URLs, repository names and agent names.

## Privacy

FlowTrace is local software. It has no server to talk to.

- **FlowTrace never sends anything anywhere.** There is no HTTP client in the
  codebase — no telemetry, no crash reporting, no model API. It does *listen* on
  `127.0.0.1` when you switch the browser-extension endpoint on, so that the
  extension and CLI can hand it captures; that socket is bound to loopback, is off
  by default, and every route but `/health` requires a bearer token.
- **No account, no sync, no telemetry.**
- **Nothing is scanned until you say so.** First run lists the exact directories
  it wants to read and reads nothing until you tick them.
- **Read-only.** FlowTrace runs `git rev-parse`, `git status`, `git log` and
  `git rev-list`. It never checks out, stashes, commits or fetches.
- **Transcripts:** working directory, branch, timestamps, the session's own
  title, and the prompts *you* typed. Assistant replies, file contents and tool
  output are skipped.
- **Browser tabs:** page title and URL only. Never page contents, cookies, form
  values or credentials — and no browser is launched just to be read.
- Everything lives in one SQLite file at
  `~/Library/Application Support/FlowTrace/flowtrace.sqlite`. Settings has
  Reveal in Finder, Export to JSON/Markdown, and Delete all.

## Install

Requires macOS 14+ and the Xcode **Command Line Tools** — not Xcode.

```bash
git clone https://github.com/YOURNAME/flowtrace
cd flowtrace
./Scripts/bundle.sh release
cp -R dist/FlowTrace.app /Applications/
cp dist/flowtrace /usr/local/bin/          # optional CLI
```

Builds are ad-hoc signed, so macOS will quarantine the app on a machine that
didn't build it:

```bash
xattr -dr com.apple.quarantine /Applications/FlowTrace.app
```

To produce a distributable build, set `FLOWTRACE_SIGN_IDENTITY` to a Developer
ID before running `bundle.sh`.

## The brief

The thing FlowTrace is actually for. Run it in any repository:

```bash
flowtrace brief
```

```
You worked on refund 10 days ago, on branch main.
That session was about: Run project on localhost.
You left 15 uncommitted files (IntentTrace.jsx, intent.js, app.js), and 8 commits
not yet pushed.
Your last commit was "Expand support-mcp to 20 tools and stage policy ownership".

The last things you asked an agent in this repository:
  · If I have multiple agents, how would that work?
  · run this project on localhost
```

Better still, have it appear on its own. `./Scripts/install-hook.sh` adds a
`SessionStart` hook so the brief is handed to Claude Code whenever you start it in
a repository you left something in — no shortcut to remember, no app to open.
`./Scripts/uninstall-hook.sh` removes it.

It stays quiet unless it has something to say: nothing if you were here in the
last two hours, nothing if the tree is clean, nothing for scratch worktrees, and
nothing for work old enough that it is over rather than paused. Credential-shaped
strings are stripped from prompts before they reach the brief — it is going into
an agent's context, so a leaked key would travel further than one sitting in a
local file.

Runs in about 80ms, because a repository's transcripts are found by directory name
rather than by reading every transcript on the machine.

## CLI

```bash
flowtrace brief                 # where you left this repository
flowtrace verdict win|loss      # did the brief beat what you'd have typed?
flowtrace verdict --report      # the tally
flowtrace scan                  # find unfinished work
flowtrace scan --cold-days 14   # only things untouched for two weeks
flowtrace scan --json           # machine-readable
flowtrace list                  # your threads
flowtrace attach --thread oauth --note "why this matters"
flowtrace resume oauth          # everything you need to pick it back up
flowtrace serve                 # capture endpoint without the app
flowtrace seed                  # realistic sample data (scratch db by default)
```

`⌥Space` opens capture from anywhere, without needing Accessibility permission.

The CLI writes directly to the same database, so it works whether or not the app
is running.

## Browser extension (optional)

AppleScript capture covers the common case with nothing to install. The
extension adds what AppleScript can't do: capture a tab *with its reason* at the
moment you open it, and a toolbar badge showing that the current tab is already
filed under a thread.

1. FlowTrace → Settings → Browser extension → switch the endpoint on, copy the token.
2. `chrome://extensions` → Developer mode → Load unpacked → select `Extension/`.
3. Extension options → paste the port and token → Save and test.

The endpoint binds to `127.0.0.1` only and every request needs the bearer token.

## Architecture

```
Sources/
  FlowTraceCore/     no UI — models, SQLite store, FTS5 search, git probe,
                     agent adapters, detector, AppleScript reader, local server
  FlowTraceApp/      SwiftUI — MenuBarExtra + NavigationSplitView
  flowtrace/         CLI
  FlowTraceTests/    the suite
Extension/           MV3 extension
```

`FlowTraceApp` holds no business logic. Detection, parsing, git and storage live
in `FlowTraceCore`, which is why the CLI and the app behave identically and why
the logic is testable headlessly.

Adding an agent means implementing `AgentAdapter` — `discoverSessions()`
returning `[AgentSession]`. Nothing else changes. Cursor, OpenCode and Gemini CLI
deliberately have no adapter: their local stores are thin or opaque, and a
fragile parser that silently returns wrong data is worse than honest manual
capture.

## Tests

```bash
swift run flowtrace-tests
```

The suite is an executable rather than an XCTest target, because XCTest ships
with Xcode and this project targets the Command Line Tools. It runs against
committed fixtures and temporary git repositories — never against your real
`~/.claude` or `~/.codex`.

## Status

Early. Built for one person's daily use first. Detection covers Claude Code and
Codex CLI; everything else is manual capture behind a stable adapter interface.

MIT.
