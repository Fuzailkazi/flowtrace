# Capture lands where you pressed the key

Sub-project A of Tier 0 in `docs/superpowers/audits/2026-09-03-product-audit-and-launch-roadmap.md` (item 0.1). Tier 0 is executed as five sub-projects, each with its own spec and plan, in the audit's order: **A** this one; **B** nothing is read before you say so (0.2); **C** redact at the choke point (0.3, 1.9); **D** first run and the shortcut story (0.4, 0.5, 0.6); **E** the launch wrapper (0.7).

## Problem

Quick Capture's promise is that a sentence typed over a tab lands on *that* tab and can be found there next week. Today `save()` writes the note onto whatever span the recorder happens to have open, not onto where the key was pressed (`Sources/FlowTraceApp/Capture/QuickCaptureView.swift`: `load()` sets `current = openActivity()` and pre-fills `note = current?.note`; `save()` annotates `current` and only re-targets when `current.url == nil`). Three concrete failures follow, all confirmed against the code by the audit's skeptic and again by this spec's reviewer:

1. **Recording off — the default for every new install** (`AppModel.isRecording` reads `flowtrace.recording`, false until toggled in Settings; onboarding never turns it on). The first capture falls through to `beginActivity`, which inserts a span with `endedAt = nil`. Nothing ever closes it: `endOpenActivity` has exactly one caller, `ActivityRecorder.closeSpan()`, and the recorder is not running. The next keypress, in any app, finds that stale row as `current`, pre-fills the field with the old note, shows the *new* app in the header, and on Return overwrites the old row — and, when the stale row is an app and the new place is a web page, `describeActivity` also flips its kind and URL. One note works; every later one silently destroys it. The pre-filled note also makes `recomputeSuggestion` a no-op (it guards `note.isEmpty`), so Smart Capture disappears after the first note.
2. **Recording on.** A tab switch inside a browser is only noticed by the recorder's 30-second idle tick (`ActivityRecorder.checkIdle → captureFrontmost`); `didActivateApplication` does not fire for a tab change. Press the key within 30s of opening a tab — the exact moment "why did I open this?" happens — and `current.url` is the *previous* tab's URL, so the `current.url == nil` guard does nothing and the note lands on the previous page while the header shows the new one.
3. **A failed save loses the sentence.** The `catch` sets `model.toast` and calls `onFinish()`, which dismisses the panel. The toast only renders inside `MainWindow`, which the README recommends keeping closed. The user sees the panel vanish with no "Written down." and their text is gone.

Two lifecycle gaps make (1) worse and can misfile notes even with recording on. `AppLifecycle.applicationWillTerminate` only logs (its doc comment claims it closes the span), so quitting leaves the span open. And nothing at launch handles a span left open by a crash or a previous build: with recording off it sits open for days; with recording on, `recorder.start()` → `captureFrontmost()` → `beginActivity` either closes it at launch time (a span "stretching to now") or, if the frontmost app describes the same activity, *resumes* it — a 17-hour span.

## Approach

Make the *snapshot* — `FrontmostSnapshot`, captured before the panel activates, enriched with the tab a moment later — the source of truth for where a note goes. Keep the decision pure and in `FlowTraceCore` so it is unit-tested the way `CaptureSuggester` is; keep the view thin. Fix the span lifecycle in the recorder, which owns spans. Keep a failed save on screen. Never overwrite words the user has not seen.

Alternatives considered and rejected:
- *Always `beginActivity(fromSnapshot)`.* When the tab has not resolved yet (`url == nil` for a browser) or the app is not a browser at all (the snapshot carries no window title — `FrontmostSnapshot.capture()` records only `appName`/`bundleIdentifier`), the snapshot event fails `describesSameActivity` against the recorder's span on `target`/`url`, so we would close the recorder's correct span, open a worse one, and the recorder's next tick would open a third. The rules below handle exactly these cases by trusting the open span whenever the snapshot cannot say more than "same app".
- *Trust the recorder, but force a `captureFrontmost()` before saving.* Fixes the 30s lag only while recording, still leaves recording-off users with immortal spans, and ties the panel to recorder timing.
- *A separate `note` table keyed on URL.* The timeline, `noteForTab`, pruning rules and tests are all built on noted `ActivityEvent`s; changing storage is a Tier 2 conversation.

## Design

### 1. `CaptureTargeting` (new, `Sources/FlowTraceCore/Capture/CaptureTargeting.swift`)

A stateless enum with static entry points, following `CaptureSuggester`, `Redaction`, `FilePathCanon`.

