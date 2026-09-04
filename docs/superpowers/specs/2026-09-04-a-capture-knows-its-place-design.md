# A capture knows its place

Sub-project **A2**, taken out of order at the author's request after hitting it within minutes of real use. It implements the audit's core-loop finding "non-browser captures record only app name" and the editor/terminal half of Tier 1.3 (`docs/superpowers/audits/2026-09-03-product-audit-and-launch-roadmap.md`). It builds on **A — capture lands where you pressed the key** (merged), and pushes B (consent), C (redaction), D (first run) and E (launch wrapper) back one slot.

Revised after review. Three things changed materially: the ranking now reads the terminal's **atime** rather than its mtime, because mtime measures output and not you; the place is stored in **metadata only, never `target`**, because a `target` the recorder cannot reproduce splits its spans within 30 seconds; and the whole window-title/Accessibility section is gone — that row already exists in Settings, and I was wrong to call it a defect.

## Problem

Press the capture shortcut in VS Code or a terminal and the panel says **`Code`**. Not which project, not which file — just the app. The note that lands says the same, so a week later the timeline reads "Code" with a sentence under it and no way to tell which of eight projects it was about.

Measured on the author's live database:

| kind | rows | with no `target` | with a url |
|---|---|---|---|
| `app` | 557 | **557** | 0 |
| `browserTab` | 919 | 0 | **919** |
| `agentSession` | 36 | 0 | 0 |

So the browser half of the request is already done — every browser row carries the browser name, the page title *and* the link (`Brave Browser · Fuzail Kazi | LinkedIn · https://linkedin.com/in/fuzail-kazi/`). The app half has never once worked, for two reasons:

1. **The panel never asks.** `FrontmostSnapshot.capture()` collects `localizedName` and `bundleIdentifier` and nothing else — no window title, no project, and no pid. Nothing in `Sources/FlowTraceApp/Capture/` reads `LiveState` or Accessibility. So the header says `Code` regardless of any permission.
2. **The recorder's title read returns nothing.** `ActivityRecorder.captureFrontmost` does attempt layer 2 (`captureWindowTitles` defaults true and nothing sets it false), so 557 empty targets mean `AXIsProcessTrusted()` is false: Accessibility is not granted on this machine.

The app does *not* hide that second fact — `SettingsView.recordingSection` already shows "Without Accessibility, entries show the app only" with a **Grant…** button whenever recording is on and the permission is missing. An earlier draft of this spec called that a third defect; it was wrong. The only residue is that `ActivityRecorder.wantsAccessibility` has no reader at all, the Settings row being driven by `AccessibilityPermission.isGranted` instead — which is better, since a flag that only becomes true *after* a failed read would not appear until the damage was done. Delete the dead property.

## Approach

**A capture lands on a place, not on an app.** "Place" is already FlowTrace's unit — `LiveProject` groups agents and servers by repository root precisely because an agent in `tulu` and a server started in `tulu/frontend` are one thing. A note taken in VS Code should join that same place, so the day reads `Code · flowtrace — "fixing the save path"` and the note sits alongside the agents and ports already grouped under `flowtrace`.

The place is resolved by **process inspection plus terminal input recency** — the same permission-free machinery `LiveStateReader` already uses for agents (`ps`/`lsof`/`git rev-parse`), no Accessibility, no Automation, nothing new to grant. Every claim below was measured on the author's machine before being designed, and re-measured by review.

**What the probes found.**

VS Code's own processes are useless: every helper reports cwd `/`. But its integrated terminals are reachable — the chain is `Electron (the app pid) → Code Helper → zsh → cwd`, and those shells sit in real projects. The catch is that one VS Code app held **eight** distinct project cwds across twenty-five shells, so the process tree yields a *set* of candidates, not an answer. `Terminal.app` is worse: nothing descends from its pid at all, its shells having been re-parented to launchd (on this machine via `tmux`; `login` is the usual mechanism but no `login` process was present).

The disambiguator is the tty device's timestamp — but **which** timestamp is the whole design, and the obvious choice is wrong:

- **mtime is output.** It advanced 4.5 seconds on `ttys010` with nobody touching the keyboard, because a streaming agent was printing there. On a machine built for running many agents, mtime would pin whichever project has a live agent to first place forever. Worse, a single system wake touched seven ttys within 0.5 seconds of each other, flattening the ranking into a meaningless tie.
- **atime is input.** A tty's access time advances when something *reads* from it, which is your keystrokes. It separates exactly the cases mtime confuses, and it does not drift: over four seconds with no typing, atime did not move on any tty.

```
tty        mtime_idle  atime_idle   cwd
ttys039            6s          6s   venture/flowtrace        ← where the author actually is
ttys010            0s         85s   venture/flowtrace        ← agent streaming, nobody typing
ttys040           48s       3608s   venture/flowtrace        ← printed recently, left an hour ago
ttys021         4718s      59318s   iq/adk           ┐
ttys008         4718s      60464s   projects/hyperframe ├ mtime ties from one system wake;
ttys022         4718s      67651s   iq/devx          ┘ atime separates them correctly
```

`ps -eo pid,ppid,tty,comm` costs ~77ms over 778 processes; the full probe — `ps` + one batched `lsof` + one `git rev-parse` — measured **~113ms**.

Rejected alternatives:
- *Accessibility window title.* The one exact answer to "which window is in front" (`main.swift — flowtrace`), already coded in the recorder — but it needs a permission the author has not granted, so it would ship and still show `Code`; extracting a project from a title means per-app format guessing; the read is synchronous IPC with a **six-second** default timeout, which cannot sit inside the panel's 1.5-second budget; and the function is `private` on a `@MainActor` class while this resolution runs off the main actor. All risk, and it buys only a nicer header line. Out of scope entirely.
- *Match against live agents/servers.* FlowTrace already knows which repos are live, but with 17 live places that is a guess with no tie-breaker. Superseded by atime, which is the same idea with evidence attached.
- *Reading the editor's argv for a workspace path.* Probed and absent — VS Code's helpers carry only `vscode-window-config`, and this install is App-Translocated anyway.

**Silence beats a wrong answer, and the thresholds enforce it.** A wrong place is not cosmetic: it feeds Smart Capture's highest-priority suggestion source. So a candidate must be recent enough to be believable, and when nothing is, the panel says `Code` exactly as it does today.

## Design

### 1. `PlaceResolver` (new, `Sources/FlowTraceCore/Live/PlaceResolver.swift`)

