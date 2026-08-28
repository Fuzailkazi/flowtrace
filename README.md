# FlowTrace

**You have eleven coding agents running. Seven have been idle for four days. Can you say what any of them were doing?**

FlowTrace is a macOS app that shows you what is actually happening on your
machine — which agents are running and where each one stopped, which servers are
still holding ports, what you had open — and lets you attach *why* to any of it,
in one keystroke, without leaving what you're doing.

It reads only what your machine already wrote down. No screen recording, no OCR,
no keystroke logging, and nothing ever leaves the device.

```
15 places · 7 left running and forgotten

●  gtm                                                     just now
   waht kind of content should i post from my account i.e fuzailkazi_ on x

●  aum                                                      29m ago
   add more animation make this site a genz website it looks liek a 90s webstie

○  tulu                                                4d ago · idle
   give me a good detail so that i knwo what i have to say on the loom video
   listening  :3000
   ● what are you building here?
```

That is real output from a real machine, and the `tulu` line is the point: an
agent abandoned four days ago **and** a dev server still holding port 3000. Two
facts that mean little apart and a lot together.

## Three surfaces

**Now** — what's happening this second. Running agents, what you last asked each
one, how long since anything moved, and every local server with the project it
was started from. Grouped by place, because work happens in places: an agent in
`tulu` and a server started in `tulu/frontend` are one thing, not two.

**Why** — intent, captured where you are. Press the shortcut anywhere and a small
panel appears over what you're doing, already knowing where you are and what led
there. Type a sentence, press return, and it lands on the timeline. **The note
outlives the thing** — close the tab, quit the agent, reboot; next week you can
still find out why you opened it.

**Then** — what you're building in each place. Written once against the
repository rather than a session or a process, so it survives everything that
ends.

## What it reads, and what it refuses to

FlowTrace only ever reads things that already exist on disk:

| It reads | It does not |
|---|---|
| Which app is frontmost (no permission needed) | Record your screen |
| The focused window's title (Accessibility) | OCR anything |
| The active browser tab's title and URL (Automation) | Log keystrokes |
| Coding-agent transcripts your agents wrote themselves | Attach to or inject into any process |
| Git state via four read-only commands | Write to any repository |
| Which processes are listening on which ports | Send anything anywhere |

**No network requests.** There is no HTTP client in the codebase — no telemetry,
no crash reporting, no model API. It *listens* on `127.0.0.1` when you switch the
browser-extension endpoint on, so the extension and CLI can hand it captures;
that socket is loopback-bound, off by default, and token-gated on every route but
`/health`.

**Nothing is recorded until you switch it on**, nothing while the screen is
locked or you've stepped away, and FlowTrace never records itself. Everything
lives in one SQLite file you can open yourself:

```
~/Library/Application Support/FlowTrace/flowtrace.sqlite
```

Settings → **What FlowTrace knows** lists exactly what is held — notes you wrote,
records made automatically, pages seen, agent sessions, project notes — and how
large the file is. You can erase only what was recorded automatically and keep
everything you wrote, forget a single day, forget one entry, or delete
everything. The file's path is shown with a Reveal button, because deleting it
yourself should always be an option.

**Credentials are stripped before they are stored.** Prompts are the one free-text
input, and free text contains whatever you pasted — a scan of `~/.claude/projects`
on the machine this was built on found five live API keys sitting in prompts. Keys,
tokens, JWTs and database URLs with passwords are redacted at the point text
leaves the transcript, leaving the sentence around them readable.

## Install

Requires macOS 14+ and the Xcode **Command Line Tools** — not Xcode.

```bash
git clone https://github.com/Fuzailkazi/flowtrace
cd flowtrace
./Scripts/bundle.sh release
cp -R dist/FlowTrace.app /Applications/
cp dist/flowtrace /usr/local/bin/          # optional CLI
```

Builds are ad-hoc signed, so macOS quarantines the app on a machine that didn't
build it:

```bash
xattr -dr com.apple.quarantine /Applications/FlowTrace.app
```

Set `FLOWTRACE_SIGN_IDENTITY` to a Developer ID before running `bundle.sh` to
produce a distributable build.

## Using it

**The app** opens on *Now*. The `Now / Today` switch moves between live state and
the day you can read.

