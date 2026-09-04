# A capture knows its place

Sub-project **A2**, taken out of order after the author hit it within minutes of real use. It implements the audit's core-loop finding "non-browser captures record only app name" and the editor half of Tier 1.3 (`docs/superpowers/audits/2026-09-03-product-audit-and-launch-roadmap.md`). It builds on **A — capture lands where you pressed the key** (merged), and pushes B (consent), C (redaction), D (first run) and E (launch wrapper) back one slot.

**Third revision, and a different design.** Two earlier drafts resolved the project by inspecting processes and ranking terminals by recency. Review destroyed both rankings with measurements from the author's own machine: tty **mtime** tracks output, so a streaming agent pinned one project to first place permanently; tty **atime** tracks *any* read, and an interactive TUI queries the terminal constantly — over three minutes with nobody typing, exactly the three ttys running a Claude session advanced their atime, and the ranking would have answered `devx` while the author worked in `flowtrace`. Both drafts were elaborate machinery around a signal that does not mean what it claims.

The answer was sitting in a file the editor writes itself. This revision reads that, and does nothing else.

## Problem

Press the capture shortcut in VS Code and the panel says **`Code`**. Not which project, not which file — just the app. The note that lands says the same, so a week later the timeline reads "Code" with a sentence under it and no way to tell which of five open projects it was about.

Measured on the author's live database:

| kind | rows | with no `target` | with a url |
|---|---|---|---|
| `app` | 557 | **557** | 0 |
| `browserTab` | 919 | 0 | **919** |
| `agentSession` | 36 | 0 | 0 |

The browser half of the request is already done — every browser row carries the browser name, the page title *and* the link (`Brave Browser · Fuzail Kazi | LinkedIn · https://linkedin.com/in/fuzail-kazi/`). The app half has never once worked, for two reasons:

1. **The panel never asks.** `FrontmostSnapshot.capture()` collects `localizedName` and `bundleIdentifier` and nothing else. Nothing in `Sources/FlowTraceApp/Capture/` reads any further source. So the header says `Code` regardless of any permission.
2. **The recorder's window-title read returns nothing.** `ActivityRecorder.captureFrontmost` does attempt it (`captureWindowTitles` defaults true and nothing sets it false), so 557 empty targets mean `AXIsProcessTrusted()` is false: Accessibility is not granted here.

The app does *not* hide that second fact — `SettingsView.recordingSection` already shows "Without Accessibility, entries show the app only" with a **Grant…** button. An earlier draft called that a third defect; it was wrong. The only residue is that `ActivityRecorder.wantsAccessibility` has no reader anywhere, the Settings row being driven by `AccessibilityPermission.isGranted` instead — which is better, since a flag that turns true only *after* a failed read would appear too late to help. Delete the dead property.

## Approach

**Ask the editor which window you are in, because it already wrote the answer down.**

VS Code maintains `~/Library/Application Support/Code/User/globalStorage/storage.json`, and inside it:

```
windowsState.lastActiveWindow.folder  → file:///Users/fu2ail/venture/flowtrace
windowsState.openedWindows[].folder   → iq/adk, hyperframe, armor/videos, iq/devx, venture/flowtrace
```

Verified on the author's machine, written 83 seconds before it was read, and correct — `venture/flowtrace` was the focused window while five projects were open. Cursor keeps the same file under its own support directory (it is a VS Code fork); Windsurf, VSCodium and Insiders would too if installed.

This is the same category of source FlowTrace is built on. The README's promise is "It reads only what your machine already wrote down", and its existing sources are exactly that: agent transcripts the agents wrote, git state, listening ports. An editor's own window-state file belongs in that list. It needs **no permission**, costs **one file read**, and — decisively — answers the question process inspection cannot: not "which projects does this app have open" but **"which window is in front"**.

**Terminals are deliberately out of scope, and get their own sub-project.** A terminal has no equivalent state file, and its shells' cwds have the same window-ambiguity problem an editor's terminals do, with no honest discriminator: mtime is output, atime is TUI traffic, and both drafts that tried to rank them produced a wrong answer at the top of the list on the author's machine. `Terminal.app`'s shells are not even reachable from its pid (they are re-parented to launchd; on this machine via `tmux`). That is a real problem worth solving, but it needs its own measurement pass, and bundling it here is what made the last two drafts wrong. **A3** will take it, with the material already gathered recorded in the audit.

