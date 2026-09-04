# Nothing is read before you say so

Sub-project B of Tier 0 in `docs/superpowers/audits/2026-09-03-product-audit-and-launch-roadmap.md` (item 0.2). Companion to **C — redact at the choke point** (0.3, 1.9); the two are independent and can be built in either order.

## Problem

FlowTrace's consent screen says "Nothing is scanned until you turn it on here" (`Sources/FlowTraceApp/Onboarding/OnboardingView.swift`, consent step) and the README says "Nothing is recorded until you switch it on". In code, four things read before consent is given, the first three while the onboarding sheet is still on screen:

1. **Transcripts are imported unconditionally.** `RootView.task` calls `model.startRecordingIfEnabled()` (`FlowTraceApp.swift`), which calls `importSessions()` regardless of `consent`. `SessionImporter` (`Sources/FlowTraceCore/Activity/SessionImporter.swift`) constructs both adapters itself and gates only on `isAvailable` (the directory exists). Only `AppModel.scan()` honours `consent.claudeCode`/`consent.codex`. `TimelineView`'s 20s import tick goes through the same `importSessions()`.
2. **Now tails every agent's transcript every 8 seconds.** `NowView` is the default route beneath the sheet. Its `.task` and 8s tick call `LiveStateReader().read()`, which for each running agent finds the newest transcript and reads up to 4 MB of its tail for the last prompt (`LiveStateReader.readAgents`, `lastPrompt(in:)`). Consent is not consulted.
3. **Browsers are asked for their tabs during the Welcome screen.** `NowView.task` also calls `refreshBrowsers()` → `LiveStateReader.readBrowsers()`, which runs `tabsInFrontWindow(of:)` against *every running browser*. For a browser FlowTrace has never asked, that AppleScript call is what makes macOS show "FlowTrace wants to control Safari" — one dialog per browser, behind a modal sheet, where dismissing is a permanent deny (`BrowserAccess.Status.denied`: "macOS won't ask again"). There is no non-prompting permission check anywhere: `BrowserTabReader` learns of a refusal only from AppleScript error −1743 *after* attempting the read, and `BrowserAccess.survey()`'s `probe` does the same, so its doc comment ("prompting for none of them") is currently false and its `.notAsked` status can never be returned.
4. **Settings prompts too.** `SettingsView.task` calls `BrowserAccess.survey()`, and Settings is reachable with ⌘, while the onboarding sheet is up (the sheet is modal to the main window only).

Two copy lines are false as a result: `SettingsView.swift` ("Nothing is captured automatically. Every thread and every capture is something you confirmed.", directly under a "Recorded automatically" holdings row) and the Automation usage string in `Scripts/bundle.sh` ("only when you ask it to capture them" — the recorder also reads the tab on every app switch and 30s tick).

## Approach

Thread consent through the two readers as a value, gate transcript content and browser tabs on `hasCompletedOnboarding`, and make Automation prompts happen only when the user clicks Connect. **Process discovery stays ungated**: `pgrep`/`lsof` need no permission, read no content, and are what make the Now view's first screen useful. Only *transcript content* and *browser tabs* are behind consent.

Rejected: a global "consent granted" flag checked deep inside the readers (hides the dependency; the CLI has no such flag and must keep working), and disabling the Now view until onboarding finishes (the sheet already covers it; the bug is the reads, not the view).

## Design

### 1. `AgentSources` (new, `Sources/FlowTraceCore/Agents/AgentSources.swift`)

```swift
/// Which agents' transcripts FlowTrace may read. Process discovery is never
/// gated — it reads no content — but everything that opens a transcript is.
public struct AgentSources: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let claudeCode = AgentSources(rawValue: 1 << 0)
    public static let codex      = AgentSources(rawValue: 1 << 1)
    public static let all: AgentSources = [.claudeCode, .codex]
    public static let none: AgentSources = []
    /// False for every agent FlowTrace cannot read yet (`.cursor`, `.openCode`,
    /// `.geminiCLI`, `.other`).
    public func contains(_ agent: AgentName) -> Bool
}
```

### 2. `SessionImporter` takes its sources, keeps its adapters injectable

```swift
public init(
    sources: AgentSources = .all,
    claude: ClaudeCodeAdapter = ClaudeCodeAdapter(),
    codex: CodexAdapter = CodexAdapter(),
    git: GitProbe = GitProbe()
)
```

