# Nothing is read before you say so

Sub-project B of Tier 0 in `docs/superpowers/audits/2026-09-03-product-audit-and-launch-roadmap.md` (item 0.2). Companion to **C — redact at the choke point** (0.3, 1.9); the two are independent and can be built in either order.

## Problem

FlowTrace's consent screen says "Nothing is scanned until you turn it on here" (`Sources/FlowTraceApp/Onboarding/OnboardingView.swift`, consent step) and the README says "Nothing is recorded until you switch it on". In code, three things read before consent is given, all while the onboarding sheet is still on screen:

1. **Transcripts are imported unconditionally.** `RootView.task` calls `model.startRecordingIfEnabled()` (`FlowTraceApp.swift`), which calls `importSessions()` regardless of `consent`. `SessionImporter` (`Sources/FlowTraceCore/Activity/SessionImporter.swift`) constructs both adapters itself and gates only on `isAvailable` (the directory exists), not on consent. Only `AppModel.scan()` honours `consent.claudeCode`/`consent.codex`.
2. **Now tails every agent's transcript every 8 seconds.** `NowView` is the default route beneath the sheet. Its `.task` and 8s tick call `LiveStateReader().read()`, which for each running agent finds the newest transcript and reads up to 4 MB of its tail to extract the last prompt (`LiveStateReader.readAgents`, `lastPrompt(in:)`). Consent is not consulted.
3. **Browsers are asked for their tabs during the Welcome screen.** `NowView.task` also calls `refreshBrowsers()` → `LiveStateReader.readBrowsers()`, which runs `tabsInFrontWindow(of:)` against *every running browser*. For a browser FlowTrace has never asked, that AppleScript call is what makes macOS show "FlowTrace wants to control Safari" — one dialog per browser, behind a modal sheet, where dismissing is a permanent deny (`BrowserAccess.Status.denied`: "macOS won't ask again"). There is no non-prompting permission check anywhere: `BrowserTabReader` learns of a refusal only from AppleScript error −1743 after the attempt.

Two copy lines are false as a result: `SettingsView.swift` ("Nothing is captured automatically. Every thread and every capture is something you confirmed.", directly under a "Recorded automatically" holdings row) and the Automation usage string in `Scripts/bundle.sh` ("only when you ask it to capture them" — the recorder also reads the tab on every app switch and 30s tick).

## Approach

Thread consent through the two readers as a value, gate everything on `hasCompletedOnboarding`, and make Automation prompts happen only when the user clicks Connect. Keep process discovery (pgrep/lsof) ungated — it needs no permission, reads no content, and is what makes the Now view's first screen useful; only *transcript content* and *browser tabs* are behind consent.

Rejected: a global "consent granted" flag checked deep inside the readers (hides the dependency; the CLI has no such flag and must keep working), and disabling the Now view until onboarding finishes (the sheet already covers it; the bug is the reads, not the view).

## Design

### 1. `AgentSources` (new, `Sources/FlowTraceCore/Agents/AgentSources.swift`)

```swift
/// Which agents' transcripts FlowTrace may read. Process discovery is never
/// gated — it reads no content — but everything that opens a transcript is.
public struct AgentSources: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let claudeCode = AgentSources(rawValue: 1 << 0)
    public static let codex      = AgentSources(rawValue: 1 << 1)
    public static let all: AgentSources = [.claudeCode, .codex]
    public static let none: AgentSources = []
    public func contains(_ agent: AgentName) -> Bool
}
```

### 2. `SessionImporter` takes its sources

`init(sources: AgentSources = .all, git: GitProbe = GitProbe())`. Adapters are constructed only for enabled sources; `importSessions(on:into:cache:)` with `.none` returns 0 without touching the filesystem. The default stays `.all` so the CLI — where running `flowtrace now` *is* the consent — is unchanged. The app never uses the default.

### 3. `LiveStateReader` reads transcripts only for consented agents

`read(transcripts: AgentSources = .all)` and `readAgents(transcripts:)`. Discovery (`runningProcesses`, `workingDirectories`, git top-level) runs as today. For an agent whose source is not in `transcripts`, `newestTranscript`/`lastPrompt` are skipped and the `LiveAgent` gets `transcriptHidden = true`, `lastActivityAt = nil`, `lastPrompt = nil`, `sessionId = nil`, `state = .idle`.

`LiveProject` (the grouping Now renders) gains `hasHiddenTranscripts: Bool` (any agent hidden). A hidden agent is neither working nor forgotten: it is excluded from `isForgotten` and from the header's forgotten count, so consent-off users are not told they have forgotten agents FlowTrace has not looked at.

### 4. `AppModel`: one effective-sources value, and nothing starts before onboarding

```swift
/// What FlowTrace may read right now: nothing until onboarding is finished,
/// then exactly the sources switched on.
var readableSources: AgentSources {
    guard consent.hasCompletedOnboarding else { return .none }
    var s = AgentSources.none
    if consent.claudeCode { s.insert(.claudeCode) }
    if consent.codex { s.insert(.codex) }
    return s
}
```

