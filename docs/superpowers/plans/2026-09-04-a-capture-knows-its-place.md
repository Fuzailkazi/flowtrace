# A Capture Knows Its Place — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A capture in VS Code or Cursor names the project you are actually in — `flowtrace`, not `Code` — by reading the editor's own record of its focused window, and stores it where it cannot damage the recorder's spans.

**Architecture:** A new pure `EditorPlace` in `FlowTraceCore` maps a bundle identifier to an editor's `globalStorage/storage.json` and extracts `windowsState.lastActiveWindow.folder`. The panel resolves it in its own detached task, waiting briefly for the write that its own activation triggers, and publishes it onto the snapshot. The place travels into `metadata` — never `target` — on all three write paths, and feeds Smart Capture's project-note source directly.

**Tech Stack:** Swift 6 tools / language mode v5, SwiftUI (macOS 14+), SwiftPM, GRDB, custom `TestKit` harness (no XCTest).

---

## Before you start

Read the spec: `docs/superpowers/specs/2026-09-04-a-capture-knows-its-place-design.md`. It went through four revisions and three reviews; two earlier designs were rejected on measurements. **Read its "The write cadence" section in Approach before writing any code** — the wait in Task 3 looks like paranoia and is the difference between this feature naming your project and naming the one you were in before.

Sub-project **A** is merged and its rules are delicate. Skim `docs/superpowers/specs/2026-09-03-capture-lands-where-you-pressed-the-key-design.md` §1–2 so you understand why the place must not touch `target` and why nothing may block `enrichmentFinished`.

Commands: `swift build`; `Scripts/test.sh` (whole suite, no filter). Baseline: **161 passed**. Inspect stored rows with `Scripts/verify-capture.sh notes`.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/FlowTraceCore/Live/EditorPlace.swift` (new) | `Place`, `EditorFamily`, and the pure read: `storageURL(for:support:)`, `lastActiveFolder(inStorageJSON:)`, `place(forBundleIdentifier:…)`. Foundation only. |
| `Sources/FlowTraceTests/EditorPlaceTests.swift` (new) | Parsing and resolution, including the `vscode-remote://` and multi-root refusals. |
| `Sources/FlowTraceTests/Fixtures/editor/storage.json` (new) | A trimmed real `storage.json`. |
| `Sources/FlowTraceCore/Activity/ActivityStore.swift` (modify) | `describeActivity(id:metadata:)` — merge, and remove on nil. |
| `Sources/FlowTraceCore/Capture/CaptureTargeting.swift` (modify) | `CaptureSite.placeName`/`placeRoot`; `PlaceBackfill`; carry it on `annotateOpen`; write metadata in "site as event". |
| `Sources/FlowTraceApp/Capture/FrontmostSnapshot.swift` (modify) | `place`, mapped into `site`; `summary`/`detail` for a resolved editor. |
| `Sources/FlowTraceApp/Capture/QuickCaptureView.swift` (modify) | The place task and its wait; ownership of `resolved`; the three back-fill paths; Smart Capture wiring. |
| `Sources/FlowTraceApp/Timeline/TimelineRow.swift` (modify) | Render the place after `target`. |
| `Sources/FlowTraceCore/Activity/ActivityRecorder.swift` (modify) | Delete the dead `wantsAccessibility`. |
| `Sources/FlowTraceTests/main.swift` (modify) | Register the new suite. |

---

## Task 1: `EditorPlace` — ask the editor

**Files:** create `Sources/FlowTraceCore/Live/EditorPlace.swift`, `Sources/FlowTraceTests/EditorPlaceTests.swift`, `Sources/FlowTraceTests/Fixtures/editor/storage.json`; modify `Sources/FlowTraceTests/main.swift`.

- [ ] **Step 1: Capture the fixture**

Copy the real file, trim it, and replace the author's paths. Keep the shape exactly — this fixture is the contract:

```bash
mkdir -p Sources/FlowTraceTests/Fixtures/editor
python3 - <<'PY'
import json, pathlib
src = pathlib.Path.home() / "Library/Application Support/Code/User/globalStorage/storage.json"
d = json.load(src.open())
ws = d.get("windowsState", {})
out = {"windowsState": {
    "lastActiveWindow": {"folder": "file:///Users/dev/acme", "backupPath": "/x", "uiState": {"mode": 1}},
    "openedWindows": [
        {"folder": "file:///Users/dev/other", "uiState": {"mode": 1}},
        {"folder": "file:///Users/dev/my%20project", "uiState": {"mode": 1}},
    ],
}}
pathlib.Path("Sources/FlowTraceTests/Fixtures/editor/storage.json").write_text(json.dumps(out, indent=2))
print("keys present in the real file:", sorted(ws.keys()))
PY
```

Report what that last line prints — if the real file has keys the fixture omits, say so; the parser must not depend on their absence.

- [ ] **Step 2: Write the failing tests**

Create `Sources/FlowTraceTests/EditorPlaceTests.swift`. `fixtures` is the global in `main.swift`; the fixture root is `fixtures.appendingPathComponent("editor")`.

```swift
import Foundation
import FlowTraceCore

func runEditorPlaceTests(fixtures: URL) {
    TestKit.suite("EditorPlace — which window is in front")

    let storage = fixtures.appendingPathComponent("editor/storage.json")

    TestKit.test("reads the focused window, not the list of open ones") {
        let data = try Data(contentsOf: storage)
        expectEqual(EditorPlace.lastActiveFolder(inStorageJSON: data), "/Users/dev/acme")
    }

    TestKit.test("a percent-encoded path is decoded") {
        let json = #"{"windowsState":{"lastActiveWindow":{"folder":"file:///Users/dev/my%20project"}}}"#
        expectEqual(
            EditorPlace.lastActiveFolder(inStorageJSON: Data(json.utf8)),
            "/Users/dev/my project"
        )
    }

    // A remote window's folder is a vscode-remote:// URI. Its path component
    // looks like a local path and is not one — the container's, not yours.
    TestKit.test("a remote window is refused, not mistaken for a local path") {
        for uri in [
            "vscode-remote://ssh-remote+box/home/dev/proj",
            "vscode-remote://dev-container%2B7b22/workspaces/proj",
        ] {
            let json = #"{"windowsState":{"lastActiveWindow":{"folder":"\#(uri)"}}}"#
            expectNil(EditorPlace.lastActiveFolder(inStorageJSON: Data(json.utf8)), uri)
        }
    }

    // A .code-workspace names several roots in an order that means nothing.
    TestKit.test("a multi-root workspace yields nothing rather than one arbitrary root") {
        let json = #"{"windowsState":{"lastActiveWindow":{"workspaceIdentifier":{"id":"a1","configURIPath":"file:///Users/dev/two.code-workspace"}}}}"#
        expectNil(EditorPlace.lastActiveFolder(inStorageJSON: Data(json.utf8)))
    }

    TestKit.test("anything malformed yields nothing rather than throwing") {
        for json in [
            #"{}"#,
            #"{"windowsState":{}}"#,
            #"{"windowsState":{"lastActiveWindow":{}}}"#,
            #"{"windowsState":{"lastActiveWindow":{"folder":""}}}"#,
            #"{"windowsState":"not an object"}"#,
            #"{"windowsState":{"lastActiveWindow":{"folder""#,
            "",
        ] {
            expectNil(EditorPlace.lastActiveFolder(inStorageJSON: Data(json.utf8)), json)
        }
        expectNil(EditorPlace.lastActiveFolder(inStorageJSON: Data([0xff, 0xfe, 0x00])))
    }

    TestKit.suite("EditorPlace — which editors")

    TestKit.test("the editors we have actually verified are recognised") {
        let code = try unwrap(EditorFamily.matching(bundleIdentifier: "com.microsoft.VSCode"))
        expectEqual(code.supportDirectory, "Code")
        expectEqual(code.displayName, "VS Code")
        let cursor = try unwrap(EditorFamily.matching(bundleIdentifier: "com.todesktop.230313mzl4w4u92"))
        expectEqual(cursor.supportDirectory, "Cursor")
        expectEqual(cursor.displayName, "Cursor")
    }

    TestKit.test("anything else is not an editor") {
        expectNil(EditorFamily.matching(bundleIdentifier: "com.apple.Safari"))
        expectNil(EditorFamily.matching(bundleIdentifier: nil))
    }

    TestKit.suite("EditorPlace — resolving a place")

    // The temp directory must sit outside any repository: GitProbe walks up,
    // and inside the checkout it would find FlowTrace and the assertions
    // would depend on where the suite was run from.
    func scratch() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flowtrace-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Lays out `<support>/Code/User/globalStorage/storage.json` pointing at
    /// a real directory, so the existence check has something to find.
    func support(folder: URL, in base: URL, modified: Date = Date()) throws -> URL {
        let support = base.appendingPathComponent("Application Support")
        let dir = support.appendingPathComponent("Code/User/globalStorage")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("storage.json")
        let json = #"{"windowsState":{"lastActiveWindow":{"folder":"file://\#(folder.path)"}}}"#
        try Data(json.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        return support
    }

    TestKit.test("a folder with no repository is still a place") {
        let base = try scratch()
        let project = base.appendingPathComponent("loose-folder")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let place = try unwrap(EditorPlace.place(
            forBundleIdentifier: "com.microsoft.VSCode",
            support: try support(folder: project, in: base)
        ))
        expectEqual(place.name, "loose-folder")
        expectEqual(place.editor, "VS Code")
    }

    // The mtime says when a window last lost focus, not how old the value is.
    // VS Code loads the previous session's state at launch and does not
    // rewrite it until the first blur, so a loose bound returns yesterday's
    // project.
    TestKit.test("a file left by an earlier session is refused") {
        let base = try scratch()
        let project = base.appendingPathComponent("stale")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let support = try support(
            folder: project, in: base, modified: Date().addingTimeInterval(-600)
        )
        expectNil(EditorPlace.place(
            forBundleIdentifier: "com.microsoft.VSCode", support: support, staleness: 120
        ))
    }

    TestKit.test("nothing to resolve is nil, not a guess") {
        let base = try scratch()
        let project = base.appendingPathComponent("here")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let support = try support(folder: project, in: base)
        expectNil(EditorPlace.place(forBundleIdentifier: "com.apple.Safari", support: support))
        expectNil(EditorPlace.place(forBundleIdentifier: nil, support: support))
        // A support tree with no file at all.
        expectNil(EditorPlace.place(
            forBundleIdentifier: "com.microsoft.VSCode",
            support: base.appendingPathComponent("empty")
        ))
    }

    TestKit.test("a folder that no longer exists is not a place") {
        let base = try scratch()
        let gone = base.appendingPathComponent("deleted-since")
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        let support = try support(folder: gone, in: base)
        try FileManager.default.removeItem(at: gone)
        expectNil(EditorPlace.place(forBundleIdentifier: "com.microsoft.VSCode", support: support))
    }
}
```