`sources` decides which of the two injected adapters is consulted; `.none` returns 0 from `importSessions(on:into:cache:)` without touching the filesystem. Adapter injection stays because the tests point adapters at `Fixtures/` via `root:` — `main.swift` promises tests never read the real `~/.claude`/`~/.codex`. The `.all` default keeps the CLI — where running `flowtrace now` *is* the consent — unchanged; the app never uses the default.

### 3. `LiveStateReader` reads transcripts only for consented agents

`read(transcripts: AgentSources = .all)` and `readAgents(transcripts:)`. Discovery (`runningProcesses`, `workingDirectories`, git top-level) runs as today.

`LiveAgent` gains `public var transcriptHidden: Bool = false`, **and a defaulted `transcriptHidden: Bool = false` parameter in its explicit public memberwise init** — without the default every existing construction (including the `agent()` helper in the live-project tests) stops compiling.

The per-process resolution is factored out so it can be tested without `pgrep`:

```swift
public func agent(
    for process: RunningProcess, root: String, transcripts: AgentSources
) -> LiveAgent
```

`root` is passed in rather than resolved inside, because `readAgents` memoises git top-levels across processes precisely to avoid one subprocess per agent — seventeen agents in three repositories are three `git` calls, not seventeen. The memo stays in `readAgents`; the seam receives the answer. `RunningProcess` becomes `public` and `Sendable` with a `public init(pid:command:workingDirectory:)`, since `FlowTraceTests` is a separate module and cannot see internal types.

For an agent whose source is not in `transcripts`, `newestTranscript` and `lastPrompt` are skipped entirely — including the directory listing, which would expose session ids — and the `LiveAgent` gets `transcriptHidden = true`, `lastActivityAt = nil`, `lastPrompt = nil`, `sessionId = nil`, `state = .idle`; `branch` is unchanged (never populated by the reader today). Age is therefore not shown for hidden agents: the audit expected it to survive, but age comes from the transcript's mtime, and listing transcripts is a read of the agent's files the user has not agreed to.

Forgotten-ness is judged on agents FlowTrace has actually looked at:

```swift
var isForgotten: Bool {
    let seen = agents.filter { !$0.transcriptHidden }
    return !seen.isEmpty && seen.allSatisfy { $0.state == .idle }
}
```

so an all-hidden project is never forgotten and contributes 0 to the header count, and a mixed project is judged on its visible agents.

`statusLabel` gains one branch, **first in the chain and guarded on a non-empty agent list** — hidden agents carry `state == .idle`, so without being first they would fall through to `"unknown · idle"`, and without the non-empty guard `allSatisfy` is vacuously true and a server-only project would lose its existing "server only" label:

```swift
if !agents.isEmpty, agents.allSatisfy(\.transcriptHidden) { return "not reading transcripts" }
```

Hidden agents keep the grey dot and sort to the bottom — `projects()` sorting and `NowView.colour(for:)` key on `.idle`, and that is the right visual weight for "nothing known". `NowView.projectBlock` needs no change: `LiveProject.lastPrompt` is already nil when its agents have no prompt. No `hasHiddenTranscripts` property is added — `statusLabel` asks `agents` directly, and a stored property would also break `LiveProject`'s memberwise construction in `projects(notes:)`. `LiveState.headline`/`idleAgents` have no callers and are untouched.

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

- `importSessions()` uses `SessionImporter(sources: readableSources)`, with `readableSources` hoisted onto the main actor *before* the `Task.detached` (the importer is constructed inside it today, and `AppModel` is `@MainActor`).
- `startRecordingIfEnabled()` returns immediately when `!consent.hasCompletedOnboarding`, logging `Diagnostics.log("read: held — onboarding not finished")` on the way out, and `Diagnostics.log("read: sources \(readableSources)")` when it proceeds. Once per launch, not once per tick: `importSessions` itself is called every 20 seconds while Today is open, and `debug.log` is append-only with no rotation. This one line is what makes the headline promise auditable.
- `OnboardingView.finish()` sets the flag, saves, and then calls `model.startRecordingIfEnabled()` so recording and import begin the moment consent is complete rather than on next launch. For users who already completed onboarding the flag is loaded from defaults before `RootView.task` runs, so nothing changes for them.
- `scan()` is unchanged: it already filters adapters by consent, and its one pre-finish caller is the onboarding "scanning" step, which the user reaches by switching sources on — that is the ask.

### 5. Browsers: a non-prompting status check, and prompts only from Connect

