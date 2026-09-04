# A capture knows its place

Sub-project **A2**, taken out of order after the author hit it within minutes of real use. It implements the audit's core-loop finding "non-browser captures record only app name" and the editor half of Tier 1.3 (`docs/superpowers/audits/2026-09-03-product-audit-and-launch-roadmap.md`). It builds on **A — capture lands where you pressed the key** (merged), and pushes B (consent), C (redaction), D (first run) and E (launch wrapper) back one slot.

**Fourth revision.** Two early drafts resolved the project by inspecting processes and ranking terminals by tty timestamps; review destroyed both with measurements from this machine. tty **mtime** tracks output, so a streaming agent pinned one project to first place permanently. tty **atime** tracks *any* read, and an interactive TUI queries the terminal constantly — over three minutes with nobody typing, exactly the three ttys running a Claude session advanced their atime, and the ranking answered `devx` while the author worked in `flowtrace`. Both drafts were elaborate machinery around a signal that did not mean what it claimed.

The third revision moved to the file the editor writes itself, which is the right source. This revision keeps it and fixes the one thing that made it answer the *previous* project — see the write cadence in Approach, which is the most important paragraph in this document.

## Problem

Press the capture shortcut in VS Code and the panel says **`Code`**. Not which project, not which file — just the app. The note that lands says the same, so a week later the timeline reads "Code" with a sentence under it and no way to tell which of five open projects it was about.

Measured on the author's live database:

| kind | rows | with no `target` | with a url |
|---|---|---|---|
| `app` | 557 | **557** | 0 |
| `browserTab` | 919 | 0 | **919** |
| `agentSession` | 36 | 0 | 0 |

The browser half of the request is already done — every browser row carries the browser name, the page title *and* the link (`Brave Browser · Fuzail Kazi | LinkedIn · https://linkedin.com/in/fuzail-kazi/`). The app half has never once worked, for two reasons:

1. **The panel never asks.** `FrontmostSnapshot.capture()` collects `localizedName` and `bundleIdentifier` and nothing else. So the header says `Code` regardless of any permission.
2. **The recorder's window-title read returns nothing.** `ActivityRecorder.captureFrontmost` does attempt it (`captureWindowTitles` defaults true and nothing sets it false), so 557 empty targets mean `AXIsProcessTrusted()` is false: Accessibility is not granted here.

The app does *not* hide that second fact — `SettingsView.recordingSection` already shows "Without Accessibility, entries show the app only" with a **Grant…** button. An earlier draft called that a third defect; it was wrong. The only residue is that `ActivityRecorder.wantsAccessibility` has no reader anywhere, the Settings row being driven by `AccessibilityPermission.isGranted` instead — which is better, since a flag that turns true only *after* a failed read would appear too late to help. Delete the dead property.

## Approach

**Ask the editor which window you are in, because it already wrote the answer down.**

VS Code maintains `~/Library/Application Support/Code/User/globalStorage/storage.json`, and inside it:

```
windowsState.lastActiveWindow.folder  → file:///Users/fu2ail/venture/flowtrace
windowsState.openedWindows[].folder   → iq/adk, hyperframe, armor/videos, iq/devx, venture/flowtrace
```

Verified on this machine, and correct — `venture/flowtrace` was the focused window while five projects were open. Cursor keeps the same file under its own support directory (it is a VS Code fork).

This is the category of source FlowTrace is built on. The README promises "It reads only what your machine already wrote down", and the existing sources are exactly that: agent transcripts the agents wrote, git state, listening ports. An editor's own window-state file belongs in that list. It needs **no permission**, costs one ~100 KB read (~1 ms, off the main actor), and answers the question process inspection cannot: not "which projects does this app have open" but **which window is in front**.

### The write cadence, and why the panel's own activation is load-bearing

This is the mechanism the whole design rests on, established by reading the write path out of the shipped bundle (`Contents/Resources/app/out/main.js`, `windowsStateHandler`):

```js
app.on("browser-window-blur", () => this.t()),  onBeforeCloseWindow,
onBeforeShutdown,  onDidChangeWindowsCount,  onDidDestroyWindow
```

Those are the only triggers. **There is no timer and no `browser-window-focus` handler** — confirmed empirically too: 40 samples over 3m20s with VS Code running and not frontmost left `storage.json`'s mtime frozen, while its sibling `state.vscdb` advanced three times. The saved value is `getLastActiveWindow()`, the window with the highest `lastFocusTime` *at the moment of the write*, and the write itself is 100 ms-throttled and atomic (temp file plus rename, so a reader can never see a torn file).