Register it in `Sources/FlowTraceTests/main.swift` beside the other fixture-taking suite:

```swift
runEditorPlaceTests(fixtures: fixtures)
```

Run: `Scripts/test.sh` → build FAILS, no `EditorPlace`.

- [ ] **Step 3: Implement**

Create `Sources/FlowTraceCore/Live/EditorPlace.swift` following the spec's §1 exactly. Notes that matter:

- `lastActiveFolder` must check `URL(string:)?.scheme == "file"` before taking `.path`. Percent-decoding comes free from `URL.path`; verify with the fixture.
- `place(…)` order: family → file mtime within `staleness` → parse → `git.topLevel(of:)` → else `FilePathCanon.canonical(folder)` → existence check → `SessionImporter.folderLabel`.
- Foundation only. No AppKit, no `Shell`, no process inspection.

- [ ] **Step 4: Tests pass**

Run: `Scripts/test.sh` → **175 passed** (161 + 14). If a count differs, report the actual number rather than adjusting a test to match.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlowTraceCore/Live/EditorPlace.swift Sources/FlowTraceTests/EditorPlaceTests.swift \
        Sources/FlowTraceTests/Fixtures/editor Sources/FlowTraceTests/main.swift
git commit -m "Ask the editor which window is in front"
```

---

## Task 2: The store can describe metadata

**Files:** modify `Sources/FlowTraceCore/Activity/ActivityStore.swift`, `Sources/FlowTraceTests/ActivityTests.swift`.

- [ ] **Step 1: Write the failing tests**

Add at the end of `runActivityTests()` (inside it, before its closing brace, so the nested `store()` helper is in scope):

```swift
    TestKit.suite("Describing what a row is")

    TestKit.test("metadata is merged, not replaced") {
        let store = try store()
        let event = try store.recordActivity(ActivityEvent(
            kind: .browserTab, startedAt: Date(), appName: "Safari",
            metadata: ["tabsOpen": "11"]
        ))
        try store.describeActivity(id: event.id, metadata: ["place": "flowtrace"])
        let after = try unwrap(try store.allActivity(on: event.startedAt, minimumSeconds: 0).first)
        expectEqual(after.metadata["tabsOpen"], "11", "existing key survived")
        expectEqual(after.metadata["place"], "flowtrace")
    }

    // A note and its place are written together or not at all — otherwise a
    // capture with no answer leaves the previous capture's project on the row.
    TestKit.test("a nil value removes the key") {
        let store = try store()
        let event = try store.recordActivity(ActivityEvent(
            kind: .app, startedAt: Date(), appName: "Code",
            metadata: ["place": "old-project", "cwd": "/tmp/old", "tabsOpen": "2"]
        ))
        try store.describeActivity(id: event.id, metadata: ["place": nil, "cwd": nil])
        let after = try unwrap(try store.allActivity(on: event.startedAt, minimumSeconds: 0).first)
        expectNil(after.metadata["place"])
        expectNil(after.metadata["cwd"])
        expectEqual(after.metadata["tabsOpen"], "2", "unrelated key survived")
    }

    TestKit.test("describing a row that is gone changes nothing") {
        let store = try store()
        try store.describeActivity(id: "not-a-row", metadata: ["place": "x"])
    }
