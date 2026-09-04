# Sharpness, positioning, and how this reaches a market

Written as a product review, not a cheerleading exercise. Runs the 3-Question Sharpness Test (Ch 1, *Building Rocketships*) against the three directions currently on the table, then takes a position on category, persona, wedge and sequence.

Companion to `2026-09-04-habit-and-adoption.md`, which establishes the aha loop. Read that first: its finding — that the author himself is not activated — constrains everything here.

---

## The three candidates

| | Problem | Verdict |
|---|---|---|
| **A** | "I don't know what my many coding agents were doing" | **SHARP** — narrow, early, growing fast |
| **B** | "I have too many browser tabs" | **NOT SHARP** — trivial alternatives, free and built in |
| **C** | "I need to orchestrate and plan my agents" | **NOT SHARP *for this product*** — different company, and it costs the only moat |

---

## A — Agent context loss

### Alternatives

Real and numerous, which is a good sign — people are duct-taping:

- `claude --resume` / `codex resume` — the closest alternative, and genuinely good *inside one repository you already know you want*
- Reading `~/.claude/projects/**.jsonl` by hand
- `git status` in each repo, one at a time
- tmux scrollback, terminal history, a Notes file, memory
- **Abandoning the work and redoing it** — the most common alternative, and the most expensive

The gap the alternatives leave is specific and worth naming precisely: **they all require you to already know which repository to ask about.** None answers *"across my 23 repositories, where did I leave something unfinished?"* That is the sharp edge, and `flowtrace scan` answers it in 0.5 s.

### Prevalence

- **Market size — small today.** Developers running *several concurrent* AI coding agents. Not "developers who use AI" (huge); the pain needs plurality. Perhaps low hundreds of thousands globally, and honest to call it a niche.
- **Growth — the strongest axis by far.** In 2024 nobody had eleven agents running. The author has eleven *today*. Agent count per developer is going one direction, fast, and the pain scales superlinearly with it: two agents you hold in your head, eleven you cannot. A shrinking problem is a hard no; this is the opposite.
- **Niche-ness — role-specific and narrow.** Developer, and specifically a heavy agent user. Narrow is survivable when frequency is high.
- **Frequency — daily, often several times a day.** The strongest thing about this problem. A daily problem sustains a business at a fraction of the market size a monthly one needs.

### Value

Nobody spends money on this today, so estimate from time. Re-deriving lost context costs 15–30 minutes; on the author's own machine there are three abandoned repositories, one with 15 uncommitted files and 8 unpushed commits, stopped 38 days ago. Two or three of those a week at developer rates is a few hundred dollars a month of waste.

Willingness to pay is the weak axis. Personal developer tooling has historically been paid for grudgingly — but that has *changed*: this exact audience now pays $20–200/month for Cursor and Claude Code subscriptions. They pay for throughput. The honest read: **$5–15/month solo, meaningfully more when it becomes a team's visibility tool** (see Persona 4).

### The 3× bar

- Against `claude --resume` for one known repo: **FlowTrace loses.** Don't compete there.
- Against manually checking 23 repositories: **0.5 seconds versus twenty minutes.** Comfortably past 3×, arguably 10×.
- Against "abandon and redo": unbounded.

**Verdict: SHARP**, on frequency and growth, with the sharpest edge being *cross-repository discovery* rather than single-repository recall. Market size is the risk, and it is a bet on a trend that is visibly happening.

---

## B — Too many browser tabs

Stopping this one early, because it is the most tempting mistake in the question.

- **Alternatives are trivial, free, and already installed.** Chrome/Safari tab groups, Arc's spaces, `⌘⇧T`, bookmarks, and simply closing them. Ch 1's rule is explicit: *if a trivial alternative exists, the problem is not sharp.*
- **The pain is chronic, not acute.** Low-grade annoyance, not lost work. People complain about tabs and change nothing, for years.
- **The graveyard is large.** Workona, Toby, Tab Session Manager, dozens of extensions. Great products, thin businesses.
- **It dilutes the story.** "Tool for developers running many agents" is a sentence someone repeats. "Tool for people with lots of tabs" is a sentence nobody repeats.

