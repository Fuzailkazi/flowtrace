# Capture lands where you pressed the key

Sub-project A of Tier 0 in `docs/superpowers/audits/2026-09-03-product-audit-and-launch-roadmap.md` (item 0.1). Tier 0 is executed as five sub-projects, each with its own spec and plan, in the audit's order: **A** this one; **B** nothing is read before you say so (0.2); **C** redact at the choke point (0.3, 1.9); **D** first run and the shortcut story (0.4, 0.5, 0.6); **E** the launch wrapper (0.7).

## Problem

Quick Capture's promise is that a sentence typed over a tab lands on *that* tab and can be found there next week. Today `save()` writes the note onto whatever span the recorder happens to have open, not onto where the key was pressed (`Sources/FlowTraceApp/Capture/QuickCaptureView.swift`, `load()` sets `current = openActivity()` and pre-fills `note = current?.note`; `save()` annotates `current` and only re-targets when `current.url == nil`). Three concrete failures follow, all confirmed against the code by the audit's skeptic:

1. **Recording off — the default for every new install** (`AppModel.isRecording` reads `flowtrace.recording`, false until toggled; onboarding never turns it on). The first capture falls through to `beginActivity`, which inserts a span with `endedAt = nil`. Nothing ever closes it: `endOpenActivity` has exactly one caller, `ActivityRecorder.closeSpan()`, and the recorder is not running. The next keypress, in any app, finds that stale row as `current`, pre-fills the field with the old note, shows the *new* app in the header, and on Return overwrites the old row — including flipping its kind and URL via `describeActivity` when the new place is a web page. One note works; every later one silently destroys it. The pre-filled note also makes `recomputeSuggestion` a no-op (it guards `note.isEmpty`), so Smart Capture disappears after the first note.
2. **Recording on.** A tab switch inside a browser is only noticed by the recorder's 30-second idle tick (`ActivityRecorder.checkIdle → captureFrontmost`); `didActivateApplication` does not fire for a tab change. Press the key within 30s of opening a tab — the exact moment "why did I open this?" happens — and `current.url` is the *previous* tab's URL, so the `current.url == nil` guard does nothing and the note lands on the previous page while the header shows the new one.
3. **A failed save loses the sentence.** The `catch` sets `model.toast` and calls `onFinish()`, which dismisses the panel. The toast only renders inside `MainWindow`, which the README recommends keeping closed. The user sees the panel vanish with no "Written down." and their text is gone.

Two smaller lifecycle gaps make (1) worse and can misfile notes even with recording on: `AppLifecycle.applicationWillTerminate` only logs (its doc comment claims it closes the span), so quitting leaves the span open and tomorrow's first note can file under yesterday; and nothing at launch closes a span left open by a crash or a previous build, so a stale span can sit open for days.

## Approach

Make the *snapshot* — `FrontmostSnapshot`, captured before the panel activates, enriched with the tab a moment later — the source of truth for where a note goes. Keep the decision pure and in `FlowTraceCore` so it is unit-tested the way `CaptureSuggester` is; keep the view thin. Fix the span lifecycle in the recorder, which owns spans. Keep a failed save on screen.

Three alternatives were considered and rejected:
- *Always `beginActivity(fromSnapshot)`.* Simple, but when the tab has not resolved yet (`resolved.url == nil` for a browser) the snapshot is just "Brave Browser", `describesSameActivity` fails on kind/target/url, and we would close the recorder's correct tab span and open a worse one. The rule below handles exactly this case.
- *Trust the recorder, but force a `captureFrontmost()` before saving.* Fixes the 30s lag only while recording, still leaves recording-off users with immortal spans, and makes the panel depend on recorder timing.
- *A separate `note` table keyed on URL.* Clean in theory, but the timeline, `noteForTab`, pruning rules and tests are all built on noted `ActivityEvent`s; changing storage is a Tier 2 conversation.

## Design

### 1. `CaptureTargeting` (new, `Sources/FlowTraceCore/Capture/CaptureTargeting.swift`)