```

Run: `Scripts/test.sh` → FAILS, no such overload.

- [ ] **Step 2: Implement**

In `ActivityStore.swift`, after the existing `describeActivity(id:target:url:)` (line 173):

```swift
    /// Fills in free detail once it becomes known — the project an editor had
    /// in front when a note was written, say.
    ///
    /// Merges rather than replaces, because `metadata` is shared: `tabsOpen`,
    /// `asked` and `messages` all live there. A nil value removes its key, so
    /// a caller with no answer can clear a stale one rather than leave it.
    ///
    /// Only the recorder and the capture panel ever write the open span, and
    /// this is only ever called on a row a note is landing on — so it cannot
    /// reach an imported `agentSession` row, whose metadata a re-import
    /// replaces wholesale.
    public func describeActivity(id: String, metadata: [String: String?]) throws {
        guard !metadata.isEmpty else { return }
        try database.writer.write { db in
            guard var event = try ActivityEvent.fetchOne(db, key: id) else { return }
            for (key, value) in metadata {
                if let value { event.metadata[key] = value }
                else { event.metadata.removeValue(forKey: key) }
            }
            try event.update(db)
        }
    }
```

- [ ] **Step 3: Tests pass, then commit**

Run: `Scripts/test.sh` → **178 passed**.

```bash
git add Sources/FlowTraceCore/Activity/ActivityStore.swift Sources/FlowTraceTests/ActivityTests.swift
git commit -m "Let a row be told what it is, without forgetting what it knew"
```

---

## Task 3: The panel asks, and waits for its own blur

**Files:** modify `Sources/FlowTraceApp/Capture/FrontmostSnapshot.swift`, `Sources/FlowTraceApp/Capture/QuickCaptureView.swift`.

App-target only, so `swift build` plus Task 6's manual pass is the verification.

- [ ] **Step 1: The snapshot carries a place**

In `FrontmostSnapshot.swift`: add `var place: Place?` beside the other stored properties. Then:

- `site` (line 52) gains `placeName: place?.name, placeRoot: place?.root` (Task 4 adds those fields; expect this not to compile until then, and do Tasks 3 and 4 in either order but build once at the end of 4).
- `summary` (line 31): after the `pageTitle`/`url` cases and before `appName`, return `place.name` if set.
- `detail` (line 37): unchanged for browsers (it returns the URL host). When `url == nil` and a place resolved, return `"\(place.editor)'s current window"`.

- [ ] **Step 2: The place task, with the wait**

In `QuickCaptureView.swift`, add to the `@State` block (lines 15-27):

```swift
    /// What the tab continuation last computed, so a later suggestion refresh
    /// can pass the same value rather than dropping it.
    @State private var tabNote: String?