Two consequences, one bad and one that rescues it:

- **The file records the window you left, not the one you moved to.** macOS delivers `resignKey` to the old window before `becomeKey` to the new one, so on a VS Code→VS Code switch the blur fires while the *old* window still holds the highest `lastFocusTime`. Between switching from A to B and leaving VS Code entirely, the file says **A**.
- **But our own panel is what blurs it.** `QuickCaptureController.present()` calls `NSApp.activate(ignoringOtherApps:)` and `makeKeyAndOrderFront`, which blurs the VS Code window and therefore triggers exactly the save that records B. The catch is timing: that write lands ~100 ms later, while a naive read happens within a few milliseconds and returns A — the sibling project, the worst wrong answer this feature could give.

So the read **waits for its own blur to land**: see §2. Without that wait the feature is subtly and consistently wrong, which is why this paragraph exists rather than a comment in the code.

Rejected alternatives:
- *Process inspection with terminal recency.* Two drafts, both measured, both wrong at the top of the ranking.
- *Accessibility window title.* The other exact answer (`main.swift — flowtrace`), already coded in the recorder — but it needs a permission that is not granted here, so it would ship and still show `Code`; extracting a project from a title means per-app format guessing; the read is synchronous IPC with a six-second default timeout; and the function is `private` on a `@MainActor` class while enrichment runs off the main actor.
- *Match against live agents and servers.* With 17 live places that is a guess with no tie-breaker.

**Terminals are deliberately deferred to A3.** A terminal keeps no equivalent file, its shells have the same window-ambiguity an editor's terminals do with no honest discriminator, and `Terminal.app`'s shells are not even reachable from its pid (re-parented to launchd; here via `tmux`). Bundling it is what made the first two drafts wrong.

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
    /// Which editor said so, for the header line ("Cursor's current window").
    public var editor: String
}

/// Editors that keep a readable record of their focused window.
///
/// All of these are VS Code or a fork of it, so one parser serves them all.
/// Adding another is a line in this list, which is why it is data.
public struct EditorFamily: Sendable {
    public var bundleIdentifiers: Set<String>
    /// Directory under ~/Library/Application Support.
    public var supportDirectory: String
    /// What to call it in the panel. `localizedName` is "Code" for VS Code,
    /// which would render "Code · Code's current window".
    public var displayName: String

    /// Both identifiers below were read from the installed apps' Info.plist on
    /// the author's machine. Other forks are omitted on purpose: an
    /// unverified identifier is silent breakage, and VSCodium in particular
    /// ships `com.vscodium` on release builds, not the oss-dev identifier that
    /// is easy to find by searching. Add one only after checking its plist.
    public static let all: [EditorFamily] = [
        EditorFamily(
            bundleIdentifiers: ["com.microsoft.VSCode"],
            supportDirectory: "Code", displayName: "VS Code"
        ),
        EditorFamily(
            bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
            supportDirectory: "Cursor", displayName: "Cursor"
        ),
    ]

    public static func matching(bundleIdentifier: String?) -> EditorFamily?
}

public enum EditorPlace {
    /// Where the editor's state file lives, so the caller can check its
    /// freshness before and after triggering a write. See §2 — the caller
    /// owns the waiting, because Core has no business polling a clock.
    public static func storageURL(for family: EditorFamily, support: URL) -> URL

    /// Reads the file and resolves the focused window's repository.
    ///
    /// `staleness` refuses a value left over from a previous session. It is
    /// tight (two minutes) for a reason that is easy to get wrong: the file's
    /// mtime is "when a window last lost focus", *not* the age of the value.
    /// VS Code loads the previous session's state at launch and does not
    /// rewrite it until the first blur, so a loose bound would happily return
    /// yesterday's project. With the caller's wait in §2 the file is always
    /// seconds old whenever the answer is trustworthy, so tightness is free —
    /// and it is the only thing that refuses the two genuinely stale states:
    /// a carried-over session, and the editor frontmost with no windows open.
    public static func place(
        forBundleIdentifier id: String?,
        support: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support"),
        staleness: TimeInterval = 120,
        git: GitProbe = GitProbe()
    ) -> Place?