```swift
/// Where the key was pressed, as the panel knows it. AppKit-free so the rules
/// can be tested without the app target.
public struct CaptureSite: Sendable, Equatable {
    public var appName: String
    public var bundleIdentifier: String?
    public var pageTitle: String?
    public var url: String?
    public var openTabCount: Int
    /// A browser FlowTrace knows how to read. With `url == nil` this means the
    /// tab has not been read *yet* (or could not be) — not "not a web page".
    public var isBrowser: Bool
    /// The read was refused by macOS, so `url` will never arrive.
    public var automationDenied: Bool
}

public enum CapturePlan: Sendable {
    /// Write onto the span the recorder already has open. Back-fill fields are
    /// set when the span knows the app but not the page and the snapshot does.
    case annotateOpen(ActivityEvent, backfillURL: String?, backfillTitle: String?)
    /// Close whatever is open and begin a span for the site via
    /// `Store.beginActivity` (whose coalescing and 5-minute resume still apply).
    case beginSpan(ActivityEvent)
    /// Recording is off: one closed, zero-length event — a point, not a span.
    case recordPoint(ActivityEvent)
}

public enum CaptureTargeting {
    public static func plan(
        open: ActivityEvent?, site: CaptureSite, recording: Bool, now: Date
    ) -> CapturePlan

    /// The note to pre-fill the field with, if any. Only the open span's own
    /// note, only when the plan is to annotate that span, and never from a
    /// browser whose tab has not been read yet — at that moment the open span
    /// may be the previous tab, and its words would be the wrong words.
    public static func prefill(open: ActivityEvent?, site: CaptureSite, recording: Bool) -> String?
}
```

`CapturePlan` is deliberately not `Equatable`: "site as event" carries a fresh `UUID`, so tests pattern-match on the case and compare fields.

**`plan` rules, first match wins.** "Same app" means both `bundleIdentifier`s are non-nil and equal; a nil on either side is a different app.

| recording | open span | site | plan |
|---|---|---|---|
| off | anything | — | `recordPoint(site as event, startedAt = endedAt = now)` |
| on | nil | — | `beginSpan(site as event)` |
| on | different app | — | `beginSpan(site as event)` |
| on | same app, `open.url == nil` | `site.url != nil` | `annotateOpen(open, backfillURL: site.url, backfillTitle: site.pageTitle)` — today's back-fill, kept |
| on | same app | `site.url == nil` | `annotateOpen(open)` — the snapshot cannot say more than "same app" (a terminal or editor, or a browser whose tab was not read); the recorder's span is the best knowledge of the place |
| on | same app, `open.url == site.url` (both non-nil) | — | `annotateOpen(open)` |
| on | same app, both URLs non-nil and different | — | `beginSpan(site as event)` — you changed tabs less than 30s ago |

"site as event": `kind = site.url != nil ? .browserTab : .app`, `appName`, `bundleIdentifier`, `target = pageTitle`, `url`, `metadata = ["tabsOpen": n]` when `openTabCount > 1` — what `save()` builds today.

**`prefill` rule.** Returns nil when `site.isBrowser && site.url == nil && !site.automationDenied` (the tab is still being read). Otherwise returns `open.note` iff `plan(open:site:recording:now:)` is `.annotateOpen`, else nil.

`beginSpan` goes through `Store.beginActivity`: if the recorder's open span is a different activity it is closed at `now` and the new span opened — what the recorder itself would do at its next tick, done earlier with better information. The recorder's next `captureFrontmost` coalesces into the new span: both sides take `appName` from `frontmostApplication.localizedName` and `pageTitle` from `BrowserTabReader`, so they describe the same activity.

`recordPoint` goes through `Store.recordActivity` with `note`/`noteAt` already set, so recording-off captures are a single insert and can never leave a span open. A zero-duration noted event survives `allActivity`'s minimum-seconds filter because it is not unexplained, and renders as "under a minute".

### 2. The view (`QuickCaptureView.swift`)