Rejected alternatives:
- *Process inspection with terminal recency.* Two drafts, both measured, both wrong at the top of the ranking. Kept out of A2 entirely.
- *Accessibility window title.* The other exact answer (`main.swift — flowtrace`), already coded in the recorder — but it needs a permission the author has not granted, so it would ship and still show `Code`; extracting a project from a title means per-app format guessing; the read is synchronous IPC with a six-second default timeout, which cannot sit inside the panel's budget; and the function is `private` on a `@MainActor` class while enrichment runs off the main actor. All risk, and it buys a nicer header line for a case this design already covers.
- *Match against live agents and servers.* FlowTrace knows which repos are live, but with 17 live places that is a guess with no tie-breaker.

## Design

### 1. `EditorPlace` (new, `Sources/FlowTraceCore/Live/EditorPlace.swift`)

```swift
/// The project an editor has in front, read from the editor's own state file.
public struct Place: Sendable, Equatable {
    /// Repository root, canonical — the same key `LiveProject` and `ProjectNote` use.
    public var root: String
    /// "flowtrace" — what a person calls it. From `SessionImporter.folderLabel`,
    /// deliberately: Now already labels this place that way, and two names for
    /// one place is worse than an imperfect name.
    public var name: String
    /// How long since the editor wrote the file. Surfaced because an answer
    /// from ten seconds ago and one from two days ago deserve different trust.
    public var writtenAgo: TimeInterval
}

/// Editors that keep a readable record of their focused window.
///
/// All of these are VS Code or a fork of it, so one parser serves them all.
/// Adding another is a line in this list, which is the point of keeping it
/// data rather than code.
public struct EditorFamily: Sendable {
    public var bundleIdentifiers: Set<String>
    /// Directory under ~/Library/Application Support.
    public var supportDirectory: String

    public static let all: [EditorFamily] = [
        EditorFamily(bundleIdentifiers: ["com.microsoft.VSCode"], supportDirectory: "Code"),
        EditorFamily(bundleIdentifiers: ["com.microsoft.VSCodeInsiders"], supportDirectory: "Code - Insiders"),
        EditorFamily(bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"], supportDirectory: "Cursor"),
        EditorFamily(bundleIdentifiers: ["com.exafunction.windsurf"], supportDirectory: "Windsurf"),
        EditorFamily(bundleIdentifiers: ["com.visualstudio.code.oss"], supportDirectory: "VSCodium"),
    ]

    public static func matching(bundleIdentifier: String?) -> EditorFamily?
}

public enum EditorPlace {
    /// The freshest answer an editor is willing to give, or nil.
    ///
    /// `staleness` bounds how old the file may be. It is generous on purpose:
    /// the file records the window you last focused, which stays true while
    /// you are in that window — and if the editor is not in front, nothing
    /// asks. It exists only to refuse an answer from a previous session.
    public static func place(
        forBundleIdentifier id: String?,
        support: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support"),
        staleness: TimeInterval = 7 * 24 * 3600,
        git: GitProbe = GitProbe()
    ) -> Place?

    // MARK: - The testable half

    /// The focused window's folder path, from the contents of a
    /// `globalStorage/storage.json`.
    ///
    /// Only `windowsState.lastActiveWindow.folder` is read. `openedWindows` is
    /// deliberately ignored: it is the set of projects open, which is the
    /// ambiguity this design exists to avoid, not an answer.
    public static func lastActiveFolder(inStorageJSON data: Data) -> String?
}
```

`place(forBundleIdentifier:)` composes: match the family; read `<support>/<dir>/User/globalStorage/storage.json`; refuse if its modification date is older than `staleness`; `lastActiveFolder`; convert the `file://` URL to a path; `git.topLevel(of:)` for the repository root, falling back to the folder itself when it is not a repository — a note about a directory beats a note about an app; `SessionImporter.folderLabel` for the name.

`lastActiveFolder` handles what the format actually does: `folder` is a percent-encoded `file://` URL and must be decoded (a path with a space arrives as `%20`); a window opened on a multi-root workspace has `workspaceIdentifier` instead of `folder` and yields nil rather than a guess; an untitled window has neither. It uses `JSONSerialization` and returns nil on anything malformed — this file is written by another program and its shape is not a contract.

### 2. Where it runs