```swift
/// Where you are working, when the app in front is not a browser.
public struct Place: Sendable, Equatable {
    /// Repository root, canonical — the same key `LiveProject` and `ProjectNote` use.
    public var root: String
    /// "flowtrace" — what a person calls it. From `SessionImporter.folderLabel`,
    /// deliberately: Now already labels this place that way, and two names for
    /// one place is worse than an imperfect name. (In a linked worktree that
    /// means the worktree's own folder, e.g. "smart-capture".)
    public var name: String
    /// The terminal it was read from. Shown only in a tooltip — a tty name
    /// means nothing to most people, but it makes a wrong answer checkable.
    public var tty: String?
    /// How long since anyone last *typed* in that terminal (the tty's atime,
    /// not its mtime: output is not presence).
    public var idleFor: TimeInterval
    public var source: Source

    public enum Source: Sendable, Equatable {
        /// A shell descended from the app in front.
        case ownShell
        /// Nothing descends from the app in front — its terminals are
        /// re-parented (Terminal.app, tmux) — so the most recently typed-in
        /// shell on the machine was taken instead. The weaker answer.
        case recentShell
    }
}

/// A process as `ps` reports it.
public struct ShellProcess: Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    public var tty: String?
    /// Verbatim, because `ps -eo comm` emits absolute paths containing spaces
    /// and parentheses — "…/Code Helper (Renderer).app/…/Code Helper (Renderer)".
    public var command: String
    public init(pid: Int32, ppid: Int32, tty: String?, command: String)
}

public enum PlaceResolver {
    /// How stale a terminal may be and still answer.
    ///
    /// A descendant of the app in front is trusted for a working session: you
    /// can read code for twenty minutes without typing in the terminal you
    /// opened the project from. A shell that merely happens to be the most
    /// recent on the machine gets `LiveStateReader.workingWindow` — the app's
    /// one definition of "actively working" — because that answer is a guess
    /// about a different app entirely.
    public static let ownShellWindow: TimeInterval = 30 * 60
    public static let recentShellWindow: TimeInterval = 120

    public static func place(
        forFrontmost pid: Int32,
        probe: ProcessProbe = SystemProcessProbe(),
        git: GitProbe = GitProbe()
    ) -> Place?

    // MARK: - The testable half

    /// Parses `ps -eo pid,ppid,tty,comm`. Skips the header; keeps `command`
    /// whole by splitting only the first three fields.
    public static func parse(psOutput: String) -> [ShellProcess]

    /// Every descendant of `pid`, walking the parent map. Depth-capped at 64
    /// so a cycle in a malformed table cannot hang the panel.
    public static func descendants(of pid: Int32, in processes: [ShellProcess]) -> Set<Int32>

    /// Processes worth asking for a working directory: a shell with a tty.
    /// Matched on the last path component with any leading `-` stripped, so
    /// `-zsh`, `/bin/zsh` and `/opt/homebrew/bin/zsh` all count. Known shells:
    /// `zsh`, `bash`, `fish`, `sh`, `dash`, `ksh`, `tcsh`, `csh`, `nu`.
    public static func shells(in processes: [ShellProcess]) -> [ShellProcess]

    /// Picks one candidate, or none. Tier first, then input recency, then the
    /// staleness thresholds — see §2.
    public static func rank(
        candidates: [ShellProcess], descendants: Set<Int32>,
        idleForTTY: [String: TimeInterval], rootForPID: [Int32: String]
    ) -> (shell: ShellProcess, source: Place.Source)?
}

/// The three system reads, behind a seam so the composition is testable.
public protocol ProcessProbe: Sendable {
    /// `ps -eo pid,ppid,tty,comm`
    func processTable() -> String
    /// Batched `lsof -a -d cwd -Fpn -p <csv>`, keyed by pid.
    func workingDirectories(for pids: Set<Int32>) -> [Int32: String]
    /// The tty device's atime, as seconds since it was last read from.
    func idleForTTY(_ ttys: Set<String>) -> [String: TimeInterval]
}
```

`SystemProcessProbe` is the real implementation. `processTable()` goes through Core's hardened `Shell.run` (stdin nulled, 5s timeout). `workingDirectories(for:)` is **not reimplemented**: the identical private method on `LiveStateReader` is promoted to `internal static` and called from both. `idleForTTY` uses the existing `FileMeta.stat` helper rather than adding a fourth stat implementation, reading **atime**; a device that cannot be stat'ed is reported as `.greatestFiniteMagnitude`.

`place(forFrontmost:)` composes: `processTable` → `parse` → `shells` → `descendants` → `workingDirectories` for the candidate pids → `idleForTTY` for their ttys → `rank` → `git.topLevel(of:)` for the winner only, then `FilePathCanon.canonical` and `SessionImporter.folderLabel`. A cwd with no git root still yields a `Place` — the folder is the place, and a note about a directory beats a note about an app.

### 2. Ranking rules

In order:
1. **Tier.** Any candidate that is a descendant of the frontmost app beats any that is not. This makes VS Code's integrated terminal authoritative over an unrelated Terminal window.
2. **Input recency.** Within a tier, the tty with the smallest atime-idle wins.
3. **Staleness.** The winner is discarded — and `place` returns nil — if its idle exceeds `ownShellWindow` (30 min) for a descendant, or `recentShellWindow` (120s) for a non-descendant. A stale answer is a wrong answer waiting to be believed.
4. **Unreadable.** A candidate whose cwd cannot be read is dropped before ranking (not ranked-and-skipped), so a readable but staler sibling can still answer. A tty that cannot be stat'ed sorts last by construction and is then almost always cut by rule 3.
5. **Nothing left → nil**, and the panel behaves exactly as today: the app's name. Silence over a bad guess.

**What tier cannot do, stated plainly:** all twenty-five shells under VS Code's helper are equally descendants of the app pid, across eight projects. Rule 1 distinguishes *apps*, not *windows*. So for a multi-window editor the answer is "the project whose terminal you typed in most recently", which is usually but not always the window in front. That is why the hedge in §3 is on `idleFor`, not on `source` — `.ownShell` can be wrong too, just less often.

### 3. Where it runs, and what the user sees

