# A capture knows its place

Sub-project **A2**, taken out of order at the author's request after hitting it within minutes of real use. It implements the audit's core-loop finding "non-browser captures record only app name" and the editor/terminal half of Tier 1.3 (`docs/superpowers/audits/2026-09-03-product-audit-and-launch-roadmap.md`). It builds on **A — capture lands where you pressed the key**, and pushes B (consent), C (redaction), D (first run) and E (launch wrapper) back one slot.

## Problem

Press the capture shortcut in VS Code or a terminal and the panel says **`Code`**. Not which project, not which file — just the app. The note that lands says the same, so a week later the timeline reads "Code" with a sentence under it and no way to tell which of six projects it was about.

Measured on the author's live database:

| kind | rows | with no `target` | with a url |
|---|---|---|---|
| `app` | 557 | **557** | 0 |
| `browserTab` | 919 | 0 | **919** |
| `agentSession` | 36 | 0 | 0 |

So the browser half of the request is already done — every browser row carries the browser name, the page title *and* the link (`Brave Browser · Fuzail Kazi | LinkedIn · https://linkedin.com/in/fuzail-kazi/`). The app half has never once worked. Three separate causes:

1. **The panel never asks.** `FrontmostSnapshot.capture()` collects `localizedName` and `bundleIdentifier` and nothing else — no window title, no project. Nothing in `Sources/FlowTraceApp/Capture/` reads `LiveState` or Accessibility. So the header says `Code` regardless of any permission.
2. **The recorder's title read returns nothing.** `ActivityRecorder.captureFrontmost` does attempt layer 2 (`captureWindowTitles` defaults true and nothing sets it false), so 557 empty targets mean `AXIsProcessTrusted()` is false: Accessibility is not granted.
3. **And the app never says so.** The recorder sets `wantsAccessibility = true` when the read fails, and nothing anywhere reads that property. The app degrades silently and permanently.

## Approach

**A capture lands on a place, not on an app.** "Place" is already FlowTrace's unit — `LiveProject` groups agents and servers by repository root precisely because an agent in `tulu` and a server started in `tulu/frontend` are one thing. A note taken in VS Code should join that same place, so the day reads `Code · flowtrace — "fixing the save path"` and the note sits alongside the agents and ports already grouped under `flowtrace`.

The place is resolved by **process inspection plus terminal recency** — the same permission-free machinery `LiveStateReader` already uses for agents (`pgrep`/`lsof`/`git rev-parse`), no Accessibility, no Automation, nothing new to grant. This was verified empirically on the author's machine before being designed; the findings below are why the design has the shape it does.

**What the probe found.** VS Code's own processes are useless — every helper reports cwd `/`. But its integrated terminals are reachable: the chain is `Electron (the app pid) → Code Helper → zsh → cwd`, and those shells sit in real projects. The catch is that one VS Code app held **six** distinct project cwds across thirteen shells, so the process tree yields a *set* of candidates, not an answer. `Terminal.app` is worse: its shells are re-parented to launchd (via `login`, and in one case `tmux`), so no shell descends from its pid at all.

The disambiguator is **the tty's last-write time**, which is free to read and ranked the author's six candidates correctly on the first try:

```
ttys010   idle     0s   /Users/fu2ail/venture/flowtrace     ← the session in front
ttys008   idle  3963s   /Users/fu2ail/projects/hyperframe
ttys006   idle 54811s   /Users/fu2ail/armor/videos
ttys012   idle 80165s   /Users/fu2ail/iq/adk
ttys001   idle 319917s  /Users/fu2ail/cc/agentTeam1
```

`ps -eo pid,ppid,tty,comm` over 770 processes costs 63ms, once.

Rejected alternatives:
- *Accessibility window title only.* It is the one exact answer to "which window is in front" (`main.swift — flowtrace`), and it is already coded in the recorder. But it needs a permission the author has not granted, so it would have shipped and still shown `Code`; and extracting a project from a title means per-app format guessing. It is kept as an **enrichment**, not the mechanism — see §5.
- *Match against live agents/servers.* Cheapest, and FlowTrace already knows which repos are live — but with 17 live places it is a guess with no tie-breaker. Superseded by tty recency, which is the same idea with evidence attached.
- *Reading the editor's argv for a workspace path.* Probed and absent: VS Code's helpers carry only `vscode-window-config`. (This install is also App-Translocated, which would defeat path-based heuristics anyway.)

**This is a ranked guess, and the design says so.** The panel shows the place it chose *and* how stale that evidence is, so a wrong answer is visible rather than silent. Correcting it in the panel is deliberately out of scope for this sub-project (see §7).

## Design

### 1. `PlaceResolver` (new, `Sources/FlowTraceCore/Live/PlaceResolver.swift`)