A stateless enum with one static entry point, following `CaptureSuggester`, `Redaction`, `FilePathCanon`.

```swift
/// Where the key was pressed, as the panel knows it. App-target-free so the
/// rule can be tested without AppKit.
public struct CaptureSite: Sendable, Equatable {
    public var appName: String
    public var bundleIdentifier: String?
    public var pageTitle: String?
    public var url: String?
    public var openTabCount: Int
    /// True when the app is a browser FlowTrace knows how to read — so a nil
    /// `url` means "couldn't read the tab (yet)", not "not a web page".
    public var isBrowser: Bool
}

public enum CapturePlan: Sendable, Equatable {
    /// Write onto the span the recorder already has open. `backfillURL` is set
    /// when the span knows the app but not the page and the snapshot does.
    case annotateOpen(ActivityEvent, backfillURL: String?, backfillTitle: String?)
    /// Close whatever is open and begin a span for the site (via `beginActivity`,
    /// whose coalescing still applies).
    case beginSpan(ActivityEvent)
    /// Recording is off: record a closed, zero-length event — a point, not a span.
    case recordPoint(ActivityEvent)
}

public enum CaptureTargeting {
    public static func plan(
        open: ActivityEvent?, site: CaptureSite, recording: Bool, now: Date
    ) -> CapturePlan

    /// The note to pre-fill, if any: only the open span's note, and only when
    /// the plan is to annotate that span. Never an unrelated row's words.
    public static func prefill(for plan: CapturePlan) -> String?
}
```

Rules, in order:

| recording | open span | site | plan |
|---|---|---|---|
| off | anything | — | `recordPoint(site as event, startedAt = endedAt = now)` |
| on | nil | — | `beginSpan(site as event)` |
| on | same `bundleIdentifier`, same `url` (both non-nil) | — | `annotateOpen(open)` |
| on | same `bundleIdentifier`, `open.url == nil` | `site.url != nil` | `annotateOpen(open, backfillURL: site.url, backfillTitle: site.pageTitle)` — today's back-fill, kept |
| on | same `bundleIdentifier` | `site.isBrowser && site.url == nil` | `annotateOpen(open)` — the tab could not be read; the recorder's span is the best knowledge of the page |
| on | same `bundleIdentifier`, `open.url != nil`, `site.url != nil`, different | — | `beginSpan(site)` — you changed tabs less than 30s ago |
| on | different `bundleIdentifier` | — | `beginSpan(site)` |

"site as event": `kind = site.url != nil ? .browserTab : .app`, `appName`, `bundleIdentifier`, `target = pageTitle`, `url`, `metadata = ["tabsOpen": n]` when `openTabCount > 1` — exactly what `save()` builds today.

`beginSpan` goes through `Store.beginActivity`, so if the recorder's open span is a *different* activity it is closed at `now` and the new span opened — the same thing the recorder itself would do at its next tick, done earlier with better information. The recorder's next `captureFrontmost` then coalesces into the new span because it describes the same activity.

`recordPoint` goes through `Store.recordActivity` with the note already set (`note`, `noteAt`), so recording-off captures are a single insert and can never leave a span open. A zero-duration event with a note survives `allActivity`'s minimum-seconds filter because it is not unexplained.

### 2. The view (`QuickCaptureView.swift`)

- `load()`: keep `current = openActivity()`, but pre-fill `note` from `CaptureTargeting.prefill(for: plan)` where `plan` is computed from `current`, the *current* `resolved`, and `model.isRecording` — not from `current?.note`. In the recording-off case this is always nil, so the field is empty and the Smart Capture row shows. Recompute the pre-fill once in the tab-enrichment continuation, alongside the existing `recomputeSuggestion`, and only if the field is still empty.
- `save()`: re-fetch `open = try model.store.openActivity()` at save time (the load-time value can be seconds stale), compute `plan`, then:
  - `.annotateOpen(open, backfillURL, backfillTitle)` → `describeActivity` when a back-fill is present, then `annotate(activityId: open.id, note:)`.
  - `.beginSpan(event)` → `let target = try beginActivity(event)`, then `annotate(activityId: target.id, note:)`.
  - `.recordPoint(event)` → `var e = event; e.note = text; e.noteAt = Date(); try recordActivity(e)`.