    // MARK: - The testable half

    /// The focused window's folder path, from a `globalStorage/storage.json`.
    ///
    /// Only `windowsState.lastActiveWindow.folder` is read. `openedWindows` is
    /// ignored: it is the set of projects open — the ambiguity this design
    /// exists to avoid — it is empty whenever only one window is open, and its
    /// order is registration order, not recency. It carries no answer.
    public static func lastActiveFolder(inStorageJSON data: Data) -> String?
}
```

`place(forBundleIdentifier:)` composes: match the family; refuse if the file's modification date is older than `staleness`; `lastActiveFolder`; `git.topLevel(of:)` for the repository root, falling back to the folder itself when it is not a repository — a note about a directory beats a note about an app — and running that fallback through `FilePathCanon.canonical`, which `GitProbe.topLevel` already does for its own result; `SessionImporter.folderLabel` for the name.

`lastActiveFolder` handles what the format actually does:
- `folder` is a URL string, and **the scheme must be `file`**. A remote window writes `vscode-remote://ssh-remote+host/home/x/proj` or a dev-container URI; `URL(string:)?.path` would yield `/home/x/proj`, a plausible-looking local path that is not on this machine. Reachable here — the remote-containers extension is installed. Anything not `file` yields nil.
- The path is percent-encoded (`file:///Users/dev/my%20project`) and must be decoded.
- A multi-root workspace window has `workspaceIdentifier` instead of `folder`, and yields **nil** rather than a guess: a `.code-workspace` names several roots in an order that means nothing, and labelling every capture with an arbitrary member is the failure the first two drafts were rejected for.
- An untitled window has neither.
- It uses `JSONSerialization` and returns nil on anything malformed. The atomic write means a torn read is not actually possible, so this is belt-and-braces rather than load-bearing.

### 2. Where it runs, and the wait that makes it correct

The place is resolved in **its own detached task** from `QuickCaptureView.load()` — not inside the existing tab-resolution task, which flips `enrichmentFinished`; putting the place before that flip would make every non-browser capture wait on A's 1.5-second bound, which today it never does.

That task implements the wait Approach explains:

1. Note `openedAt` when the panel opens.
2. If the editor's `storage.json` mtime is already `>= openedAt`, our blur has landed: read it.
3. Otherwise sleep ~40 ms and look again, for up to ~400 ms. Then read whatever is there.

400 ms comfortably covers a 100 ms-throttled write plus the filesystem, and the loop lives entirely inside this task, so `enrichmentFinished` and A's bound stay untouched. The waiting belongs in the App layer: `EditorPlace` stays a pure function of a file's contents plus a freshness check, with no injectable clock.

**Ownership of `resolved` is split between two tasks, so both must be explicit.** The place task mutates **only** `resolved.place`. The tab task assigns whole snapshots (`resolved = identified`, `resolved = counted`) built from a pre-place local, so it must preserve what landed: `var next = identified; next.place = resolved.place; resolved = next`. Today this happens not to matter — `resolvingActiveTab()` returns `self` for a non-browser, so the assignment is skipped by an equality guard — which means the feature would survive by accident and a later change to that function would silently delete it.

Only editors are asked. A browser is never asked (a tab is a better answer than a directory); anything with no `EditorFamily` match is never asked, and its capture is unchanged.

`FrontmostSnapshot` gains `var place: Place?`; `FrontmostSnapshot.site` maps `place.name` and `place.root` into two new `CaptureSite` fields, `placeName` and `placeRoot`. No pid, no process walk.

**`CaptureTargeting.plan`'s choice of case never depends on the place** — it branches on `bundleIdentifier`, `url`, `pageTitle`, `recording` and the browser flags only. The place merely rides along: into the built event for `beginSpan`/`recordPoint`, and into `annotateOpen`'s back-fill. This is what lets it arrive late — `save()` calls `refreshPlan()` immediately before `write(text)`, so the plan is rebuilt from `resolved.site` at save time and picks up a place that landed after `load()`.

### 3. What the user sees

`summary` returns `place.name` for a non-browser that resolved, so the header reads **`flowtrace`** in the slot a page title occupies for a browser. The app name is already rendered separately, so `detail` is unchanged for browsers (it keeps the URL host) and for a resolved editor it reads `\(place.editor)'s current window` — "VS Code's current window", "Cursor's current window". That is a statement about *where the answer came from*, not a claim about presence: the two earlier drafts wrote "typed here just now", which their data could not support. This one can, because the editor said so.

