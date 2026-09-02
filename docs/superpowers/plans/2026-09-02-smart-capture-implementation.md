# Smart Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Phase 1 ("Smart Capture") of `docs/superpowers/specs/2026-09-02-ux-unification-and-smart-capture-design.md` — when Quick Capture opens, show at most one suggested answer for "why are you here?", built only from records FlowTrace already stores, never auto-filled.

**Architecture:** A new pure, deterministic, unit-testable `CaptureSuggester` type in `FlowTraceCore` picks among three already-resolved candidate strings (project note, tab note, last agent prompt) in priority order. `QuickCaptureView` (the only caller) is responsible for gathering those three candidates from its existing `current`/`leadingUp`/`resolved` state, computing a suggestion synchronously on `load()`, recomputing it once the browser tab resolves asynchronously, and rendering a single dismissible suggestion row with Tab-to-accept and click-to-accept.

**Tech Stack:** Swift 6 / SwiftUI (macOS 14+ target), Swift Package Manager, custom `TestKit` test harness (no XCTest).

---

## Before you start

Read `docs/superpowers/specs/2026-09-02-ux-unification-and-smart-capture-design.md` in full — this plan implements only "Phase 1 — Smart Capture (fully designed)" from that spec. Phases 2–5 are out of scope.

Two commands you'll use throughout:
- Build the app target: `swift build`
- Run the whole test suite: `Scripts/test.sh` (equivalent to `swift run flowtrace-tests`; there is no way to filter to a single test — the harness runs everything in `Sources/FlowTraceTests/main.swift` and prints ✓/✗ per test)

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/FlowTraceCore/Capture/CaptureSuggester.swift` (new) | Pure priority-picking logic: `CaptureSuggestionInput` (three optional candidate strings) → `CaptureSuggestion?` (text + which source won). No I/O, no SwiftUI. |
| `Sources/FlowTraceTests/CaptureSuggesterTests.swift` (new) | Unit tests for `CaptureSuggester`: priority order, each source alone, empty/whitespace-only treated as absent, all-nil → nil. |
| `Sources/FlowTraceTests/main.swift` (modify) | Register `runCaptureSuggesterTests()`. |
| `Sources/FlowTraceApp/Capture/QuickCaptureView.swift` (modify) | Gather the three candidates from `current`/`leadingUp`/`resolved`, call `CaptureSuggester.suggest`, store the result, recompute after tab enrichment, render the suggestion row, handle Tab-to-accept and click-to-accept. |

`CaptureSuggester` lives in `FlowTraceCore` following the existing stateless-enum-with-static-entry-point convention used by `Redaction` (`Sources/FlowTraceCore/Brief/Redaction.swift`), `FilePathCanon` (`Sources/FlowTraceCore/Git/FilePathCanon.swift`), and `SearchIndex` (`Sources/FlowTraceCore/Search/SearchIndex.swift`).

---

## Task 1: `CaptureSuggester` core type

**Files:**
- Create: `Sources/FlowTraceCore/Capture/CaptureSuggester.swift`
- Create: `Sources/FlowTraceTests/CaptureSuggesterTests.swift`
- Modify: `Sources/FlowTraceTests/main.swift`

- [ ] **Step 1: Write the failing tests**

Create `Sources/FlowTraceTests/CaptureSuggesterTests.swift`:

```swift
import Foundation
import FlowTraceCore