```swift
/// Where you are working, when the app in front is not a browser.
public struct Place: Sendable, Equatable {
    /// Repository root, canonical — the same key `LiveProject` and `ProjectNote` use.
    public var root: String
    /// "flowtrace" — what a person calls it.
    public var name: String
    /// The terminal this was read from, e.g. "ttys010". Shown so a wrong
    /// answer is checkable.
    public var tty: String?
    /// How long since that terminal last wrote anything. The evidence for the
    /// ranking, surfaced because "10 seconds ago" and "four days ago" deserve
    /// different amounts of trust.
    public var idleFor: TimeInterval
    public var source: Source

    public enum Source: Sendable, Equatable {
        /// A shell descended from the app in front.
        case ownShell
        /// No shell descends from it — its terminals are re-parented (Terminal.app,
        /// tmux) — so the most recently used shell on the machine was taken instead.
        case recentShell
        /// The window title said so. Needs Accessibility; beats both of the above.
        case windowTitle
    }
}

/// A shell as `ps` reports it, with what could be read about it.
public struct ShellProcess: Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    public var tty: String?
    public var command: String
    public init(pid: Int32, ppid: Int32, tty: String?, command: String)
}

public enum PlaceResolver {
    /// One `ps`, one batched `lsof`, and a memoised `git rev-parse` per root.
    public static func place(
        forFrontmost pid: Int32, git: GitProbe = GitProbe()
    ) -> Place?

    // MARK: - The testable half

    /// Parses `ps -eo pid,ppid,tty,comm` output into processes.
    public static func parse(psOutput: String) -> [ShellProcess]

    /// Every descendant of `pid`, by walking the parent map. Depth-capped so a
    /// cycle in a malformed table cannot hang the panel.
    public static func descendants(of pid: Int32, in processes: [ShellProcess]) -> Set<Int32>

    /// The shells worth asking about a working directory: a login shell or a
    /// known shell binary, with a tty.
    public static func shells(in processes: [ShellProcess]) -> [ShellProcess]

    /// Ranks candidates and picks one. Descendants of the app in front win
    /// outright; among equals, the terminal that wrote most recently wins.
    public static func rank(
        candidates: [ShellProcess], descendants: Set<Int32>,
        idleForTTY: [String: TimeInterval], rootForPID: [Int32: String]
    ) -> (shell: ShellProcess, source: Place.Source)?
}
```

`place(forFrontmost:)` composes these: run `ps -eo pid,ppid,tty,comm` through the existing `Shell.run` (already hardened — stdin nulled, 5s timeout); `parse`; `shells`; `descendants`; read each candidate's cwd with **one** batched `lsof -a -d cwd -Fpn -p <csv>`, exactly as `LiveStateReader.workingDirectories(for:)` does today (that method is reused, not reimplemented); `stat` each tty device for its mtime; `rank`; then `git.topLevel(of:)` for the winner, memoised per cwd across a single call. `name` comes from `SessionImporter.folderLabel(for:)`, so it matches what Now already calls that place. A cwd with no git root still yields a `Place` — the folder is the place — because a note about a directory is better than a note about an app.

Shell detection is by binary name (`zsh`, `bash`, `fish`, `sh`, `dash`, `nu`, `-zsh` and other login-dash forms), which is why `parse` keeps `command` verbatim.

### 2. Ranking rules