- `importSessions()` uses `SessionImporter(sources: readableSources)`.
- `startRecordingIfEnabled()` returns immediately when `!consent.hasCompletedOnboarding`. `OnboardingView.finish()` sets the flag, saves, and then calls `model.startRecordingIfEnabled()` so recording/import begin the moment consent is complete rather than on next launch.
- `scan()` is unchanged: it already filters adapters by consent, and its one pre-finish caller is the onboarding "scanning" step, which the user reaches by switching sources on — that is the ask.

### 5. Browsers: a non-prompting status check, and prompts only from Connect

- **`BrowserAccess.status(for browser: SupportedBrowser) -> Status`** (new) uses `AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)` against the browser's bundle identifier: `noErr` → `.connected`; `errAEEventWouldRequireUserConsent` (−1744) → `.notAsked`; `errAEEventNotPermitted` (−1743) → `.denied`; `procNotFound` (−600) → `.notRunning`. `survey()` uses it instead of `probe`, which makes its existing doc comment ("prompting for none of them") true. `connect(_:)` keeps calling `probe` — that is the one place a prompt is wanted.
- **`LiveStateReader.readBrowsers()`** reads tabs only from browsers whose status is `.connected`. Others are returned with no tabs and a new `LiveBrowser.access: BrowserAccess.Status` so `OpenTabsSection` can render "Connect" (`.notAsked`, calls `BrowserAccess.connect`) or "Allow in System Settings…" (`.denied`, opens the Automation pane) instead of nothing. The existing `needsPermission` becomes `access == .denied`.
- **`ActivityRecorder.captureFrontmost`** checks `status(for:)` before layer 3: `.notAsked` → skip the tab read and add the browser to `browsersNeedingPermission` (so Settings offers Connect); `.connected` → read as today; `.denied` → as today. The recorder never triggers a prompt.
- **`FrontmostSnapshot.resolvingBrowserTab()`** does the same: `.notAsked` sets a new `automationNotAsked = true`, and `QuickCaptureView.automationNotice` shows "FlowTrace hasn't been allowed to read \(app)'s tabs yet" with a **Connect** button (calls `connect`, then re-resolves) instead of the Allow… link. A system dialog must never appear unbidden while the panel is open.
- **`NowView`**: `refresh()` passes `model.readableSources`; `refresh()` and `refreshBrowsers()` both return early while `!model.consent.hasCompletedOnboarding`.

### 6. Copy made true

- `SettingsView.swift`, privacy card: delete "Nothing is captured automatically. Every thread and every capture is something you confirmed."
- `Scripts/bundle.sh` `NSAppleEventsUsageDescription`: "FlowTrace reads the title and address of the tab in front, so a note lands on the page you were on. It never reads page contents, cookies or form data."
- `README.md`, "Nothing is recorded until you switch it on" paragraph: add "and no agent transcript is opened until you have chosen which agents FlowTrace may read."
- `OnboardingView` consent copy ("Nothing is scanned until you turn it on here") stays — it becomes true.

### 7. Out of scope

Redaction of what *is* read (C). The onboarding rewrite, Connect buttons on the last onboarding step, and recording/launch-at-login toggles (D). The README literal-truth pass beyond the one sentence above (E).

## Testing

`Sources/FlowTraceTests/` (Core-only harness; the existing adapter fixtures under `Fixtures/claude` and `Fixtures/codex` are reused):
- `SessionImporter(sources: .none).importSessions(on:into:)` against a store and the fixture roots → returns 0 and the store has no `agentSession` rows.
- `SessionImporter(sources: .claudeCode)` → imports the Claude fixture session and none from Codex; `.codex` → the reverse.
- `AgentSources.contains(.claudeCode)` / `.codex` for each combination (cheap, and the readers depend on it).
- `LiveAgent`/`LiveProject`: a project whose only agent has `transcriptHidden` is not `isForgotten` and contributes 0 to the forgotten count (pure model test, no processes).

Not unit-testable here (AppKit, live processes): `BrowserAccess.status(for:)`, the recorder and panel paths — covered by the manual pass.

## Manual verification

Reset defaults (`defaults delete ai.flowtrace.FlowTrace`) and launch `Scripts/dev.sh` with two browsers running, one never granted:
1. Welcome sheet is up: **no** Automation dialog appears; `debug.log` shows no transcript reads; Activity Monitor shows no `pgrep`/`lsof` storms beyond the 8s process list (process discovery is allowed).
2. Behind the sheet (or after cancelling out of the flow in a dev build), Now lists running agents by place with "not reading transcripts" and no prompts, and the header's forgotten count is 0.
3. Switch Claude Code on in the consent step and finish: Now fills in last prompts within one tick; Codex agents (if any) stay hidden until switched on in Settings.
4. Open tabs section: the never-granted browser shows a **Connect** button; clicking it produces the one macOS dialog; allow → tabs appear on the next 30s tick. A browser refused earlier shows "Allow in System Settings…".
5. Recording on, switch to the never-granted browser: no dialog; Settings shows it under browsers needing permission. Press the capture key over it: the panel shows the Connect notice, no dialog appears on its own.