- **`BrowserAccess.status(for browser: SupportedBrowser) -> Status`** (new). Builds an `AEAddressDesc` with `AECreateDesc(DescType(typeApplicationBundleID), …)` from the browser's bundle identifier and calls `AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)`: `noErr` → `.connected`; `errAEEventWouldRequireUserConsent` (−1744) → `.notAsked`; `errAEEventNotPermitted` (−1743) → `.denied`; `procNotFound` (−600) → `.notRunning`. Verified callable from Swift with `import AppKit` alone (no bridging header; available since macOS 10.14). Implementation notes the engineer should not have to rediscover: `AECreateDesc` returns `OSErr`, and the descriptor must be `AEDisposeDesc`'d; the `askUserIfNeeded: false` argument is load-bearing — with `true` the call blocks and prompts, and −1744 is only returned when it is `false`; it is synchronous IPC, so call it off the main actor where the caller already is (Now's detached reads) and accept it on the main actor only where `NSAppleScript` already runs there (the recorder); no Apple Events entitlement is needed while `bundle.sh` signs ad-hoc without hardened runtime — if hardened runtime is ever enabled, this check and the existing `NSAppleScript` reads both need `com.apple.security.automation.apple-events`; ad-hoc signing resets Automation grants on every rebuild, so `.notAsked` reappears after each dev build.
- **`survey()`** uses `status(for:)` instead of `probe`. Its doc comment becomes true, and `.notAsked` becomes a real result — which brings `SettingsView`'s existing `.notAsked → Connect` branch to life (today dead code). That is an intended behaviour change in Settings. `connect(_:)` keeps calling `probe` — the one place a prompt is wanted.
- **`LiveStateReader.readBrowsers()`** reads tabs only from browsers whose status is `.connected`. `LiveBrowser` gains `access: BrowserAccess.Status`, its public init becomes `init(name:tabs:access:)`, and `needsPermission` becomes a computed alias for `access == .denied`. The trailing filter becomes `!tabs.isEmpty || access == .notAsked || access == .denied` so a never-asked browser reaches `OpenTabsSection`.
- **`OpenTabsSection.browserBlock` switches on `access`, not on `needsPermission`.** Both the chip and the trailing control today branch on that one Boolean, so a never-asked browser would fall into the `else` and read "0 tabs" beside a Connect button. Chip: `.denied` → the existing amber "can't read tabs"; `.notAsked` → "not connected" in the same amber treatment; otherwise the tab count. Control: `.denied` → **Allow…** (`AutomationPermission.openSettings()`, the helper this view and `QuickCaptureView` already use); `.notAsked` → **Connect** (`BrowserAccess.connect`, then refresh); otherwise the existing "n more" expander.
- **`ActivityRecorder.captureFrontmost`** checks `status(for:)` before layer 3: `.notAsked` → skip the tab read (Settings will offer Connect on its own via `survey()`); `.connected` → read as today; `.denied` → as today. The recorder never triggers a prompt. `browsersNeedingPermission` keeps its meaning (denied) — nothing in the app reads it today, and this spec does not add a reader.
- **`FrontmostSnapshot.resolvingBrowserTab()`** does the same: `.notAsked` sets a new `automationNotAsked = true`, and `QuickCaptureView.automationNotice` shows "FlowTrace hasn't been allowed to read \(app)'s tabs yet" with a **Connect** button (calls `connect`, then re-resolves) instead of Allow…. A system dialog must never appear unbidden while the panel is open.
- **`NowView`**: `refresh()` always runs — it is process discovery — and passes `model.readableSources`, read on the main actor *before* `Task.detached` (only `model.store` is captured today). `refreshBrowsers()` returns early while `!model.consent.hasCompletedOnboarding`. A new `.onChange(of: model.consent.hasCompletedOnboarding)` runs `refresh()` and `refreshBrowsers()` immediately, so finishing onboarding fills Now in without waiting for the 8s/30s ticks.
- **`CaptureSheet`** (More → Capture context…, ⇧⌘C) reads tabs of the picked browser on appear and on selection. It is user-initiated from a menu and stays a prompting path in this sub-project; D decides whether the tabs mode survives at all.

### 6. Copy made true

- `SettingsView.swift`, privacy card: delete "Nothing is captured automatically. Every thread and every capture is something you confirmed."
- `Scripts/bundle.sh` `NSAppleEventsUsageDescription`: "FlowTrace reads the title and address of the tab you are on, so a note lands on the page rather than on the browser. It never reads page contents, cookies or form data."
- `README.md`, "Nothing is recorded until you switch it on" paragraph: add "and no agent transcript is opened until you have chosen which agents FlowTrace may read."
- `OnboardingView` consent copy ("Nothing is scanned until you turn it on here") stays — it becomes true.

### 7. Out of scope

Redaction of what *is* read (C). The onboarding rewrite, including Connect buttons on the last onboarding step — with B alone, a first-run user with a never-granted browser sees no tabs until they click Connect in Now or Settings; D closes that (D). Recording and launch-at-login toggles in onboarding (D). The README literal-truth pass beyond the one sentence above (E). Retiring or gating `CaptureSheet` (D).

## Testing

New `Sources/FlowTraceTests/ConsentTests.swift` with `func runConsentTests(fixtures: URL)`, **registered in `main.swift`'s call list** (a flat list — a new suite that isn't added there silently never runs). Core-only harness; adapters pointed at `Fixtures/claude` and `Fixtures/codex` via `root:` as the adapter tests already do. The fixtures are dated 2026-07-14 (Claude 09:00Z, Codex 11:00–11:05Z), which fall on *different local days* at extreme offsets, so derive each assertion's `on:` day from that source's own fixture timestamp rather than sharing one date; and note `CodexAdapter.discoverSessions(modifiedWithin: 2)` filters on file mtime — checkout time for a fixture.
- `SessionImporter(sources: .none, claude: fixtureClaude, codex: fixtureCodex).importSessions(on:into:)` → returns 0 and the store has no `agentSession` rows.
- `sources: .claudeCode` → the Claude fixture session and none from Codex; `.codex` → the reverse (each on its own derived day).
- `AgentSources.contains(_:)` for every `AgentName` case.
- `LiveStateReader(claudeRoot: fixturesClaude).agent(for: RunningProcess(pid: 1, command: "claude", workingDirectory: "/Users/dev/acme"), root: "/Users/dev/acme", transcripts: .none)` → `transcriptHidden`, nil `lastPrompt`/`sessionId`/`lastActivityAt`. With `.claudeCode` → `transcriptHidden == false` and `lastPrompt == "now add refresh token rotation before we ship"` (the reader's tail scanner filters on `AgentSession.isSubstantive`, so it is *not* the adapter's `lastPrompt` of "do it"), plus a non-nil `sessionId`. The fixture directory `-Users-dev-acme` already has the slug shape `ClaudeCodeAdapter.projectSlug` produces for that cwd, and passing `root` explicitly keeps `GitProbe` out of the test.
- `LiveProject`: all agents hidden → `isForgotten == false`, `statusLabel == "not reading transcripts"`; one hidden + one idle visible → forgotten; one hidden + one working → not forgotten; **no agents and one server → `statusLabel == "server only"`** (the guard that stops `allSatisfy` being vacuously true).