**The shortcut** is `⌥Space` by default, and configurable in Settings — click the
field and press whatever you want. It can also be a bare modifier tap (left ⌥ on
its own), which needs Accessibility and can misfire; double-tap is steadier. If
another app already owns your combination, Settings says so instead of leaving a
dead key.

**The CLI** works whether or not the app is running:

```bash
flowtrace now         # what's running, grouped by place
flowtrace brief       # where you left this repository, ready to hand to an agent
flowtrace scan        # repositories with unfinished work in them
flowtrace resume <x>  # everything you need to pick a thread back up
flowtrace attach      # attach this repository to a thread
flowtrace serve       # the capture endpoint, without the app
```

`./Scripts/install-hook.sh` registers a `SessionStart` hook so `flowtrace brief`
is handed to Claude Code whenever you start it in a repository you left something
in. It stays silent unless it has something to say — nothing if you were here in
the last two hours, nothing for a clean tree, nothing for scratch worktrees.

## How some of it works

A few things were harder than they look, and the notes are in the code:

**Spans, not points.** Forty alt-tabs must become one timeline entry, not forty.
Staying put extends a span; nipping to Slack and back within five minutes resumes
the old one rather than splitting your morning into three lines.

**`lsof` lies about failure.** It exits non-zero whenever any one of its
selections matches nothing — so `-c claude -c codex` with no Codex running
reports failure on a perfectly good read. It also only saw four of seventeen
running agents, because it cannot inspect every process. Discovery uses `pgrep`;
one batched `lsof -p` resolves the directories.

**Transcript tails.** Reading each agent transcript end-to-end cost two seconds
across eleven agents. Only the tail is read, widening from 512KB to 4MB when a
long agent turn has pushed the last human prompt out of reach. 2.0s → 0.6s.

**`isMeta`.** Claude Code writes injected skill bodies and slash-command
expansions as user turns. They are indistinguishable from you until you check
that flag — before FlowTrace honoured it, proposals came out titled *"Base
directory for this skill: …"*.

**`/var` is not `/private/var`.** Foundation's `resolvingSymlinksInPath()`
deliberately leaves that pair alone; `git rev-parse` resolves it. Two spellings of
one directory compared as two different repositories until every path went
through `realpath`.

## Architecture

```
Sources/
  FlowTraceCore/     no UI — models, SQLite store, FTS5 search, git probe,
                     agent adapters, live process reader, activity recorder,
                     AppleScript tab reader, loopback server
  FlowTraceApp/      SwiftUI — Now, the day timeline, quick-capture panel
  flowtrace/         the CLI
  FlowTraceTests/    101 tests
Extension/           MV3 browser extension
```

Native Swift 6 and SwiftUI, built with Swift Package Manager and no Xcode.
Two dependencies: GRDB for SQLite and Swift Argument Parser for the CLI. Nothing
else — the loopback server is a plain BSD socket, which is what makes binding to
`INADDR_LOOPBACK` a guarantee rather than a setting.

`FlowTraceApp` holds no business logic, which is why the CLI and the app behave
identically and why the logic is testable headlessly.

Adding an agent means implementing one protocol method, `discoverSessions()`.
Cursor, OpenCode and Gemini CLI deliberately have no adapter: their local stores
are thin or opaque, and a parser that silently returns wrong data is worse than
honest manual capture.

## Tests

```bash
./Scripts/test.sh
```

The suite is an executable rather than an XCTest target, because XCTest ships
with Xcode and this project targets the Command Line Tools. It runs against
committed fixtures and temporary git repositories — never against your real
`~/.claude` or `~/.codex`.

## Status

Early, and honest about it.

**Working:** the Now view, the day timeline with inline annotation, ambient
capture of apps and windows and tabs, agent session import, project notes,
quick-capture panel, configurable shortcut, the CLI, the `SessionStart` hook,
search, export, delete.

**Not yet:** you can see seven forgotten agents but not stop them — seeing isn't
acting, and that's the next thing worth building. "What did I do last time" and
paused/resumed are unbuilt. Open apps and tabs appear in the timeline but not in
Now.

**Unverified:** light mode. Everything has been looked at in dark.

MIT.