```

Then in `load()` (line 316), after the existing tab-resolution `Task.detached`, add a **second, separate** task. It must be separate: the tab task flips `enrichmentFinished`, and putting this before that flip would make every non-browser capture wait on A's 1.5-second bound.

```swift
        // Only an editor is asked, and only ever about its own state file.
        guard let family = EditorFamily.matching(bundleIdentifier: snapshot.bundleIdentifier)
        else { return }

        // The file is written when a window loses focus — and activating this
        // panel is what blurs it. That write is throttled ~100ms, so reading
        // immediately returns the window we *left*, which for a switch
        // between two editor windows is the sibling project: the worst answer
        // this feature could give. So wait for our own blur to land.
        let openedAt = Date()
        Task.detached(priority: .userInitiated) {
            let url = EditorPlace.storageURL(for: family, support: EditorPlace.defaultSupport)
            let deadline = ContinuousClock.now + .milliseconds(400)
            while ContinuousClock.now < deadline {
                let written = (try? FileManager.default.attributesOfItem(atPath: url.path))
                    .flatMap { $0[.modificationDate] as? Date }
                if let written, written >= openedAt { break }
                try? await Task.sleep(for: .milliseconds(40))
            }
            let place = EditorPlace.place(forBundleIdentifier: snapshot.bundleIdentifier)
            await MainActor.run {
                resolved.place = place
                refreshPlan()
                recomputeSuggestion(tabNote: tabNote)
            }
        }
```

Add `EditorPlace.defaultSupport` as a static in Task 1's file if it is not already there, so the path is defined once.

- [ ] **Step 3: Two tasks, one `resolved` — say who owns what**

The place task mutates **only** `resolved.place`. The tab task assigns whole snapshots built from a pre-place local, so it must preserve what has landed. In the tab continuation, replace each bare assignment:

```swift
                if identified != snapshot {
                    var next = identified
                    next.place = resolved.place       // a place may already have landed
                    resolved = next
                }
```

and the same for `counted`. Today `resolvingActiveTab()` returns `self` for a non-browser so the assignment is skipped — the feature would survive by accident, and a later change to that function would silently delete it.

Also store the tab note when the tab continuation computes it, so Step 2's refresh can pass it:

```swift
                if let url = identified.url {
                    tabNote = (try? model.store.noteForTab(url: url)) ?? nil
                    recomputeSuggestion(tabNote: tabNote)
                }
