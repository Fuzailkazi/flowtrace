# Human-First Now and Background Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the process-first Now screen with human-attention-ranked work and a collapsed background-process cleanup surface that can safely stop verified local agents and development servers.

**Architecture:** Add pure Core models for attention ranking and process-stop eligibility, extend live process discovery with identity/resource data, and keep signalling in a dedicated actor. SwiftUI consumes immutable ranked/background snapshots and presents explicit per-target confirmation before invoking the actor.

**Tech Stack:** Swift 6/SwiftPM, SwiftUI/AppKit, Darwin process APIs, `lsof`, GRDB, the existing executable test harness.

---

## File map

- Create `Sources/FlowTraceCore/Live/AttentionRanker.swift`: deterministic Continue/Recently ranking.
- Create `Sources/FlowTraceCore/Live/AttentionEvidenceReader.swift`: assemble canonical dated evidence from enabled sources and accept ephemeral deliberate visits owned by `AppModel`.
- Create `Sources/FlowTraceCore/Live/NowPresentation.swift`: pure section/view-state model testable without importing SwiftUI.
- Create `Sources/FlowTraceCore/Live/ProcessInventory.swift`: background target and endpoint models.
- Create `Sources/FlowTraceCore/Live/ProcessInventoryReader.swift`: read-only discovery behind injectable proc/socket providers.
- Create `Sources/FlowTraceCore/Live/ProcessStopper.swift`: identity validation, graceful stop, verification, and force-stop eligibility.
- Create `Sources/FlowTraceApp/Now/ContinueSection.swift`: human-first cards.
- Create `Sources/FlowTraceApp/Now/RecentSection.swift`: up to six recent places, omitted when empty.
- Create `Sources/FlowTraceApp/Now/BackgroundSummary.swift`: collapsed background summary.
- Create `Sources/FlowTraceApp/Now/BackgroundReviewSheet.swift`: review, confirmation, progress, and results.
- Modify `Sources/FlowTraceCore/Live/LiveStateReader.swift`: collect inventory fields without changing existing census behavior.
- Modify `Sources/FlowTraceCore/Live/LiveProject.swift`: expose human-attention evidence without machine-first sorting semantics.
- Modify `Sources/FlowTraceApp/Now/NowView.swift`: new section order and sheet wiring.
- Modify `Sources/FlowTraceTests/NowTests.swift`: ranking and presentation-model coverage.
- Create `Sources/FlowTraceTests/ProcessStopperTests.swift`: safe-stop regression tests using controlled fixtures.
- Modify `Sources/FlowTraceTests/main.swift`: register new tests.

### Task 1: Human-attention ranking

- [ ] Write failing tests in `Sources/FlowTraceTests/NowTests.swift` for seven-day Continue eligibility, machine-only exclusion, 30-day Recently eligibility, deduplication, source-hidden exclusion, deterministic ties, and context fallback.
- [ ] Run `.build/debug/flowtrace-tests` and confirm the new tests fail because `AttentionRanker` is missing.
- [ ] Implement `AttentionEvidence`, `AttentionCandidate`, and `AttentionRanker` in `Sources/FlowTraceCore/Live/AttentionRanker.swift` as pure value types with an injectable `now`.
- [ ] Implement `AttentionEvidenceReader` to assemble canonical evidence from activity, captures/project notes, enabled human agent turns, and an ephemeral deliberate-visit map supplied by the app; background review never records a visit.
- [ ] Add `AppModel` navigation hooks used by Continue, search, memory, and Place Recall to record an in-memory deliberate visit without persistence.
- [ ] Run the test suite and confirm all ranking tests pass.
- [ ] Commit with `feat: rank Now by human attention`.

### Task 2: Replace the process-first Now hierarchy

- [ ] Add failing `NowPresentation` tests proving no machine-only project becomes the spotlight, Continue/Recently exclude duplicates, Recently caps at six/disappears empty, and a place is not duplicated as a full card.
- [ ] Implement the pure `NowPresentation` section model in Core.
- [ ] Create `ContinueSection.swift` and `RecentSection.swift`; modify `NowView.swift` to render `Continue your work`, `Recently`, then browser context. Defer the background section until Task 3 so every intermediate build compiles.
- [ ] Remove the `Active project`, `Last active project`, `Also running`, `server only`, and `left running and forgotten` UI copy.
- [ ] Add plain-language empty and context-fallback states.
- [ ] Run `.build/debug/flowtrace-tests` and `swift build -c debug --product FlowTraceApp`.
- [ ] Commit with `feat: make Now human first`.