- `FrontmostSnapshot` gains `var site: CaptureSite` — a one-line mapping (`isBrowser` and `automationDenied` already exist on it).
- New state: `@State private var plan: CapturePlan?`. `recording` is `model.recorder.isRunning` — the fact about whether spans get closed.
- `load()`: after `current = openActivity()`, set `plan = CaptureTargeting.plan(open: current, site: resolved.site, recording:, now:)` and `note = CaptureTargeting.prefill(open: current, site: resolved.site, recording:) ?? ""` (for a browser this is nil until the tab resolves). In the tab-enrichment continuation, after `resolved = enriched`: recompute `plan`; if `note.isEmpty`, set `note = prefill(...) ?? ""`; then the existing `recomputeSuggestion`. Order matters: a pre-fill that arrives suppresses the suggestion row, which is correct — the user already wrote about this span.
- `header`: show `current.durationLabel` only when `plan` is `.annotateOpen` (today it shows the open span's duration under whatever title `resolved` has).
- `save()`: re-fetch `open = try model.store.openActivity()` (the load-time value can be seconds stale), recompute `plan`, then:
  - `.annotateOpen(open, backfillURL, backfillTitle)` → `describeActivity` when a back-fill is present, then `annotate(activityId: open.id, note: text)`.
  - `.beginSpan(event)` → `let target = try beginActivity(event)`. **If `target.note` is non-empty and differs from `text`** — `beginActivity`'s 5-minute resume branch handed back a span you noted earlier and have not seen in this panel — do not overwrite it: record `text` as a point instead (`recordActivity` with the site as event, `startedAt = endedAt = now`, note set). Otherwise `annotate(activityId: target.id, note: text)`. Your earlier words are never destroyed by later ones.
  - `.recordPoint(event)` → `var e = event; e.note = text; e.noteAt = now; try recordActivity(e)`.
- Failure: new `@State private var saveError: String?`. On `catch`, set it to a fixed human sentence ("Couldn't write that down. Your words are still here — press Return to try again."), log `error` via `Diagnostics.log`, and do **not** call `onFinish()`. Render it under the field in `Journal.amber`, in the style of `automationNotice`. Clear it when the text changes. Success path unchanged ("Written down.", dismiss after 600ms).

### 3. Span lifecycle (`ActivityRecorder.swift`, `ActivityStore.swift`, `AppModel.swift`, `AppLifecycle.swift`)

- **Quit closes the span, running or not.** `ActivityRecorder.init` registers, once, for `NSApplication.willTerminateNotification` on `NotificationCenter.default` and calls `closeSpan()`. It is registered outside `start()`/`stop()` (which manage workspace-centre observers only) so toggling recording neither leaks nor loses it. `AppLifecycle.applicationWillTerminate` keeps its log line; its comment is corrected to say the recorder closes the span.
- **Heartbeat.** `public static let lastSeenAtKey = "flowtrace.recorder.lastSeenAt"` on `ActivityRecorder`. Every `captureFrontmost()` and every idle tick writes `Date()` to `UserDefaults.standard` under it. It is the only way to know when the machine actually stopped after a crash or a force-quit.
- **Stale spans are closed at launch, before anything can resume them.** New `Store.closeStaleOpenActivity(lastSeenAt: Date?, now: Date = Date()) -> Int` (`@discardableResult`, returns the count so launch can log it): for every event with `endedAt == nil`, `endedAt = max(startedAt, min(now, (lastSeenAt ?? startedAt) + 60))`. With no heartbeat (first run after upgrade) a stale span becomes one minute long rather than a lie. **Called synchronously as the first statement of `AppModel.startRecordingIfEnabled()`** — read the heartbeat, close, log — *before* `recorder.start()`, whose first `captureFrontmost()` would otherwise close the span at `now` or resume it. It runs whether or not recording is on, which also repairs the immortal rows the old bug left in existing databases.

### 4. Out of scope (later tiers)

- Showing an existing note for the page as "You wrote · date" instead of pre-filling (Tier 1.1).
- URL normalisation for `noteForTab` (Tier 1.2).
- Moving the recorder's AppleScript and DB write off the main actor (Tier 1.8).
- Any change to the 30-second tick itself.

## Testing

`Sources/FlowTraceTests/CaptureTargetingTests.swift`, registered in `main.swift`, one `TestKit.test` per rule row above (pattern-match the case, compare fields), plus:
- Same app, nil bundle on one side → `beginSpan`.
- `prefill`: browser site with `url == nil` and not denied → nil even when the open span has a note; same site with `automationDenied` → the open span's note; non-browser same-app site → the open span's note; recording off → nil; different app → nil.
- `recordPoint` event has `endedAt == startedAt == now` and `kind == .app` when `url == nil`, `.browserTab` otherwise.

`ActivityTests.swift` additions (real in-memory store, as the existing tests do):
- Two `recordActivity` noted points from different apps → `activity(on:)` lists two noted rows; `openActivity()` is nil.
- `closeStaleOpenActivity`: open span started 09:00, `lastSeenAt` 17:30 → closed 17:31, returns 1; `lastSeenAt` nil → closed 09:01; `lastSeenAt` earlier than `startedAt` → closed at `startedAt`; an already-closed span is untouched, returns 0.
- `beginActivity` from a browser-tab event while a different tab is open closes the old span at the new event's start.
- `beginActivity` resume: note tab A, switch to B, return to A within the merge gap → the returned span is A **with its note intact** (this is the store behaviour the `save()` rule depends on).

The view's remaining branching — three plan cases and the resume check — is verified by hand.

## Manual verification

With `Scripts/dev.sh`, on a fresh database *and* on the author's real one (back it up first):
1. Recording **off**. Capture in Safari, then capture in Terminal. Today shows two noted rows, neither pre-filled the other, Smart Capture row visible on the second. `openActivity()` is nil (raw view).
2. Recording **on**. Open a new tab and press the key within 10 seconds. The note lands on the new tab (Today row shows its title; `noteForTab` for its URL returns it), not the previous one. The field was empty when the panel opened, not pre-filled with the previous tab's words.
3. Recording **on**, in VS Code or a terminal. Capture: the note lands on the recorder's open span for that app (Today shows one row with the window title, not a bare title-less row).
4. Recording **on**, Automation denied for the browser. Capture over a tab: the note lands on the recorder's open span for that browser; the panel shows the Allow… notice.
5. Note tab A, switch to B, come back to A within a minute, capture a *different* sentence: Today shows both sentences (A's original and the new point); nothing was overwritten.
6. Quit FlowTrace with a span open, relaunch: `debug.log` records one stale span closed at the heartbeat time; a capture the next morning is a fresh row dated today.
7. Simulate a failure (e.g. make the database read-only): the panel stays open, the sentence is still in the field, the amber line explains, Return retries after restoring.