func runCaptureSuggesterTests() {
    TestKit.suite("CaptureSuggester")

    TestKit.test("project note wins when all three sources are present") {
        let input = CaptureSuggestionInput(
            projectNote: "shipping the oauth refresh flow",
            tabNote: "reading about oauth pkce",
            lastAgentPrompt: "add refresh token rotation"
        )
        let suggestion = try unwrap(CaptureSuggester.suggest(input))
        expectEqual(suggestion.text, "shipping the oauth refresh flow")
        expectEqual(suggestion.source, .projectNote)
    }

    TestKit.test("tab note wins over the last agent prompt when there is no project note") {
        let input = CaptureSuggestionInput(
            tabNote: "reading about oauth pkce",
            lastAgentPrompt: "add refresh token rotation"
        )
        let suggestion = try unwrap(CaptureSuggester.suggest(input))
        expectEqual(suggestion.text, "reading about oauth pkce")
        expectEqual(suggestion.source, .tabNote)
    }

    TestKit.test("falls back to the last agent prompt alone") {
        let input = CaptureSuggestionInput(lastAgentPrompt: "add refresh token rotation")
        let suggestion = try unwrap(CaptureSuggester.suggest(input))
        expectEqual(suggestion.text, "add refresh token rotation")
        expectEqual(suggestion.source, .agentPrompt)
    }

    // A note that exists but is blank (or whitespace) is the same as no note —
    // the source shouldn't win just because the field happens to be non-nil.
    TestKit.test("an empty or whitespace-only source is treated as absent") {
        let input = CaptureSuggestionInput(
            projectNote: "",
            tabNote: "   ",
            lastAgentPrompt: "add refresh token rotation"
        )
        let suggestion = try unwrap(CaptureSuggester.suggest(input))
        expectEqual(suggestion.source, .agentPrompt)
    }

    TestKit.test("no suggestion when nothing is available") {
        expectNil(CaptureSuggester.suggest(CaptureSuggestionInput()))
    }
}
```

- [ ] **Step 2: Register the test and verify it fails to build**

Add `runCaptureSuggesterTests()` to `Sources/FlowTraceTests/main.swift`, alongside the other `run*Tests()` calls (e.g. right after `runBriefTests()` at line 19):

```swift
runBriefTests()
runCaptureSuggesterTests()
```

Run: `Scripts/test.sh`
Expected: build FAILS — `CaptureSuggester`, `CaptureSuggestionInput` don't exist yet.

- [ ] **Step 3: Write the implementation**

Create `Sources/FlowTraceCore/Capture/CaptureSuggester.swift`:

```swift
import Foundation

/// A single best-guess answer to "why are you here?" — never a set of
/// competing options, and never anything beyond records FlowTrace already
/// stores. `text`/`source` say what was shown and where it came from, so the
/// caller can label it honestly ("Last asked: …" for an observed prompt vs.
/// plain quotes for your own words).
public struct CaptureSuggestion: Sendable, Equatable {
    public enum Source: Sendable, Equatable { case projectNote, tabNote, agentPrompt }
    public var text: String
    public var source: Source
}

/// The three candidates `CaptureSuggester` picks among, already resolved by
/// the caller. Gathering these (scanning `leadingUp` for a `cwd`, looking up
/// a `ProjectNote`, reading a tab note) is the caller's job — this type is
/// pure priority-picking, nothing else.
public struct CaptureSuggestionInput: Sendable {
    public var projectNote: String?
    public var tabNote: String?
    public var lastAgentPrompt: String?

    public init(projectNote: String? = nil, tabNote: String? = nil, lastAgentPrompt: String? = nil) {
        self.projectNote = projectNote
        self.tabNote = tabNote
        self.lastAgentPrompt = lastAgentPrompt
    }
}