```

- [ ] **Step 4: Smart Capture prefers the live answer**

`projectNoteCandidate()` (line 286) reads `metadata["cwd"]` from earlier rows, while the resolved place is only written on save — so the payoff would arrive one capture late, and a stale `cwd` on the long-lived open span would hijack the top-priority suggestion. Prefer the live answer:

```swift
    private func projectNoteCandidate() -> String? {
        // The editor's answer for right now beats a cwd left on a row by an
        // earlier capture in another project.
        let cwd = resolved.place?.root
            ?? current?.metadata["cwd"]
            ?? leadingUp.compactMap { $0.metadata["cwd"] }.first
        guard let cwd, !cwd.isEmpty else { return nil }
        return (try? model.store.projectNote(for: cwd))?.building
    }
```

- [ ] **Step 5: Build after Task 4**

Tasks 3 and 4 are one change across two targets; build once at the end of Task 4.

---

## Task 4: The place travels, and never touches `target`

**Files:** modify `Sources/FlowTraceCore/Capture/CaptureTargeting.swift`, `Sources/FlowTraceApp/Capture/QuickCaptureView.swift`, `Sources/FlowTraceApp/Timeline/TimelineRow.swift`.

- [ ] **Step 1: `CaptureSite` and `PlaceBackfill`**

In `CaptureTargeting.swift`, add to `CaptureSite` (line 7) — and to its `init`, with defaults so existing call sites and tests keep compiling:

```swift
    /// The project the editor has in front, if it said. Stored as free detail,
    /// never as `target`: `describesSameActivity` compares `target`, and the
    /// recorder cannot produce this value, so a `target` set here would be
    /// closed and replaced by the recorder's next tick.
    public var placeName: String?
    public var placeRoot: String?
```

Add the intent type:

```swift
/// What a capture knows about the place, for a row that may already carry one.
///
/// "No opinion" and "no answer" are different: a browser capture must not
/// touch the keys, while an editor capture with no answer must clear a place
/// an earlier capture left, or a note lands under the wrong project.
public enum PlaceBackfill: Sendable, Equatable {
    case unchanged
    case set(name: String, root: String)
    case clear
}
```

`case annotateOpen` (line 41) gains `place: PlaceBackfill`. In `event(for:at:closed:)` (line 115), set the metadata:

```swift
            metadata: {
                var metadata: [String: String] = [:]
                if site.openTabCount > 1 { metadata["tabsOpen"] = String(site.openTabCount) }
                if let name = site.placeName { metadata["place"] = name }
                if let root = site.placeRoot { metadata["cwd"] = root }
                return metadata
            }()
```

In `plan`, build the back-fill for the `annotateOpen` cases. `plan` needs to know whether this app is an editor at all in order to distinguish `.clear` from `.unchanged`, and `CaptureSite` is the right carrier — add one more field rather than importing `EditorFamily` into the rules:

```swift
    /// True when this app is one whose focused window FlowTrace can read. Only
    /// then does "no place" mean "clear the row's place" rather than "not my
    /// business".
    public var isEditor: Bool
```

so the back-fill is `site.placeName.map { .set(name: $0, root: site.placeRoot ?? $0) } ?? (site.isEditor ? .clear : .unchanged)`. Put that in one private helper and use it for every `annotateOpen` return.

`FrontmostSnapshot.site` sets `isEditor: EditorFamily.matching(bundleIdentifier: bundleIdentifier) != nil`.

- [ ] **Step 2: Apply it on all three write paths**

In `QuickCaptureView.write(_:)` (line 417):

- `.recordPoint(var event)` — already carries the metadata from "site as event". No change.
- `.annotateOpen(let open, let url, let title, let place)` — pass `place` through to `annotate`.
- `.beginSpan(let event)` — `beginActivity` may **discard the event** and return a pre-existing row: the coalesce (`if open.describesSameActivity(as: event) { return open }`) and the five-minute resume both do. So the place must be applied to the row it returns, not merely built into the event. Pass `.set(…)`/`.clear` derived from `resolved` the same way.

In `annotate(_:with:at:backfill:)` (line 445), apply the place **on the same path and under the same rule as the existing back-fill** — only when the note is actually landing on this row, never when it has been diverted to a rescue point:

```swift
        // Committed to writing on this row now, so it is safe to say what it is.
        if backfill.url != nil || backfill.title != nil {
            try model.store.describeActivity(
                id: target.id, target: backfill.title, url: backfill.url
            )
        }
        switch place {
        case .unchanged: break
        case .set(let name, let root):
            try model.store.describeActivity(id: target.id, metadata: ["place": name, "cwd": root])
        case .clear:
            try model.store.describeActivity(id: target.id, metadata: ["place": nil, "cwd": nil])
        }