### Task 3: Background inventory and resource totals

- [ ] Write failing tests for canonical target deduplication, multi-port ownership, endpoint tuple normalization, RSS deduplication, unsupported-process exclusion, proc-field acquisition, missing executable/cwd/PGID behavior, cwd-change invalidation, full group allowlisting, dual-stack wildcard coalescing, and distinct same-port endpoints.
- [ ] Implement `ProcessIdentity`, `ListeningEndpoint`, `BackgroundTarget`, and `BackgroundInventory` in `ProcessInventory.swift`.
- [ ] Implement `ProcessInventoryReader` with injectable proc and socket providers; collect UID, start time, PPID, PGID, executable, RSS, cwd, group membership, and sockets, marking targets read-only when mandatory identity is unavailable. `LiveStateReader` composes it without absorbing its mutation-free responsibility.
- [ ] Create `BackgroundSummary.swift` with collapsed-by-default count, ports, prior RSS, and `Review and stop…`.
- [ ] Run all tests and build the app.
- [ ] Commit with `feat: inventory background resources`.

### Task 4: Safe graceful stop

- [ ] Create controlled fixture-process tests for identity mismatch, ownership mismatch, unrelated/new PGID member, overlap deduplication, foreground/new-attention rechecks both before confirmation and before signalling, graceful exit, timeout, port-state verification, cancellation, and no shell interpolation.
- [ ] Run the new tests and confirm they fail because `ProcessStopper` is missing.
- [ ] Implement `ProcessStopper` as an actor with injected inventory, signal, clock, sleep, foreground, and attention providers; pass an immutable review baseline into confirmation and stop; use mandatory `(pid,startTime,uid)` validation, strategy-specific optional checks, verified child-before-parent signalling, and a five-second asynchronous verification window.
- [ ] Model force stop as an in-memory state machine tied to the exact post-TERM rescan; test invalidation on refresh, sheet close, app relaunch, identity/group change, and fresh validation before every `SIGKILL`.
- [ ] Return per-target and per-endpoint outcomes; do not persist pending stops.
- [ ] Use isolated helper executables/process groups and unique ephemeral ports; every test registers `defer` teardown by verified identity plus a fail-safe timeout, never by process name, and asserts no fixture survives.
- [ ] Commit with `feat: stop verified background processes`.

### Task 5: Review and stop UI

- [ ] Add Core `NowPresentation`/review-state tests for one-row-at-a-time stopping, exact confirmation data, unavailable-memory state, partial failure, changed identity, force-stop gating, collapsed state reset on fresh presentation, cancellation sending no signal, retained prior snapshot during refresh, and no pending signal after relaunch.
- [ ] Create `BackgroundReviewSheet.swift` with friendly rows, technical disclosure, individual Stop actions, confirmation, progress, results, and fresh-review recovery.
- [ ] Add force stop only from the exact post-TERM snapshot and require the stopper to revalidate immediately before `SIGKILL`.
- [ ] Wire the sheet into `NowView`, refresh the inventory after every result, and keep the prior snapshot visible during refresh.
- [ ] On sheet close or app termination, cancel the actor operation and invalidate every force-stop token; no pending operation is persisted.
- [ ] Add VoiceOver labels for target, port, memory, stop, confirmation, progress, and outcome.
- [ ] Run all tests and build the app.
- [ ] Commit with `feat: review and stop background work`.

### Task 6: End-to-end verification and packaging

- [ ] Run `.build/debug/flowtrace-tests` and confirm all tests pass.
- [ ] Run `swift build -c debug --product FlowTraceApp` with workspace-local Swift/Clang caches if required.
- [ ] Run `./Scripts/bundle.sh debug` and verify `codesign --verify --deep --strict dist/FlowTrace.app` succeeds.
- [ ] Launch the bundle, verify the new section order, confirm background details start collapsed, stop a disposable fixture server, and verify its port becomes free.
- [ ] Confirm `git status --short` contains no unrelated changes and commit any final test/packaging adjustment separately.