One file read, so it is cheap — but it is still I/O and `load()` must not block, so it joins the panel's enrichment in `QuickCaptureView.load()` as **its own detached task**, publishing into `resolved.place`. Not inside the existing tab-resolution task: that one flips `enrichmentFinished`, and putting the place before that flip would make every non-browser capture wait on A's 1.5-second bound, which today it never does.

**`enrichmentFinished` is not gated on the place**, and A's wait is untouched. `CaptureTargeting.plan` reads `appName`, `bundleIdentifier`, `pageTitle`, `url`, `openTabCount`, `isBrowser` and `automationDenied` — never a place. Whatever has arrived by write time is stored; if nothing has, the capture behaves exactly as today.

Only editors are asked. A browser is never asked (a tab is a better answer than a directory); anything not in `EditorFamily.all` is never asked, and its capture is unchanged.

`FrontmostSnapshot` gains `var place: Place?` — no pid, no process walk, nothing else. `FrontmostSnapshot.site` maps `place.name` and `place.root` into two new `CaptureSite` fields, `placeName` and `placeRoot`.

### 3. What the user sees

`summary` returns `place.name` for a non-browser that resolved, so the header reads **`flowtrace`** in the slot a page title occupies for a browser. The app name is already rendered separately, so `detail` is unchanged for browsers (it keeps the URL host) and for a resolved editor it reads `VS Code's current window` — a statement about *where the answer came from*, not a claim about presence. That phrasing is deliberate: the two previous drafts wrote "typed here just now", which the data could not support. This one can, because the editor said so.

No time is shown. `writtenAgo` exists for the staleness refusal and for a tooltip, not for the line — the answer is either the editor's current window or it is nothing.

### 4. What is stored

**The place goes in `metadata`, never in `target`.** `ActivityEvent.describesSameActivity` compares `target`, and with Accessibility off — the author's state, and the reason for the 557 — the recorder builds VS Code events with `target = nil`. A capture writing `target = "flowtrace"` would be closed and replaced by the recorder's very next tick (≤30s), leaving a truncated noted span followed by a long bare `Code`, the noted row orphaned beyond resumption. Worse span quality than today, and it breaks the coalescing symmetry A depends on. `metadata` is not compared, so it is free.

- `CaptureTargeting`'s "site as event" sets `metadata["place"]` and `metadata["cwd"]` from the site, leaving `target` alone.
- **`annotateOpen` needs the place too**, or the dominant path gets nothing: only `beginSpan` and `recordPoint` build "site as event", and the configuration that produced all 557 rows — recording on, same app, no url — resolves to `.annotateOpen`. So `CapturePlan.annotateOpen` carries a place back-fill beside `backfillURL`/`backfillTitle`. Because `Store.describeActivity(id:target:url:)` cannot write metadata, a new affordance is required: **`Store.describeActivity(id:metadata:)`**, *merging* keys rather than replacing — `tabsOpen`, `asked` and `messages` share that dictionary.
- **`beginSpan` needs it applied to the row, not the event.** `Store.beginActivity` has two paths that discard the event entirely and return a pre-existing row: the coalesce (`if open.describesSameActivity(as: event) { return open }`) and the five-minute resume. Alt-tab to Slack and back within five minutes, capture, and the freshly resolved place is thrown away. So the back-fill is applied to whatever row `beginActivity` returns, on the same "only the row the note lands on" rule A already uses — never to a row a note was diverted from.
- **A nil resolution clears the place.** Merging alone would leave a *previous* capture's place on the recorder's long-lived open span: capture in A, switch to B, capture again with no answer, and B's sentence sits on a row labelled `Code · A`. That is worse than today. So place and note are written together or not at all: when resolution yields nil, the back-fill removes `place` and `cwd` from the row.
- `QuickCaptureView.recordPoint(_:at:)` — A's rescue path — must carry the place as well, or a diverted note loses it.
- `TimelineRow` renders the place from `metadata["place"]`, but **after** `target`, not before: if Accessibility is ever granted, a specific window title is a better label than a coarser project name, and should not be hidden behind it.
- A capture can never write to an `agentSession` row, so `upsertImportedActivity`'s wholesale `metadata` overwrite cannot destroy a captured place: `annotateOpen` only ever targets the open span, and only the recorder and the panel write open rows. `describeActivity(id:metadata:)` is new public API with no such guard, so it carries that invariant in its doc comment.

### 5. Smart Capture, wired properly

Storing `cwd` is meant to feed Smart Capture's highest-priority source — the project note for `metadata["cwd"]`. Two things have to be true for that, and neither is automatic:

- **The resolved place must reach the suggestion directly.** `projectNoteCandidate()` reads `metadata["cwd"]` from the open span and `leadingUp` — i.e. from *earlier* rows — while the freshly resolved place is only written on save. So it prefers `resolved.place?.root` and falls back to row metadata, and `recomputeSuggestion` is called when the place lands (today it runs only in `load()` and the tab continuation).
- **Otherwise a stale `cwd` hijacks it.** Today `metadata["cwd"]` appears only on closed `agentSession` rows. A2 makes the *open* VS Code span the dominant carrier, and that span outlives the project it was written in: capture in A, work in B for an hour, capture in B, and the top-priority suggestion is A's "what am I building". Preferring the live answer removes it; the fallback retains a weaker version, which is acceptable only because the fallback is now rarely reached.

### 6. Out of scope

Terminals — A3, with its own measurement pass. The window title and anything Accessibility-dependent. Correcting a place from inside the panel (`metadata["cwd"]` keeps it repairable later). Resolving a place for the recorder's ambient rows. JetBrains and Sublime, whose formats differ and which are absent here — `EditorFamily.all` is where they would go. Anything in B, C, D or E.

### 7. Decisions to confirm at review

1. **`staleness` of seven days** is generous by design: the file records the window you last focused, which remains true for as long as you stay in it, and nothing asks unless that editor is frontmost. It exists only to refuse an answer left by a previous session. Confirm, or tighten.
2. **Multi-root workspaces yield nil**, not a first-root guess. That is the silence-over-a-guess rule; say if you would rather have the first root.

## Testing

`Sources/FlowTraceTests/EditorPlaceTests.swift`, registered in `main.swift`. The file read is the only untestable part, which is why parsing is a separate public function over `Data`:

- `lastActiveFolder`: a real captured `storage.json` (trimmed, with the author's paths replaced) yields the focused folder and **not** any of the five `openedWindows` entries; a percent-encoded path (`file:///Users/dev/my%20project`) decodes; a window with `workspaceIdentifier` and no `folder` yields nil; missing `windowsState`, missing `lastActiveWindow`, an empty object, truncated JSON, and non-JSON bytes all yield nil rather than throwing.
- `EditorFamily.matching`: each listed bundle id resolves to the right support directory; `com.apple.Safari` and nil resolve to nothing.
- `place(forBundleIdentifier:support:staleness:)` against a temporary directory containing a fixture `storage.json`: resolves the folder; refuses when the file's modification date is beyond `staleness`; returns nil for a bundle id with no family, for a missing file, and for a folder that no longer exists on disk.
- `Store.describeActivity(id:metadata:)`: merges without clobbering an existing `tabsOpen`/`asked`; removes `place` and `cwd` when passed nil for them (the clearing path in §4); leaves an unrelated row untouched.

Not unit-testable in the Core-only harness: the snapshot and header changes, the timeline row, the Smart Capture wiring — covered by the manual pass.

## Manual verification

1. **The case that started this.** In a VS Code window on `venture/flowtrace`, press the shortcut. The header reads **`flowtrace`** with `Code · VS Code's current window` beneath. Save, then `Scripts/verify-capture.sh notes` shows `metadata` carrying `place` and `cwd`, and `target` still empty for an `.app` row.
2. **The freshness question, which is the one real risk.** Switch to a VS Code window on a *different* project and press the shortcut immediately. The header must follow. If it lags, VS Code writes `storage.json` on a timer rather than on window focus, and §1's staleness bound is the wrong control — report it rather than working around it, because it decides whether this design holds.
3. In Cursor, if a project is open there → same behaviour, from Cursor's own file.
4. In a terminal, over TextEdit, over WhatsApp → the header is the app name, exactly as today. No guess. (Terminals are A3.)
5. In a browser → unchanged: page title, host, link stored. Confirm no regression.
6. **Coalescing, the risk §4 exists to avoid:** recording on, capture in VS Code, wait out two recorder ticks (~60s), then `Scripts/verify-capture.sh peek`. There must be **one** span for `Code`, not a truncated noted one followed by a fresh bare one.
7. **The stale-place case:** capture in project A, switch VS Code to project B, capture again → B's note must not be labelled `A`. Then quit VS Code and capture over something else → no place at all, not a leftover.
8. Press the shortcut in a repo with a project note → Smart Capture suggests it, on the *first* capture, not the second.
9. The panel must still draw instantly.
