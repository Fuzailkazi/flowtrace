# Where FlowTrace is, and what happens next

One page, kept current. Written because there are now five design specs, two strategy notes and an audit in this repository, and it had become hard to see the shape of the thing.

Last updated: 2026-09-04.

---

## Three questions answered

### Do I need an API key from a model provider?

**No. Not from anyone, ever, for any part of this.**

FlowTrace has zero network clients and zero model calls — verifiable in one command:

```
grep -rE 'URLSession|NWConnection|import Network|anthropic|openai' Sources/
```

It returns nothing, and that is the product's single most defensible property.

The confusion is worth clearing up precisely, because it decides a lot. There are two ways a tool can be "agentic":

- **The tool calls a model.** Needs an API key, needs network, sends your data to a provider, costs money per use. FlowTrace does none of this and should not.
- **A model calls the tool.** The user's agent — Claude Code, Cursor, Codex — already has their own subscription. It asks FlowTrace a question; FlowTrace answers from local data. No key, no network, no cost, no account.

FlowTrace is the second kind, and already is today: `Scripts/install-hook.sh` installs a Claude Code `SessionStart` hook that injects `flowtrace brief` into a new session. That is an agent consuming FlowTrace. Nothing had to be paid for or signed up to.

### Do we need to build an MCP server?

**Not to make FlowTrace work. Yes, if we want it adopted without the app.**

MCP is a standard way for an agent to call local tools. Building one means your agent can ask FlowTrace things *mid-session* — "what was I doing in this repo?" — rather than only receiving a one-shot brief at startup.

It is the highest-leverage thing available for adoption, for one reason: **it delivers value with no habit required from you.** The note-writing loop asks you to remember to type something. An MCP tool asks nothing — your agent queries it and you simply find that it knows. Given that the writing habit has not formed even for the author (4 notes ever, against 1,181 ambient rows), that matters.

But nothing depends on it. It can be built or dropped without touching anything else.

### Will it be an obstacle when I give this to other people?

**Not for the app. A small, opt-in cost for the MCP part.**

| Path | What the user does | Friction |
|---|---|---|
| Just the app | Install, pick a shortcut, grant Accessibility | Normal Mac app onboarding |
| The CLI | `brew install flowtrace`, then `flowtrace scan` | One line, nothing to configure |
| The Claude Code hook | Run `Scripts/install-hook.sh` | One command; already exists and merges politely |
| The MCP server | Run `Scripts/install-mcp.sh`, answer one question | One command; discloses what becomes readable before writing anything |

The important part: **someone who installs the app never encounters MCP.** It is not mentioned, not required, not in the way. And the people who *would* use it already run agents and have installed MCP servers before — for them it is familiar, not novel.

The real onboarding obstacles are elsewhere, and they are already known: there is nothing to download (you must clone and build), and the app opens on a consent screen rather than on anything useful. Those are audit items 0.7 and 0.5, and they matter far more than MCP.

---

## Where things stand

### Done and on `main`

| | What |
|---|---|
| **Smart Capture** | The "why are you here?" box offers one suggestion — your project note, else your note on that page, else your last agent prompt. Tab or click to accept, never auto-filled. |
| **Sub-project A** | A capture lands where you pressed the key. Fixed three ways notes were silently lost or overwritten, including one where every capture after the first overwrote the same row. |
| **App icon** | Installed on Apple's grid with real transparency, `.icns` and extension icons generated. |
| **Verification tooling** | `Scripts/verify-capture.sh` — see what was actually written, rather than what the UI says. |
| **The audit** | Six dimensions, every finding adversarially verified, 65 survived, 7 launch blockers. `docs/superpowers/audits/`. |

175 tests passing.

### In flight

**A2 — a capture knows its place.** Tasks 1 and 2 committed; 3 and 4 building now. This is the fix for *"it just took it as Code, it didn't know it's the FlowTrace repository."* It reads VS Code's own record of the focused window, so the panel names the project.

### Specced, reviewed, not built

| | What | Why it matters |
|---|---|---|
| **A3** | The panel without the app | Fixes *"I always get the app up as well."* Makes FlowTrace menu-bar resident, shrinks the panel to a notepad, and settles the three-way shortcut contradiction. |
| **C** | Redact at the choke point | Three rows of your `scanCache` carry live API-key shapes right now. Blocks MCP, and blocks publishing `scan` output anywhere. |
| **MCP** | FlowTrace as agent memory | Three tools over stdio. No key, no port, no write access. |
| **B** | Nothing is read before you say so | Transcripts are read and browsers queried *during* the welcome screen, before consent. |