- Failure: new `@State private var saveError: String?`. On `catch`, set it to a fixed human sentence ("Couldn't write that down. Your words are still here — press Return to try again.") and log `error` via `Diagnostics.log`. Do **not** call `onFinish()`. Render it under the field in `Journal.amber` in the same style as `automationNotice`. Clear it when the text changes. Success path unchanged ("Written down.", dismiss after 600ms).
- `FrontmostSnapshot` gains `var site: CaptureSite` (a one-line mapping; `isBrowser` is already defined there).

### 3. Span lifecycle (`ActivityRecorder.swift`, `ActivityStore.swift`, `AppModel.swift`)

- **Quit closes the span.** `ActivityRecorder.start()` observes `NSApplication.willTerminateNotification` and calls `closeSpan()`. The recorder owns spans; `AppLifecycle` keeps only its logging and its comment is corrected to say so.
- **Heartbeat.** Every `captureFrontmost()` and every idle tick writes `Date()` to `UserDefaults` key `flowtrace.recorder.lastSeenAt`. Cheap, and it is the only way to know when the machine actually stopped after a crash or a force-quit.
- **Stale spans are closed at launch**, whether or not recording is on. New `Store.closeStaleOpenActivity(lastSeenAt: Date?, now: Date = Date())`: for every event with `endedAt == nil`, set `endedAt = max(startedAt, min(now, (lastSeenAt ?? startedAt) + 60))`. With no heartbeat (first run after upgrade) a stale span becomes one minute long rather than a lie stretching to now. Called once from `AppModel` at launch, next to `pruneAmbientActivity`, before `startRecordingIfEnabled()`. This also repairs the immortal rows the old bug left in existing databases.

### 4. Out of scope (later tiers)

- Showing an existing note for the page as "You wrote · date" instead of pre-filling (Tier 1.1).
- URL normalisation for `noteForTab` (Tier 1.2).
- Moving the recorder's AppleScript and DB write off the main actor (Tier 1.8).
- Any change to the 30-second tick itself.

## Testing

`Sources/FlowTraceTests/CaptureTargetingTests.swift`, registered in `main.swift`, one `TestKit.test` per rule row above plus:
- `prefill` returns the open span's note for `.annotateOpen` and nil for `.beginSpan`/`.recordPoint`.
- `recordPoint` event has `endedAt == startedAt == now`.

`ActivityTests.swift` additions (real store, temp database, as the existing tests do):
- Two `recordActivity` noted points from different apps with no recorder → `activity(on:)` lists two noted rows, `openActivity()` is nil.
- `closeStaleOpenActivity`: an open span started at 09:00 with `lastSeenAt` 17:30 is closed at 17:31; with `lastSeenAt` nil it is closed at 09:01; an already-closed span is untouched.
- `beginActivity` from a browser-tab event when a different tab is open closes the old span at the new event's start.

The view's own branching is thin enough to verify by hand.

## Manual verification

With `Scripts/dev.sh`, on a fresh database (`FLOWTRACE_DB` scratch or after Delete all data) *and* on the author's real one:
1. Recording **off**. Capture in Safari, then capture in Terminal. Today shows two noted rows, neither pre-filled the other, Smart Capture row visible on the second. `openActivity()` (via `flowtrace` or the raw view) is nil.
2. Recording **on**. Open a new tab and press the key within 10 seconds. The note lands on the new tab (Today row shows its title; `noteForTab` for its URL returns it), not the previous one.
3. Recording **on**, Automation denied for the browser. Capture over a tab: the note lands on the recorder's open span for that browser (not a new bare span); the panel still shows the Allow… notice.
4. Quit FlowTrace with a span open, relaunch: the span is closed at quit time, and a capture the next morning is a fresh row dated today.
5. Simulate a failure (e.g. make the database read-only): the panel stays open, the sentence is still in the field, the amber line explains, Return retries after restoring.