**Verdict: NOT SHARP. Do not pursue as a persona.**

Worth being precise, though: the tab *capability* is already built and works well (919 of 919 browser rows carry title and URL). Keep it — as a **secondary benefit to the same developer**, whose tabs are documentation, GitHub issues and Stack Overflow pages *about the work*. That is a feature of persona 1, not a new market.

---

## C — Agent orchestrator

The most seductive direction and, I think, the wrong one for *this* product. Three reasons.

**1. It is a different company.** FlowTrace's entire architecture and claim is passive: read-only, no permission, never attaches to or injects into a process, no network client in the codebase, nothing leaves the device. An orchestrator must do the opposite — spawn, write, inject, plan, control. That is not an extension of this product, it is a rewrite with a different trust model.

**2. The competition is funded and shipping.** Claude Code's own subagents and teams, Conductor (**which you already use — `conductor/workspaces` appears in your own worktree list**), Cursor's background agents, Devin, Factory, and a new one every month. Entering that fight from zero users with a Swift menu-bar app is not a good trade.

**3. It costs the only moat.** "It reads only what your machine already wrote down; nothing leaves the device" is a claim almost nobody else can make, because almost everyone else needs to be in the loop to do their job. Give that up and FlowTrace is a worse version of five better-funded products.

**The better framing, and I'd hold onto this one:**

> An orchestrator is the **cockpit**. FlowTrace is the **flight recorder**.

They are complementary, not competing, and the flight recorder is the better *first* product: it needs no trust, no permissions, no integration, and no behaviour change. It just reads what is already there. It also works across *all* the orchestrators — including the ones that don't exist yet — which is a position no orchestrator can occupy.

**Verdict: NOT SHARP as an extension.** If you genuinely want to build an orchestrator, build it as a separate product and let FlowTrace be its black box.

---

## Personas, ranked

| # | Persona | Sharpness | Verdict |
|---|---|---|---|
| **1** | **Developer running 3+ concurrent agents across several repos** | Sharp: daily, growing, no good alternative for cross-repo discovery | **The only persona to build for now** |
| 2 | Developer with one agent in one repo | Weak — `claude --resume` is sufficient and free | Will arrive on their own as their agent count grows. Don't design for them. |
| 3 | Non-developer knowledge worker, many tabs | Not sharp (see B) | Ignore |
| 4 | Team lead wanting visibility into what agents are doing across a team | **Potentially the sharpest and the only one with real budget** — but requires sync, which breaks the local-only promise | Deliberately later. Note that a "share this brief" export is a bridge that doesn't break the promise. |

Persona 4 deserves a flag: it is where the money is, it is a natural extension (the data model is already per-place), and it is the one thing that would justify a real price. It also requires the single hardest decision this product will face — whether anything ever leaves the machine. Don't decide it now; know it's coming.

---

## The wedge, and it isn't the app

This is the most actionable thing in this document.

The sharpest, most demonstrable, most shareable thing FlowTrace does is **one CLI command that needs no app, no permission, no onboarding, and no behaviour change**:

```
$ flowtrace scan
Read 175 agent sessions across 23 repositories in 0.5s.

Pick up where you left off — 3 things:
  refund · main   you stopped 38d ago
    was Run project on localhost
    15 uncommitted · 8 unpushed
```

That output is a *surprise about your own machine*, produced in half a second, with nothing installed but a binary. It is the aha from the habit document, delivered by the cheapest possible vehicle.

**So the distribution strategy is: the CLI is the product that spreads, the app is the product that retains.**

Concretely:

- `brew install flowtrace` → `flowtrace scan`. One line to try, nothing to configure, nothing to grant, nothing to trust. Contrast with today's path: clone the repo, install Command Line Tools, run `bundle.sh`, `xattr -dr` the quarantine flag. That path converts approximately nobody.
- The output is **screenshottable and self-explaining** — the two properties a thing needs to travel on X. It contains a number about *you* ("23 repositories, 3 abandoned"), which is the format that spreads.
- It is honest: no signup, no cloud, no telemetry — and that is *checkable*, which for this audience is worth more than any claim.

The app then earns the daily habit through the menu-bar count (the habit doc's highest-leverage retention item), and the notes accumulate as a byproduct.

---

## What "getting to market" actually looks like

Sequenced, and deliberately unglamorous at the start.

**Step 1 — Ten people, not a thousand (this week).**
Find ten developers who run several agents. Watch them run `flowtrace scan` on their own machine. Record two things: *did it surface something they'd forgotten*, and *what did they say in the first five seconds*. That is the whole test. If eight of ten are surprised, the problem is sharp and the wedge works. If three are, the audience is wrong or the bar is too high — and you'll have learned it for a day's work instead of a quarter's.

The Sean Ellis bar to aim at eventually: **40% of users say they'd be "very disappointed" if it disappeared.** You cannot measure it at zero users; you can start building toward it at ten.

**Step 2 — Make trying it a single line.** A Homebrew tap and a signed, notarised download. Today's install instructions are a wall; audit item 0.7 covers the mechanics.

**Step 3 — Finish the honesty work (B and C).** The privacy story is the differentiator and two claims in the README are currently false in code (transcripts read before consent; live keys in the scan cache). Launching a privacy-positioned tool with false privacy claims is the one mistake that cannot be walked back. This is not growth work; it is *permission to launch*.

**Step 4 — Give the habit a reason to recur.** Menu-bar count with the forgotten number. Currently ranked as polish; it is the only mechanism in the product that brings someone back.

**Step 5 — Launch narrow and specific.** Not "FlowTrace, know your machine." Something closer to: *"You have eleven coding agents running. Seven have been idle for four days. Can you say what any of them were doing?"* — which is already your README's first line, and it is the best sentence in this repository. Lead with it. Post the scan output, not a feature list.

**Step 6 — Only then widen.** More agents supported (Cursor, Gemini CLI, Aider, OpenCode), then Persona 4 and the export bridge.

---

## What I would not build

- **A tab manager.** Not sharp; crowded; dilutes the story.
- **An orchestrator.** Different company; abandons the moat; funded competitors.
- **Team sync, yet.** It is where the money is and it breaks the promise. Decide it deliberately, later, with users.
- **More capture polish, for now.** Sub-projects A and A2 are correct work, and the habit document explains why they improve the *wrong loop for adoption*. Finish A2 because it is nearly done and it makes the timeline legible; then stop and do the menu bar and the first run.
- **Windows or Linux.** The entire read layer is macOS-specific (`lsof`, AppleScript, Accessibility, `NSWorkspace`). A port is a rewrite.

---

## The honest summary

You do not have product-market fit, and you cannot get it by adding personas — that is the reflex the question contains and it is the one to resist. What you have is a **sharp, narrow, fast-growing problem**, a **genuinely differentiated technical position** (passive, local, permissionless), and **zero users, including yourself**.

The gap between here and PMF is not features. It is ten people who run `flowtrace scan`, are surprised by their own machine, and come back the next morning. Everything in this repository is either in service of that or it is a distraction — including, for the moment, most of what we have been building.

## Analogous case

Ch 1 contrasts Calendly's sharp problem (scheduling across organisations — tedious alternative, high frequency, real cost) with its email-from-app feature (copy-paste works fine — not sharp, shipped only because it unlocked automatic reminders).

FlowTrace's `scan` is the Calendly-scheduling case: the alternative is genuinely painful and the frequency is daily. The tab manager is the email-from-app case: useful, adjacent, and not a reason for anyone to adopt anything.