In order:
1. Any candidate whose pid is a **descendant of the frontmost app** beats any that is not. This is what makes VS Code's integrated terminal authoritative over an unrelated Terminal window.
2. Within a tier, the **least idle tty** wins.
3. A tty whose device cannot be `stat`ed is treated as maximally idle rather than dropped — it still beats having no answer.
4. If nothing has a tty or a readable cwd, `place` returns nil and the panel behaves exactly as it does today (the app's name). Silence over a bad guess.

`.recentShell` (nothing descends from the app in front) carries a real risk of being wrong, which is precisely why `Place` carries `tty` and `idleFor` and the panel shows them.

### 3. Where it runs, and when

Resolution costs three subprocesses, so it never runs on the main actor. It joins the panel's existing two-step enrichment (`QuickCaptureView.load()`), which already resolves a browser tab in a detached task:

- **Not a browser** (`matchedBrowser == nil`): the detached task calls `PlaceResolver.place(forFrontmost:)` and publishes it into `resolved.place`, then sets `enrichmentFinished`.
- **A browser**: unchanged. The place is not resolved at all — a browser tab is already a better answer than a directory.

`enrichmentFinished` must be set only *after* the place lands, because the note's destination now depends on it. A's bounded 1.5-second wait in `save()` therefore covers this too, and its timeout behaviour is already correct: on expiry the capture proceeds with whatever is known, which is the app's name — today's behaviour, not a regression. `ActivityRecorder` is **not** changed; it keeps recording spans as it does, and A's `CaptureTargeting` rules keep working on `bundleIdentifier`, which a place never affects.

### 4. What the user sees, and what is stored

- `FrontmostSnapshot` gains `var place: Place?`. `summary` returns `place.name` for a non-browser that resolved (so the header reads **`flowtrace`**, in the same slot the page title occupies for a browser); `detail` returns the app name plus the evidence — `Code · ttys010, just now` — using the existing `LiveAgent.lastActivityLabel` phrasing so the app has one vocabulary for "how long ago". A `.recentShell` answer is additionally hedged in that line ("most recent terminal"), because that is the case that can be wrong.
- `CaptureSite` gains `placeName`/`placeRoot`, and `CaptureTargeting`'s "site as event" sets `target = placeName` and `metadata["cwd"] = placeRoot`. So the stored row finally reads `Code · flowtrace` on the timeline instead of a bare `Code` — the 557-empty-target number goes to zero for anything resolvable.
- Storing `cwd` has a second payoff for free: Smart Capture's highest-priority source is the project note for `metadata["cwd"]`, which until now only ever appeared on imported agent sessions. With it on captured rows, pressing the shortcut in a repo you have written a project note for will suggest that note — the other half of Tier 1.3, obtained without extra work.
- `ActivityEvent.describesSameActivity` compares `target`, so a resolved place participates in coalescing: two captures in the same project coalesce, and moving to another project starts a new span. That is the desired behaviour and needs no change to the comparison.

### 5. Accessibility, told honestly (small, and the third defect)

`ActivityRecorder.wantsAccessibility` has no reader. Surface it: Settings' recording section gains a row that appears only when it is true — "Window titles need Accessibility" with the existing `AutomationPermission.openSettings()`-style button (`CaptureTrigger.swift` already has the Accessibility equivalent for the shortcut). Copy in the Journal voice, stating what it buys: without it FlowTrace can tell which project you are in, but not which file.

When Accessibility *is* granted, the panel prefers the window title: `PlaceResolver` gains no new dependency — instead `FrontmostSnapshot` reads the focused window title itself (the recorder's `focusedWindowTitle(of:)` moves to a shared helper rather than being duplicated) and, when it is present, `summary` shows it and `place.source` is `.windowTitle`. The stored `target` still gets the place name so the timeline groups by project, with the title kept in `metadata["window"]`. This is the only part of the design that depends on a permission, and everything works without it.

### 6. Out of scope

Correcting a wrong place from inside the panel; resolving a place for the *recorder*'s ambient rows (this sub-project is about captures, and the recorder's 557 empty targets are fixed for future rows only where a capture lands on them); the Now view's own labelling; Warp/WezTerm-specific integrations; anything in B, C, D or E.

### 7. Decisions to confirm at review

1. **A wrong guess is shown but not correctable.** The evidence line makes it visible; changing it needs a place picker in the panel, which is real UI work and a different conversation. Confirm that showing-with-evidence is enough for now.
2. **`.recentShell` for Terminal.app.** It will occasionally attribute a note to the wrong project — someone with a terminal open in another repo who presses the shortcut over a text editor. The alternative is to return nil for unreachable apps and keep saying `Code`. This design prefers a hedged answer to no answer; say if you would rather it stayed silent.

## Testing

`Sources/FlowTraceTests/PlaceResolverTests.swift` (registered in `main.swift`). The shell-out is not testable in the Core-only harness, which is why parsing and ranking are separate public functions — they are the parts with the logic:

- `parse`: a captured `ps -eo pid,ppid,tty,comm` sample (including a `??` tty, a `-zsh` login form, an absolute `/opt/homebrew/bin/zsh`, and a header line) yields the right processes; the header and blank lines are skipped.
- `descendants`: the real chain from the probe — `Electron 29392 → Code Helper 3562 → zsh 3567` — reaches the shell; an unrelated shell is excluded; a self-parenting cycle terminates instead of hanging; the depth cap holds.
- `shells`: recognises `zsh`, `-zsh`, `/bin/bash`, `/opt/homebrew/bin/zsh`, `fish`; rejects `Code Helper`, `claude`, `TMUX`, and any process with no tty.
- `rank`, using the probe's real numbers: with `3567` (idle 54811s, a descendant) against `89354` (idle 0s, not a descendant), the **descendant wins** — tier beats recency. Among two descendants, the less idle wins. Among two non-descendants, the less idle wins and the source is `.recentShell`. An unstat-able tty loses to a stat-able one but still beats nil. Empty candidates → nil.

Not unit-testable here (subprocesses, AppKit): `place(forFrontmost:)`'s composition, the snapshot changes, the Settings row — covered by the manual pass.

## Manual verification

The author's machine is the ideal fixture: six projects open in one VS Code, a `Terminal.app` whose shells are re-parented, and a tmux session.

1. In VS Code, in a window whose integrated terminal is at `~/venture/flowtrace`, press the shortcut. Header reads **`flowtrace`**, with `Code · ttys010, just now` beneath. Save, and `Scripts/verify-capture.sh notes` shows `target = flowtrace`.
2. Switch to a VS Code window for another project, use its terminal briefly, press the shortcut → the header follows to *that* project.
3. In `Terminal.app` at some repo, press the shortcut → the place resolves via the recency fallback and the evidence line says so.
4. Over an app with no terminal anywhere in its tree and no recent shell — TextEdit, WhatsApp — the header is the app name, as today. No wrong guess.
5. In a browser → unchanged: page title, host, and the link stored (this half already worked; confirm it did not regress).
6. Press the shortcut in a repo that has a project note → Smart Capture suggests it (the `metadata["cwd"]` payoff).
7. Watch the panel appear: it must still draw immediately. The place arriving a beat later is fine; a stall is not.
8. With Accessibility granted, repeat 1 → header shows the window title, the stored `target` is still the project.