Resolution costs three subprocesses, so it never runs on the main actor. It joins the panel's existing enrichment in `QuickCaptureView.load()`:

- **Not a browser** (`matchedBrowser == nil`): the detached task calls `PlaceResolver.place(forFrontmost:)` and publishes the result into `resolved.place`.
- **A browser**: not resolved at all. A tab is already a better answer than a directory.

**`enrichmentFinished` is not gated on the place**, and A's bounded 1.5-second wait in `save()` is untouched. An earlier draft gated it on the theory that the note's destination depends on the place; it does not — `CaptureTargeting.plan` reads `appName`, `bundleIdentifier`, `pageTitle`, `url`, `openTabCount`, `isBrowser` and `automationDenied`, and never the place. Whatever has arrived by write time is what gets stored. So a non-browser capture continues to wait for nothing, as today.

`FrontmostSnapshot` gains **`var pid: pid_t?`**, set in `capture()` from `frontmostApplication.processIdentifier`. This is load-bearing: by the time the detached task runs, FlowTrace itself is frontmost, so a resolver that asked the system for the frontmost pid would walk FlowTrace's own subtree and return a plausible, wrong answer with no error.

In the header, `summary` returns `place.name` for a non-browser that resolved — so the header reads **`flowtrace`** in the slot a page title occupies for a browser. The existing `detail` line already renders the app name separately, so `detail` returns only the hedge, never the app name again: `best guess from your terminals` for `.recentShell`, and for `.ownShell` a plain relative time via a `RelativeTime.label(for:)` helper extracted from `LiveAgent.lastActivityLabel` (an instance property today, so it needs lifting to a shared static rather than being referenced in place). The tty goes in `.help(…)`, not the line. The word "typed" carries the meaning: *typed here 2m ago* is checkable; "just now" would be a claim about presence the data cannot support.

### 4. What is stored

**The place goes in `metadata`, never in `target`.** `ActivityEvent.describesSameActivity` compares `target`, and with Accessibility off — the author's actual state, and the reason for the 557 — the recorder builds VS Code events with `target = nil`. A capture writing `target = "flowtrace"` would be closed and replaced by the recorder's very next tick (≤30s), leaving a truncated `Code · flowtrace` span followed by a long bare `Code`, with the noted row orphaned beyond resumption. That is worse span quality than today, and it breaks the coalescing symmetry sub-project A depends on. `metadata` is not compared, so it is free.

Concretely:
- `CaptureSite` gains `placeName: String?` and `placeRoot: String?`. `CaptureTargeting`'s "site as event" sets `metadata["place"] = placeName` and `metadata["cwd"] = placeRoot`, leaving `target` alone for a non-browser.
- **`annotateOpen` must carry the place too, or the dominant path gets nothing.** Only `beginSpan` and `recordPoint` build "site as event", and the configuration that produced all 557 rows — recording on, same app, no url — resolves to `.annotateOpen`. So `CapturePlan.annotateOpen` gains a place back-fill beside `backfillURL`/`backfillTitle`, and because `Store.describeActivity(id:target:url:)` cannot write metadata, a new store affordance is required: `Store.describeActivity(id:metadata:)` merging keys into the existing dictionary (merge, not replace — `tabsOpen`, `asked` and `messages` live there). A's `annotate(_:with:at:backfill:)` applies it on the same path and under the same rule: only when the note is actually landing on that row, never when it has been diverted to a rescue point.
- `QuickCaptureView.recordPoint(_:at:)` — A's rescue path — builds its event from `resolved` and must carry the place as well, or a diverted note loses it.
- The timeline row renders the place from `metadata["place"]`, falling back to `target`. This is the one carve-out from §5's exclusion of display work: without it nothing visible changes and the sub-project has no observable effect.

Storing `cwd` has a second payoff: Smart Capture's highest-priority source is the project note for `metadata["cwd"]`, which until now appeared only on imported agent sessions. With it on captured rows, pressing the shortcut in a repo you have written a project note for suggests that note — the other half of Tier 1.3, for no extra work. This is also why the `annotateOpen` back-fill matters: `projectNoteCandidate()` reads `metadata["cwd"]` off the open span and `leadingUp`, so without it the suggestion never fires on the common path either.

### 5. Out of scope