```

`recordPoint(_:at:)` (line 484) builds its event from `resolved` and must carry the place too, or a diverted note loses it — add `metadata` to that `ActivityEvent`, mirroring "site as event".

- [ ] **Step 3: The timeline says the project**

In `TimelineRow.swift` (line 54), the row shows `event.target`. Show the place when there is no target — **after**, not before: if Accessibility is ever granted, a window title is a better label than a coarser project name and must not be hidden behind it.

```swift
            if let target = event.target, !target.isEmpty {
                …existing…
            } else if let place = event.metadata["place"], !place.isEmpty {
                …same treatment, place…
            }
```

- [ ] **Step 4: Delete the dead property**

`ActivityRecorder.wantsAccessibility` is written twice and read nowhere; Settings uses `AccessibilityPermission.isGranted` instead, which is better because it does not wait for a failed read. Remove the property and its two assignments.

- [ ] **Step 5: Build and test**

Run: `swift build` → clean. Run: `Scripts/test.sh` → **178 passed**, unchanged (Core rules changed shape but not behaviour; if a `CaptureTargetingTests` case fails, the new fields' defaults are wrong — fix the defaults, not the test).

- [ ] **Step 6: Commit**

```bash
git add Sources/FlowTraceCore/Capture/CaptureTargeting.swift Sources/FlowTraceApp/Capture/ \
        Sources/FlowTraceApp/Timeline/TimelineRow.swift Sources/FlowTraceCore/Activity/ActivityRecorder.swift
git commit -m "Carry the place onto the note, and out of target's way"
```

---

## Task 5: Manual verification

`Scripts/dev.sh` from the main checkout. **Back up first:** `Scripts/verify-capture.sh backup`.

- [ ] **1 — The case that started this.** In a VS Code window on `venture/flowtrace`, press the shortcut. Header reads **`flowtrace`**, with `Code · VS Code's current window` beneath. Save; `Scripts/verify-capture.sh notes` shows `place` and `cwd` in metadata, and `target` still empty for the `.app` row.

- [ ] **2 — The race. The check that matters most.** Switch to a VS Code window on a *different* project and press the shortcut **immediately**. The header must name the project you just moved to. If it names the **previous** one, the wait in Task 3 is too short or absent — press again and it will be right, which is the signature of exactly this bug. Report it rather than working around it.

- [ ] **3 — Cursor**, if a project is open there → same behaviour, and the line reads `Cursor's current window`.

- [ ] **4 — No guessing.** In a terminal, over TextEdit, over WhatsApp → the header is the app name, exactly as today. (Terminals are A3.)

- [ ] **5 — Browsers unchanged** → page title, host, link stored.

- [ ] **6 — Coalescing, the risk Task 4 exists to avoid.** Recording on, capture in VS Code, wait out two recorder ticks (~60s), `Scripts/verify-capture.sh peek`. **One** span for `Code` — not a truncated noted one followed by a fresh bare one.

- [ ] **7 — No stale place.** Capture in project A, switch VS Code to B, capture again → B's note must not be labelled `A`. Then quit VS Code and capture over something else → no place at all, not a leftover.

- [ ] **8 — Multi-root**, if one is to hand → no place, rather than one arbitrary root.

- [ ] **9 — Smart Capture** in a repo with a project note → suggested on the *first* capture, not the second.

- [ ] **10 — The panel still draws instantly.** The place arriving a beat later is fine; a stall is not.

- [ ] **11 — Report.** If all eleven behave, A2 is done. Anything that diverges: name the number and what happened, before changing code.