Not unit-testable here (AppKit, live processes): `BrowserAccess.status(for:)`, the recorder and panel paths — covered by the manual pass.

## Manual verification

Reset defaults (`defaults delete ai.flowtrace.FlowTrace`) and launch `Scripts/dev.sh` with two browsers running, one never granted:
1. Welcome sheet is up: **no** Automation dialog appears. `debug.log` shows `read: held — onboarding not finished`. `sudo fs_usage -w -f filesys -p <FlowTrace pid> | grep -E '\.claude/projects|\.codex'` stays silent while the sheet is up.
2. Behind the sheet (or after cancelling out of the flow in a dev build), Now lists running agents by place with "not reading transcripts", no prompts, grey dots, and the header's forgotten count is 0.
3. Switch Claude Code on in the consent step and finish: Now fills in last prompts and tabs immediately (the `onChange`), not after a tick; Codex agents (if any) stay hidden until switched on in Settings.
4. Open tabs section: the never-granted browser shows **Connect**; clicking it produces the one macOS dialog; allow → its tabs appear on refresh. A browser refused earlier shows **Allow…**. Rebuild with `dev.sh` and note Connect comes back (ad-hoc signing).
5. Recording on, switch to the never-granted browser: no dialog. Press the capture key over it: the panel shows the Connect notice, no dialog appears on its own; click Connect → dialog → allow → the header fills with the page title.
6. Open Settings with ⌘, while the Welcome sheet is up: the browser card lists the never-granted browser as Connect, and no dialog appears.