The window title and anything Accessibility-dependent (see Approach). Correcting a wrong place from inside the panel — `metadata["cwd"]` means a wrong place stays repairable later, which is the argument for deferring the picker. Resolving a place for the recorder's own ambient rows. The Now view's labelling, apart from the timeline row named in §4. Warp/WezTerm integrations. Anything in B, C, D or E.

### 6. Decisions to confirm at review

1. **A wrong place is shown, hedged, and not correctable.** The copy carries the confidence rather than a false claim of presence. Confirm that is enough without a picker.
2. **The two thresholds — 30 minutes and 120 seconds.** They are judgement calls. Too tight and the feature rarely fires; too loose and it fires wrongly. 120s reuses `LiveStateReader.workingWindow` so the app keeps one definition of "actively working".

## Testing

`Sources/FlowTraceTests/PlaceResolverTests.swift`, registered in `main.swift`. The `ProcessProbe` seam makes the composition testable too, which matters because the one composition bug with real consequences — walking the wrong pid — is invisible at runtime.

- `parse`: a captured `ps` sample including the header, a `??` tty, a `-zsh` login form, `/opt/homebrew/bin/zsh`, and **`…/Code Helper (Renderer).app/Contents/MacOS/Code Helper (Renderer)`** — the spaces-and-parentheses case a naive whitespace split corrupts. Assert `command` intact *and* `tty` correct on that row.
- `descendants`: the real chain `Electron 29392 → Code Helper 3562 → zsh 3569` reaches the shell; an unrelated shell is excluded; a self-parenting cycle terminates; the depth cap holds.
- `shells`: accepts `zsh`, `-zsh`, `-bash`, `/bin/bash`, `/opt/homebrew/bin/zsh`, `fish`; rejects `Code Helper`, `claude`, `TMUX`, and anything with no tty.
- `rank`, using the probe's real numbers: a descendant at 54811s idle **loses to nothing** — it is cut by `ownShellWindow` — while a descendant at 6s wins over a non-descendant at 0s (tier beats recency). Among two descendants the less idle wins. Among non-descendants, one at 85s wins and one at 3608s yields nil (`recentShellWindow`). A candidate with an unreadable cwd is absent from `rootForPID` and must not be selected while a readable sibling exists. Empty candidates → nil.
- `place(forFrontmost:)` with a stub `ProcessProbe`: resolves the expected root for the VS Code chain; returns nil when the frontmost pid has no shells and every other shell is stale; and — the regression that matters — **asked for a pid whose subtree contains no shells, it must not return a `.ownShell` answer from another app's subtree.**

Not unit-testable in the Core-only harness: `SystemProcessProbe`'s three system reads, the snapshot and header changes, the timeline row. Covered by the manual pass.

## Manual verification

The author's machine is the ideal fixture: eight projects open in one VS Code, a `Terminal.app` whose shells are re-parented, a tmux session, and agents streaming to several ttys.

1. In VS Code, type something in the integrated terminal of the `flowtrace` worktree, then press the shortcut. The header reads **`smart-capture`** — the worktree's own folder, which is what Now calls that place too — with `Code · typed here just now` beneath. Save, then `Scripts/verify-capture.sh notes` shows `metadata` carrying `place` and `cwd`, and `target` still empty for an `.app` row.
2. Type in a different project's terminal, press the shortcut → the header follows to that project.
3. **The mtime trap:** find a terminal where an agent is streaming but you have not typed for a while, focus VS Code, and press the shortcut → it must *not* resolve to that project. This is the case the first draft got wrong.
4. In `Terminal.app` at some repo, type, then press the shortcut → resolves via the recency fallback and the line says `best guess from your terminals`.
5. Over an app with no terminal in its tree and nothing typed anywhere for a few minutes — TextEdit, WhatsApp — the header is the app name, as today. No wrong guess.
6. In a browser → unchanged: page title, host, link stored. Confirm no regression.
7. **Coalescing, the risk this design exists to avoid:** with recording on, capture in VS Code, then wait out two recorder ticks (~60s) and check `Scripts/verify-capture.sh peek`. There must be **one** span for `Code`, not a truncated noted one followed by a fresh bare one.
8. Press the shortcut in a repo with a project note → Smart Capture suggests it.
9. The panel must still draw instantly; the place arriving a beat later is fine, a stall is not.