No time is shown. Freshness is enforced by the refusal in §1, not reported.

### 4. What is stored

**The place goes in `metadata`, never in `target`.** `ActivityEvent.describesSameActivity` compares `target`, and with Accessibility off — the state here, and the reason for the 557 — the recorder builds VS Code events with `target = nil`. A capture writing `target = "flowtrace"` would be closed and replaced by the recorder's very next tick (≤30 s), leaving a truncated noted span followed by a long bare `Code`, the noted row orphaned beyond resumption. Worse span quality than today, and it breaks the coalescing symmetry A depends on. `metadata` is not compared, so it is free.

The back-fill carries intent, not just a value, because "no opinion" and "clear it" are different and a `Place?` cannot say which:

```swift
public enum PlaceBackfill: Sendable {
    /// Not an editor — do not touch the row's place. Browsers, TextEdit, everything else.
    case unchanged
    case set(Place)
    /// An editor, but no answer. Remove whatever place is on the row.
    case clear
}
```

`.clear` is used **only** when `EditorFamily.matching(bundleIdentifier:) != nil` and resolution failed. Without that distinction the clearing rule would fire on every browser capture and over TextEdit.

- `CaptureTargeting`'s "site as event" sets `metadata["place"]` and `metadata["cwd"]` from the site, leaving `target` alone.
- **`annotateOpen` needs the place too**, or the dominant path writes nothing: only `beginSpan` and `recordPoint` build "site as event", and the configuration that produced all 557 rows — recording on, same app, no url — resolves to `.annotateOpen`. So `CapturePlan.annotateOpen` carries a `PlaceBackfill` beside `backfillURL`/`backfillTitle`.
- **`beginSpan` must apply it to the row, not the event.** `Store.beginActivity` has two paths that discard the passed event and return a pre-existing row: the coalesce (`if open.describesSameActivity(as: event) { return open }`) and the five-minute resume. Alt-tab to Slack and back within five minutes, capture, and a freshly resolved place would be thrown away. So the back-fill is applied to whatever row `beginActivity` returns, on the same "only the row the note lands on" rule A already uses — never to a row a note was diverted from.
- **`.clear` exists because merging alone strands a stale place.** Capture in A, switch VS Code to B, capture again with no answer: B's sentence would sit on a row labelled `Code · A`, worse than today. Place and note are written together or not at all.
- Writing metadata needs a new affordance, since `Store.describeActivity(id:target:url:)` cannot: **`Store.describeActivity(id: String, metadata: [String: String?])`**, merging — `value.map { event.metadata[key] = $0 } ?? event.metadata.removeValue(forKey: key)` — because `tabsOpen`, `asked` and `messages` share that dictionary. A Swift footgun for the plan: with `[String: String?]`, assigning `dict["place"] = nil` *erases the key* rather than storing a nil; the literal `["place": nil]` does store `.some(.none)`, but anything built incrementally must use `updateValue(nil, forKey:)`.
- Its doc comment carries the invariant that makes it safe: a capture can never reach an `agentSession` row — `annotateOpen` only ever targets the open span, and only the recorder and the panel write open rows — so `upsertImportedActivity`'s wholesale `metadata` overwrite on re-import cannot destroy a captured place.
- `QuickCaptureView.recordPoint(_:at:)` — A's rescue path — must carry the place too, or a diverted note loses it. (`write(_:)`'s `plan ?? .recordPoint(…)` default is unreachable, since `load()` always sets `plan`; it needs no place and is worth a comment saying so.)
- `TimelineRow` renders the place from `metadata["place"]`, but **after** `target`, not before: if Accessibility is ever granted, a specific window title is a better label than a coarser project name and should not be hidden behind it.

### 5. Smart Capture, wired properly

Storing `cwd` is meant to feed Smart Capture's highest-priority source — the project note for `metadata["cwd"]`. Two things must be true, neither automatic:

- **The resolved place must reach the suggestion directly.** `projectNoteCandidate()` reads `metadata["cwd"]` from the open span and `leadingUp` — from *earlier* rows — while the freshly resolved place is only written on save. So it prefers `resolved.place?.root`, and falls back to row metadata **only when no place resolved** (not when a place resolved but has no `ProjectNote` — that matches the existing rule, which stops at the first `cwd` found whether or not a note exists for it). `recomputeSuggestion` is called when the place lands; today it runs only in `load()` and the tab continuation, and since it takes `tabNote:` as a parameter held in no state, that call must pass the same value the tab continuation would — hoist it into `@State` rather than passing nil.
- **Otherwise a stale `cwd` hijacks it.** Today `metadata["cwd"]` appears only on closed `agentSession` rows. A2 makes the *open* VS Code span the dominant carrier, and that span outlives the project it was written in: capture in A, work in B for an hour, capture in B, and the top-priority suggestion is A's "what am I building". Preferring the live answer removes it.

### 6. Out of scope

Terminals — A3, with its own measurement pass. The window title and anything Accessibility-dependent. Correcting a place from inside the panel (`metadata["cwd"]` keeps it repairable later). Resolving a place for the recorder's ambient rows. Editors beyond VS Code and Cursor, including JetBrains and Sublime, whose formats differ — `EditorFamily.all` is where they go, after someone checks their identifier. Multi-root workspaces (if ever filled, the answer is `workspaceIdentifier.configURIPath`'s basename, not the first root). Anything in B, C, D or E.

## Testing

`Sources/FlowTraceTests/EditorPlaceTests.swift`, registered in `main.swift`. The file read and the App-layer wait are the untestable parts, which is why parsing is a separate public function over `Data`:

- `lastActiveFolder`: a real captured `storage.json` (trimmed, paths replaced) yields the focused folder and **not** any `openedWindows` entry; `file:///Users/dev/my%20project` decodes; **`vscode-remote://ssh-remote+host/home/x/proj` yields nil** (scheme check); a window with `workspaceIdentifier` and no `folder` yields nil; missing `windowsState`, missing `lastActiveWindow`, an empty object, truncated JSON and non-JSON bytes all yield nil rather than throwing.
- `EditorFamily.matching`: both listed identifiers resolve to the right directory and display name; `com.apple.Safari` and nil resolve to nothing.
- `place(forBundleIdentifier:support:staleness:)` against a temporary directory holding a fixture `storage.json` — created **outside any git repository**, or `GitProbe` walks up and finds the FlowTrace checkout and the assertion depends on where the tests ran. Resolves the folder; refuses when the file is older than `staleness`; nil for an unknown bundle id, a missing file, and a folder that no longer exists.
- `Store.describeActivity(id:metadata:)`: merges without clobbering an existing `tabsOpen`/`asked`; **removes** `place` and `cwd` when passed nil values; leaves other rows untouched.

Not unit-testable in the Core-only harness: the wait, the snapshot and header changes, the timeline row, the Smart Capture wiring — the manual pass covers them, and step 2 is the one that would catch the wait being wrong.

## Manual verification

1. **The case that started this.** In a VS Code window on `venture/flowtrace`, press the shortcut. The header reads **`flowtrace`** with `Code · VS Code's current window` beneath. Save, then `Scripts/verify-capture.sh notes` shows `metadata` carrying `place` and `cwd`, and `target` still empty for an `.app` row.
2. **The race — the one check that matters most.** Switch to a VS Code window on a *different* project and press the shortcut **immediately**. The header must name the project you just moved to. If it names the *previous* one, the wait in §2 is too short or absent: the file only updates on blur, our own activation is what triggers it, and the read is beating the write. Press again and it will be right, which is the signature of exactly this bug.
3. In Cursor, if a project is open there → same behaviour, from Cursor's own file, and the line reads `Cursor's current window`.
4. In a terminal, over TextEdit, over WhatsApp → the header is the app name, exactly as today. No guess. (Terminals are A3.)
5. In a browser → unchanged: page title, host, link stored. Confirm no regression.
6. **Coalescing, the risk §4 exists to avoid:** recording on, capture in VS Code, wait out two recorder ticks (~60 s), then `Scripts/verify-capture.sh peek`. There must be **one** span for `Code`, not a truncated noted one followed by a fresh bare one.
7. **The stale-place case:** capture in project A, switch VS Code to project B, capture again → B's note must not be labelled `A`. Then quit VS Code and capture over something else → no place at all, not a leftover.
8. **A multi-root workspace**, if one is to hand → no place, rather than one arbitrary root.
9. Press the shortcut in a repo with a project note → Smart Capture suggests it on the *first* capture, not the second.
10. The panel must still draw instantly.