### Not designed on purpose

**D — first run**, and **E — the launch wrapper** (downloadable build, README truth pass). Both involve product and voice decisions better made together than guessed at.

---

## The order, and why

1. **A2** — finish it. It is nearly done and it is half of what you complained about.
2. **A3** — the panel without the app. The other half, and the one that is making you distrust your own tool.
3. **Accessibility** — a small change. 658 of 658 activity rows have no window title because the permission was never asked for properly. This is what makes the day readable rather than a wall of `Code`.
4. **C — redaction.** Promoted from "launch blocker" to "prerequisite", because MCP would be the first surface where a redaction failure leaves your machine, and because until it ships you cannot post `scan` output publicly.
5. **MCP** — the agentic layer.
6. **B — consent**, then **D** and **E** when you want to hand it to strangers.

Everything from 4 onward is for other people. Items 1–3 are for you.

---

## "Done for me" versus "done to give away"

You said you want to solve this for yourself first. That is the right call and it simplifies a lot — so here is what each actually requires.

**Done for you** is four things, and it is about a week:

1. The shortcut always works, and the panel appears **without the app**.
2. What you type always lands.
3. The day reads back in your own words, with project names.
4. Your agent knows what you were doing without you telling it.

That is items 1–3 plus MCP. Notably *not* on the list: sticky notes, tab management, orchestration, screen recording, more personas.

**Done to give away** adds: the privacy claims being true in code (B and C), a build people can download, and a first run that opens on something useful. Those exist because a stranger has no patience and no context — you have both.

---

## Decisions already taken

Recorded so they are not relitigated. Each has reasoning in the linked document.

| Decision | Why |
|---|---|
| **No LLM inside FlowTrace** | Would require sending transcripts to a provider or bundling a model. Also contradicts the app's own rule — `DeterministicSummarizer` states what is there and nothing more. |
| **Not an orchestrator** | Requires spawning, writing, injecting: the opposite of read-only. Competitors are funded and shipping, one of which is already in use in this repo's own worktree list. An orchestrator is the cockpit; this is the flight recorder, and the recorder works across all of them. |
| **Not a tab manager** | Trivial free alternatives already installed. The tab capability stays as a benefit to the same developer. |
| **The place goes in `metadata`, never `target`** | `describesSameActivity` compares `target`; a value the recorder cannot reproduce splits its span within 30 seconds. |
| **No MCP write tool** | `ActivityEvent` has no provenance column, so the first agent-written note makes the note count permanently uncountable and falsifies what the typography claims: a note is *your* words. |
| **MCP over stdio, not the existing HTTP server** | No port, no token in a config file, no requirement that the app be running. The privacy properties fall out of the process model. |
| **No screen recording, ever** | "Reads only what your machine already wrote down" is the whole position. Window titles, tab URLs and agent transcripts are enough to reconstruct a day. |
| **No AI attribution in commits** | Company GitHub account. Applies to commit messages and PR descriptions. |

## Decisions deliberately deferred

| Question | When it must be answered |
|---|---|
| Does anything ever leave the machine? | Before any team feature. It is where the money is and it is the one thing that would break the promise. |
| A price, and what is free | After there are users. The aha loop must stay free regardless. |
| Windows or Linux | Probably never — the entire read layer is macOS-specific. A port is a rewrite. |
| Editors beyond VS Code and Cursor | When someone asks. `EditorFamily.all` is one line per editor, after checking its bundle identifier. |
| Correcting a wrong project in the panel | Once we know it is wrong often enough to matter. |

---

## What needs you, and what needs me

**You:**
- The manual pass for A2 when it lands. Step 2 is the one that matters: switch between two VS Code windows and press the key *immediately*. If it names the project you just left, the wait is too short.
- Two calls on A3: FlowTrace disappearing from the Dock and ⌘-Tab entirely, and the "Just before this" list leaving the panel for the Today view.
- Whether to commit the icon work now (it is still uncommitted in the tree).

**Me:** everything else in the order above, one sub-project at a time, each specced and reviewed before code.

---

## How to read the other documents

- `docs/superpowers/audits/2026-09-03-…` — what is wrong with the product, verified. Start here if you want the full list.
- `docs/strategy/2026-09-04-habit-and-adoption.md` — why people would come back. The uncomfortable one.
- `docs/strategy/2026-09-04-sharpness-positioning-and-market.md` — who this is for and what not to build.
- `docs/superpowers/specs/` — one design per sub-project, each reviewed until approved.
- `docs/superpowers/plans/` — the task-by-task implementation of a spec.