/// Picks the single best-guess answer for the Quick Capture "why are you
/// here?" field: your own project note beats your own note on the page beats
/// what you last asked an agent for. The same "silence is the correct
/// default" rule as `BriefBuilder` — when none of the three have anything to
/// say, this returns nil rather than guessing.
public enum CaptureSuggester {
    public static func suggest(_ input: CaptureSuggestionInput) -> CaptureSuggestion? {
        if let text = nonEmpty(input.projectNote) {
            return CaptureSuggestion(text: text, source: .projectNote)
        }
        if let text = nonEmpty(input.tabNote) {
            return CaptureSuggestion(text: text, source: .tabNote)
        }
        if let text = nonEmpty(input.lastAgentPrompt) {
            return CaptureSuggestion(text: text, source: .agentPrompt)
        }
        return nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
```

- [ ] **Step 4: Run tests and verify they pass**

Run: `Scripts/test.sh`
Expected: `CaptureSuggester` suite shows 5/5 passing, overall suite still green.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlowTraceCore/Capture/CaptureSuggester.swift \
        Sources/FlowTraceTests/CaptureSuggesterTests.swift \
        Sources/FlowTraceTests/main.swift
git commit -m "Add CaptureSuggester: pick one best-guess answer for why-are-you-here"
```

---

## Task 2: Compute the suggestion in `QuickCaptureView`

No UI yet — this task wires up state and the two compute passes (synchronous on load, then again once the browser tab resolves), so Task 3 only has to render `suggestion`. This is UI-adjacent code in the `FlowTraceApp` target, which `FlowTraceTests` does not depend on (it depends on `FlowTraceCore` only) — verify with `swift build`, not the test suite.

**Files:**
- Modify: `Sources/FlowTraceApp/Capture/QuickCaptureView.swift`

- [ ] **Step 1: Add suggestion state**

In the `@State` block (`QuickCaptureView.swift:15-20`), add a line after `leadingUp`:

```swift
@State private var resolved: FrontmostSnapshot
@State private var current: ActivityEvent?
@State private var leadingUp: [ActivityEvent] = []
@State private var suggestion: CaptureSuggestion?
@State private var note = ""
@State private var saved = false
@FocusState private var focused: Bool
```

- [ ] **Step 2: Add the two candidate-gathering helpers and the recompute function**

Add these as new private methods, near `load()` (after the `// MARK: - Actions` comment at `QuickCaptureView.swift:199`, before `load()`):

```swift
// MARK: - Smart capture

/// The currently-open activity's project, or — scanning newest-first — the
/// first `leadingUp` event that has one. Stops at the first `cwd` found,
/// whether or not a `ProjectNote` exists for it: this is a single best guess,
/// not a search across every project mentioned in the last 20 minutes.
private func projectNoteCandidate() -> String? {
    let cwd = current?.metadata["cwd"] ?? leadingUp.compactMap { $0.metadata["cwd"] }.first
    guard let cwd, !cwd.isEmpty else { return nil }
    return (try? model.store.projectNote(for: cwd))?.building
}

/// The most recent `leadingUp` event with something asked of an agent. Mirrors
/// the `context` view below (`QuickCaptureView.swift:176-178`): `metadata["asked"]`
/// can hold several newline-joined prompts, and only the last is shown.
private func lastAgentPromptCandidate() -> String? {
    guard let raw = leadingUp.first(where: { !($0.metadata["asked"] ?? "").isEmpty })?.metadata["asked"],
          let lastLine = raw.split(separator: "\n").last
    else { return nil }
    return AgentSession.condense(String(lastLine))
}

/// Recomputes the suggestion. A no-op once the user has typed anything (by
/// hand, or by accepting an earlier suggestion) — the row is already gone and
/// should stay gone rather than reappearing with different text.
private func recomputeSuggestion(tabNote: String?) {
    guard note.isEmpty else { return }
    suggestion = CaptureSuggester.suggest(CaptureSuggestionInput(
        projectNote: projectNoteCandidate(),
        tabNote: tabNote,
        lastAgentPrompt: lastAgentPromptCandidate()
    ))
}
```

- [ ] **Step 3: Call it from `load()`, and again once the tab resolves**

Replace `load()` (`QuickCaptureView.swift:201-213`):

```swift
private func load() {
    focused = true
    current = try? model.store.openActivity()
    leadingUp = (try? model.store.activityLeadingUp(to: Date())) ?? []
    note = current?.note ?? ""
    recomputeSuggestion(tabNote: nil)

    // Enrich with the browser tab a moment later, so the panel appears at once.
    let snapshot = self.snapshot
    Task.detached(priority: .userInitiated) {
        let enriched = snapshot.resolvingBrowserTab()
        await MainActor.run {
            if enriched != snapshot {
                resolved = enriched
                if let url = enriched.url {
                    recomputeSuggestion(tabNote: (try? model.store.noteForTab(url: url)) ?? nil)
                }
            }
        }
    }
}
```

This matches the spec's timing note: `resolved.url` is `nil` when `load()` first runs (`FrontmostSnapshot.capture()` never sets `url` — only `resolvingBrowserTab()` does), so the tab-note candidate isn't available until this second pass.

- [ ] **Step 4: Verify it builds**

Run: `swift build`
Expected: builds cleanly (the `suggestion` state is currently unused by the view body — that's fine, Task 3 consumes it next; if the compiler warns about an unused variable, ignore it until Task 3).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlowTraceApp/Capture/QuickCaptureView.swift
git commit -m "Compute a smart-capture suggestion when Quick Capture opens"
```

---

## Task 3: Render the suggestion row, with Tab-to-accept and click-to-accept

**Files:**
- Modify: `Sources/FlowTraceApp/Capture/QuickCaptureView.swift`

- [ ] **Step 1: Add `canAcceptSuggestion` and `acceptSuggestion()`**

Add next to the helpers from Task 2:

```swift
private var canAcceptSuggestion: Bool { note.isEmpty && suggestion != nil }

/// Fills the field and selects the text, so typing replaces it outright —
/// nothing is saved until Return is pressed. Reaching into the responder
/// chain is necessary because a plain SwiftUI `TextField` doesn't expose the
/// underlying `NSTextView` to select programmatically; the field already has
/// focus (this is only reachable while it's focused and empty), so its field
/// editor is the key window's first responder a moment after the text is set.
private func acceptSuggestion() {
    guard let suggestion else { return }
    note = suggestion.text
    DispatchQueue.main.async {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
    }
}

private func suggestionLabel(_ suggestion: CaptureSuggestion) -> String {
    suggestion.source == .agentPrompt
        ? "Last asked: \"\(suggestion.text)\""
        : "\"\(suggestion.text)\""
}
```

- [ ] **Step 2: Add the suggestion row view**

Add a new computed view next to `editor`:

```swift
@ViewBuilder
private var suggestionRow: some View {
    if canAcceptSuggestion, let suggestion {
        Button(action: acceptSuggestion) {
            HStack(spacing: 6) {
                Text("💭")
                Text(suggestionLabel(suggestion))
                    .font(.yourWords(12.5))
                    .foregroundStyle(Journal.inkMid)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("Tab to use")
                    .font(.observed(10.5, weight: .medium))
                    .foregroundStyle(Journal.inkSoft)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 3: Wire it into `editor`, and intercept Tab on the text field**

In `editor` (`QuickCaptureView.swift:120-150`), add `.onKeyPress(.tab)` to the `TextField` and insert `suggestionRow` right after it:

```swift
private var editor: some View {
    VStack(alignment: .leading, spacing: Journal.Space.s) {
        TextField("why are you here?", text: $note)
            .textFieldStyle(.plain)
            .font(.yourWords(17))
            .foregroundStyle(Journal.ink)
            .focused($focused)
            .onSubmit(save)
            .onKeyPress(.tab) {
                guard canAcceptSuggestion else { return .ignored }
                acceptSuggestion()
                return .handled
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Journal.paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(Journal.pen, lineWidth: 1)
            )

        suggestionRow

        HStack(spacing: Journal.Space.s) {
            Text("⏎ save").font(.observed(10.5)).foregroundStyle(Journal.inkSoft)
            Text("esc cancel").font(.observed(10.5)).foregroundStyle(Journal.inkSoft)
            Spacer()
            Text(model.captureTrigger.displayString)
                .font(.observed(10.5, weight: .medium))
                .foregroundStyle(Journal.pen)
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(Journal.penSoft, in: RoundedRectangle(cornerRadius: 4))
        }
    }
    .background {
        Button("", action: onFinish)
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0)
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds cleanly. If `.onKeyPress(.tab) { ... }` fails to compile as a zero-argument closure (SwiftUI has an overload that passes a `KeyPress` argument), change the closure to `{ _ in guard canAcceptSuggestion else { return .ignored }; acceptSuggestion(); return .handled }` and rebuild.

This only catches a *compile-time* overload mismatch. There's a separate *runtime* risk the spec itself flags (spec, "Implementation notes"): macOS can consume Tab for focus-traversal before a native `TextField` ever sees `onKeyPress` — the build would succeed but Tab-to-accept just wouldn't fire, and it would only surface in Task 4's manual verification. If that happens, the fallback is to wrap the field in an `NSViewRepresentable`-hosted `NSTextField` (or a delegate on the field's editor) that intercepts `insertTab:` inside `control(_:textView:doCommandBy:)`, calls `acceptSuggestion()`, and returns `true` to swallow the key — rather than relying on `.onKeyPress` at all.

- [ ] **Step 5: Run the full test suite**

Run: `Scripts/test.sh`
Expected: still green — this task touches no `FlowTraceCore` code, so no test outcomes should change.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlowTraceApp/Capture/QuickCaptureView.swift
git commit -m "Show a suggestion row in Quick Capture: Tab or click to accept"
```

---

## Task 4: Manual verification

This is a UI-facing capture flow with no automated UI test harness in this project — verify by hand in the running app, per the `run` skill (`Scripts/dev.sh` rebuilds, kills any running instance, and relaunches).

- [ ] **Step 1: Build and launch**

Run: `Scripts/dev.sh`

- [ ] **Step 2: Project note wins**

In a repo with a saved project note (Settings → or wherever a `ProjectNote` was previously written for that repo — check `Now` view, which already shows this note), trigger Quick Capture from an app whose frontmost activity's `metadata["cwd"]` is that repo. Confirm: a suggestion row appears matching the note's "What am I building?" text, and pressing Tab fills the field with it, selected.

If Tab visibly moves focus instead of accepting the suggestion (macOS can consume Tab for focus-traversal before `onKeyPress` sees it on a native `TextField`), that's the runtime fallback case flagged in Task 3 Step 4 — click-to-accept should still work regardless, so confirm that first, then apply the `NSViewRepresentable`/`doCommandBy:` fallback described there before re-testing Tab.

- [ ] **Step 3: Tab note wins when there's no matching project note**

Open a browser tab with a previously-saved tab note, in a context with no matching project note. Trigger Quick Capture. Confirm: the suggestion row shows the tab note text (not a project note), appearing only after the brief async tab-resolution delay.

- [ ] **Step 4: Project note beats tab note when both are available**

Repeat step 3 but this time in a context that also has a matching project note. Confirm: the row shows the *project* note, not the tab note — this is the one case that actually exercises priority order rather than just source selection.

- [ ] **Step 5: Last agent prompt as last resort**

Trigger Quick Capture somewhere with a recent agent session in `leadingUp` but no project note or tab note. Confirm: the row reads `💭 Last asked: "…"` rather than being shown as if it were your own words.

- [ ] **Step 6: Silence is correct when nothing matches**

Trigger Quick Capture somewhere with no matching source at all (a plain app, no recent agent activity, no notes). Confirm: no suggestion row appears.

- [ ] **Step 7: Typing dismisses it; editing after accepting still saves correctly**

Trigger Quick Capture where a suggestion appears. Start typing your own text instead of accepting — confirm the row disappears immediately. Reopen, accept the suggestion (Tab or click), then edit the filled text before pressing Return — confirm the edited text is what gets saved (check the `Now`/`Timeline` view afterward).

- [ ] **Step 8: Report results**

If all six scenarios behave as described, the phase is done. If anything diverges, note exactly which step and what happened before making further changes — don't guess at a fix without reproducing it first.
