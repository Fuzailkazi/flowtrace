# Human-First Now and Background Cleanup Design

## Status

Approved direction from product discussion on 2026-09-17. This document defines the product and technical design; it does not authorize implementation until the written spec is reviewed.

## Problem

The current Now screen promotes the first live process group into an “Active project” card and places every other discovered process group under “Also running.” Those labels expose FlowTrace’s implementation rather than the user’s mental model.

Three facts are currently mixed together:

1. A coding-agent or server process exists.
2. A process or transcript changed recently.
3. The user personally interacted with a piece of work recently.

Only the third fact is strong evidence of what the user is working on. A Claude process can keep writing after the user has left, and a development server can remain alive for weeks. Promoting either to “Active project” makes a stale project look current. “Also running” then becomes a list of technically detectable but seemingly random folders.

The home screen must be legible to someone who does not know what a PID, coding agent, or localhost port is. Technical process information remains useful, but belongs in a secondary cleanup surface.

## Product Principles

- Lead with the user’s attention, not machine activity.
- Never call work “active” based only on a living process or changing file.
- Describe background activity calmly; do not manufacture urgency.
- Put technical details behind progressive disclosure.
- Make every cleanup action explicit, previewable, and verifiable.
- Report what FlowTrace measured, and avoid pretending an estimate is exact.

## First-Screen Information Architecture

The Now screen is ordered as follows:

### 1. Continue your work

This is the primary section. It shows at most two places with recent evidence of human attention.

A place qualifies through one or more of:

- a recent human-authored agent turn (`lastHumanActivityAt`);
- a recent foreground activity record associated with the place;
- a deliberate note or capture associated with the place;
- the user deliberately opening that place in FlowTrace.

A living PID, transcript heartbeat, filesystem change, or occupied port does not qualify by itself.

The first card uses plain language:

- project or place name;
- “Last used …” based on human attention;
- the most useful human-authored context available;
- “Continue” and “What was I doing?” actions.

If no place has credible recent-attention evidence, the section says so rather than promoting a background process.

“Recent” means within the previous seven days for the initial release. A deliberate capture or project note provides context but does not permanently make a place recent; it must be paired with dated attention inside that window. Opening a place from a search result, memory, or Continue card records a deliberate visit. Opening the background-review sheet does not. Foreground activity is associated only when an activity row already carries that canonical project path. All paths are canonicalized before deduplication.

### 2. Recently

This section contains recent places and deliberate memories that may be useful again, whether or not their processes still exist. It is a recovery surface, not a process list.

For the initial release it shows up to six unique canonical places used within the previous 30 days, excluding the paths already shown in Continue. Sources are dated foreground activity carrying a project path, deliberate captures/notes carrying a project path, and human-authored agent turns from enabled sources. Newest human-attention date wins, with canonical path as the deterministic tie-breaker. Each row shows place name, “Last used …,” the context-selection result defined below, and opens Place Recall. If nothing qualifies, the section is omitted rather than showing an empty card.

### 3. Running in the background

This replaces “Also running.” It is collapsed by default and appears only when FlowTrace has found a live supported agent or local development server.

The collapsed summary says only what a general user needs:

> 6 things running · 3 development ports · about 2.1 GB

Its action is **Review and stop…**. It does not use “needs attention,” “forgotten,” warning colors, or other language that implies a problem.

Expanded rows use approachable descriptions:

- “Coding session” rather than leading with “Claude Code · PID 1234”;
- “Local website on port 3000” rather than “server only”;
- “Last used 16 days ago” when human activity is known;
- “Activity age unknown” when it is not.

PID, executable, parent/child relationships, bound address, and exact RSS remain available in a details disclosure.

A “thing” is one canonical stop target, not one row or socket. Ports are unique `(protocol, address family, local address, port)` endpoint tuples; a dual-stack wildcard listener is presented once when macOS reports both records for the same owning target. Memory totals sum each canonical process PID once, even when it owns several ports or appears through more than one discovery route.

### 4. Open in your browser

Browser context remains on the Now screen because it can help recover work, but it does not determine which project is presented as current.

## Ranking and Classification

### Human-attention ranking

Add a pure ranking layer that is separate from `LiveProject.state` and process activity. It produces `ContinueCandidate` values using dated evidence.

Evidence is ordered by confidence:

1. explicit user capture/note or a deliberate FlowTrace visit;
2. foreground activity associated with the place;
3. human-authored agent turn;
4. no human evidence.

Eligibility first requires dated attention inside the seven-day window. Within eligible candidates, the newest attention date wins; confidence breaks ties within the same minute, followed by canonical path for deterministic ordering. A note supplies better display context but does not outrank newer attention. A deliberate visit expires like every other attention signal. Machine-only evidence never crosses into the Continue section. At most one candidate exists per canonical project path.

The evidence schema is ephemeral `AttentionEvidence(projectPath, kind, occurredAt, context)` assembled from existing dated activity, captures, project notes, agent human turns, and deliberate navigation. Existing persisted records remain the sources of truth; no new attention log or browsing history is persisted. Evidence derived from a disabled source is excluded on the next refresh.

“Most useful context” is chosen in this order from evidence belonging to the selected canonical path: latest explicit capture/note text, latest substantive human agent prompt, latest foreground title, otherwise no context line. Secret redaction rules already applied by the source remain in force.

When no context line exists, the card explains the qualifying evidence in plain language, for example “You opened this place 2 hours ago.” It never fills the space with process activity.

### Background classification

Every live server and supported agent remains discoverable in “Running in the background.” A place may appear in both Continue and the background review because those sections answer different questions: “What was I doing?” and “What is consuming resources?” The main screen must not duplicate full cards; the background summary counts it, while the review sheet owns the detailed process rows.

### Terminology

Remove these labels from the main screen:

- Active project
- Last active project
- Also running
- Server only
- left running and forgotten

Use:

- Continue your work
- Last used …
- Recently
- Running in the background
- Coding session
- Local website on port …
- Review and stop…

## Process Inventory

Extend the current live census with a process inventory designed for display and safe termination.

Each process record contains:

- PID;
- process name and executable path;
- working directory and resolved project;
- parent PID and process-group ID;
- process start time;
- resident memory (RSS);
- supported-agent identity, when applicable;
- listening sockets, including interface and port;
- the latest known human-attention date, when applicable.

On macOS the inventory uses `proc_pidinfo`/`proc_pidpath` as the authoritative source for UID, parent PID, process group, executable, start time, and RSS where available; `lsof` remains the socket-owner and cwd source. Values are normalized to canonical paths, numeric UIDs/PIDs, monotonic process identity `(pid, startTime, uid)`, and byte-count RSS. Shell text is parsed only for read-only discovery and never becomes an executable command.

Start time, UID, and PID are mandatory for a stoppable target. Missing any of them makes the item read-only. Executable, cwd, PGID, hierarchy, and RSS improve confidence/display but may be unavailable: missing executable or cwd makes an unrecognized item read-only; missing PGID disables group termination; missing RSS displays “Memory unavailable.” A cwd changing within the same verified process identity does not itself invalidate a PID-only stop, but it does prevent project-wide grouping until the inventory is refreshed.

Memory is reported as approximate because RSS can overlap through shared pages and macOS may immediately reuse released memory as cache.

The inventory reader is read-only. Termination lives in a separate controller so discovery cannot accidentally mutate the machine.

## Review and Stop Flow

Selecting **Review and stop…** opens a sheet containing grouped, selectable processes.

For each project the sheet shows:

- friendly project name;
- last-used wording;
- coding sessions;
- local development servers and occupied ports;
- approximate memory for each process and selected total;
- a technical-details disclosure.

The initial release has no bulk selection and does not preselect anything. Each row offers its own Stop action and confirmation. Unknown-age items remain reviewable but require the same explicit individual confirmation.

The final confirmation lists the exact process type, project name, PID in technical disclosure, and ports expected to close. Immediately before presenting confirmation and again immediately before signalling, FlowTrace recomputes current foreground status and latest human attention. If the item became foreground or received newer human activity since review, the action is refused with “This became active again; review it before stopping.”

Available actions are:

- **Stop server**: stop the process group responsible for the selected listening server;
- **Stop coding session**: stop the selected supported agent process;

The first release does not kill terminal applications, editors, browsers, databases, containers, or processes FlowTrace cannot confidently associate with a supported agent or local development server. Unsupported or unassociated processes are hidden from this cleanup surface rather than presented as partially actionable rows.

One canonical stop target is keyed by the verified root process identity `(pid, startTime, uid)` plus its verified descendant set. Agent and socket discovery routes that resolve to the same root collapse into one target. Overlapping selections collapse before display totals, signals, and results: each PID is counted and signalled once, while every affected visible row receives the shared outcome.

## Safe Termination Protocol

Stopping is a deliberate, multi-stage operation:

1. Re-read the target immediately before acting.
2. Match the mandatory identity `(pid, startTime, uid)` against the reviewed snapshot. Optional fields are strategy-specific: executable and cwd are compared when they were used to classify an otherwise unrecognized target; PGID and the complete member set are required and compared only for group signalling. An optional field that was present and materially changes invalidates that strategy: FlowTrace refreshes the row, falls back to a narrower already-verified PID/subtree strategy when safe, or makes the item read-only. Missing or changed optional fields never weaken the mandatory identity check.
3. Refuse the action if the identity changed or is ambiguous.
4. Enumerate the target’s current descendants and process-group members. Group signalling is allowed only when every member is owned by the current user and belongs to an eligible allowlist: the reviewed supported-agent executable, its verified descendants, or the reviewed local-server launch tree. If any member is unrelated, unknown, a terminal/editor/browser/database/container process, or cannot be identified, do not signal the group. Fall back to signalling only the verified target PID and eligible verified descendants, children before parent.
5. Revalidate every PID immediately before its signal.
6. Send `SIGTERM` once to each deduplicated verified target.
7. Wait for at most five seconds off the main actor while keeping the UI responsive and allowing cancellation of the wait (cancellation does not undo signals already sent).
8. Re-scan processes and listening sockets.
9. Report which processes exited and which ports became free.
10. If verified targets remain, offer **Force stop** as a separate destructive action using `SIGKILL`.

Force-stop eligibility belongs only to the exact post-`SIGTERM` rescan. Immediately before every `SIGKILL`, FlowTrace freshly validates PID, start time, UID, executable when available, and all proposed group members. Any refresh, app relaunch, changed identity, ownership change, new group member, or unavailable mandatory field invalidates force-stop eligibility and requires a new review. The app never persists a pending stop or resumes it after relaunch.

FlowTrace must never build a kill command from an untrusted process name, path, port string, or shell interpolation. Signals are sent directly to verified numeric identifiers.

The action is permitted only for processes owned by the current user. Authorization escalation is out of scope.

## Results and Resource Reporting

The success result leads with concrete outcomes:

> Stopped 2 background items · ports 3000 and 5173 are free · stopped processes previously used about 940 MB RSS

The result distinguishes:

- process exited;
- port released;
- process already gone;
- identity changed, so nothing was stopped;
- graceful stop timed out;
- permission denied.

The app does not claim that total system RAM “improved by X%” or that prior RSS was literally released. It may show the stopped processes’ prior RSS as a percentage of physical RAM, clearly labelled approximate. Memory pressure before and after may be shown as supporting context, not as proof of a precise causal percentage.

## Error Handling

- A PID that disappears before confirmation becomes “Already stopped.”
- A reused or changed PID is never signalled and produces “This process changed; refresh and review again.”
- A port still held by another process is reported as still occupied, with the new owner if readable.
- Partial success lists each successful and unsuccessful target separately.
- Failure to read RSS does not block stopping; the UI shows “Memory unavailable.”
- Failure to resolve a project prevents project-level grouping but does not invent a project name.
- Unknown human activity is shown as unknown, never rounded into “recent” or “old.”
- Closing the sheet or quitting FlowTrace cancels pending waits and never schedules a later signal.

## Privacy

The feature remains local-only. Process inventory and memory samples are ephemeral and are not persisted. The existing consent gate applies to transcript-derived human activity. Turning a source off removes its transcript evidence from ranking without hiding the fact that its process exists.

## Component Boundaries

### Core

- `AttentionRanker`: converts dated human evidence into Continue candidates; pure and testable.
- `ProcessInventoryReader`: reads process identity, hierarchy, RSS, ownership, and sockets; read-only.
- `BackgroundItem`: presentation-neutral model grouping verified processes by place and purpose.
- `ProcessStopper`: validates identity, performs graceful termination, verifies exit and ports, and exposes force-stop eligibility.

### App

- `NowView`: becomes an information-architecture shell; it no longer decides that the first live process is the active project.
- `ContinueSection`: renders up to two attention-ranked places.
- `RecentSection`: renders recent recovery material.
- `BackgroundSummary`: collapsed summary and entry into review.
- `BackgroundReviewSheet`: selection, technical disclosure, confirmation, progress, partial failure, and result states.

The models do not depend on SwiftUI. The UI receives immutable snapshots and invokes explicit controller operations.

## Testing Strategy

### Ranking tests

- recent human attention outranks fresh agent heartbeat;
- a five-day-old human turn is not labelled active because the process is writing now;
- server-only places never become Continue candidates;
- unknown attention never becomes recent;
- explicit notes/captures are retained when the process exits.
- attention older than seven days is ineligible even when it has higher-confidence context;
- deliberate background-review visits do not create attention;
- canonical paths deduplicate candidates and ties sort deterministically;
- disabling a transcript source removes its evidence on the next ranking pass.

### Inventory tests

- multiple listening ports owned by one PID are grouped once;
- duplicate port numbers on different interfaces or address families remain distinguishable;
- parent/child processes are deduplicated into an understandable stop target;
- RSS and start-time parsing tolerate missing fields;
- unsupported/unassociated processes are absent from the cleanup inventory;
- endpoint tuples and dual-stack listeners produce deterministic port counts;
- overlapping discovery routes deduplicate PID and RSS totals.

### Stopper tests

- identity mismatch refuses to signal;
- graceful termination is attempted before force termination;
- successful exit and port release are independently verified;
- partial success preserves per-target results;
- PID reuse cannot terminate the replacement process;
- current-user ownership is required;
- shell interpolation is never involved.
- a process group containing one unrelated member is never group-signalled;
- every PID is revalidated immediately before `SIGTERM` and `SIGKILL`;
- refresh, relaunch, or identity change invalidates force-stop eligibility;
- overlapping targets receive one signal with results attributed to every affected row;
- the five-second wait remains off the main actor and can be cancelled safely.
- foregrounding a target before confirmation refuses the stop and sends no signal;
- foregrounding a target after confirmation but before signalling refuses the stop and sends no signal;
- newer human attention before confirmation refuses the stop and sends no signal;
- newer human attention after confirmation but before signalling refuses the stop and sends no signal.

Use controllable process fixtures rather than signalling real user processes in the automated suite.

### UI tests

- “Also running,” “Active project,” “server only,” and “needs your attention” do not appear;
- background details are collapsed initially;
- no technical acronym is required to understand the summary;
- destructive actions require review and confirmation;
- force stop appears only after a verified graceful-stop failure;
- VoiceOver labels describe the affected project, process type, port, and action.
- Continue contains no more than two unique paths ordered by the deterministic attention rules;
- an empty Continue section never promotes a machine-only item;
- Recently contains no more than six unique paths used within 30 days, excludes Continue paths, and disappears when empty;
- the same place is summarized, not duplicated as a full card, when it also has background processes;
- closing/reopening the Now screen returns background details to collapsed state;
- cancelling confirmation sends no signal;
- relaunching during a wait sends no later signal;
- inventory refresh completes off the main actor and retains the previous snapshot until replacement, so the screen never flashes a false empty state.

## Rollout

1. Correct the Now information architecture and attention ranking.
2. Add read-only background resource details and the review sheet.
3. Add graceful server stopping and verification.
4. Add supported-agent stopping.
5. Consider bulk stale-item selection and stale preselection only after observing real usage.

No automatic cleanup, schedules, notifications, or remembered one-click destructive preference are part of the initial release.

## Success Criteria

- Every Continue and Recently card displays its qualifying “Last used” date plus context when available; otherwise it displays plain-language qualifying evidence such as “You opened this place 2 hours ago,” so its presence is explainable without process terminology.
- Given one recent human turn and one newer machine-only heartbeat, the human-attended place is first and the machine-only place is absent from Continue.
- A living process alone is never labelled or ranked as the user’s active project.
- Background details are collapsed on every fresh presentation and the home screen shows one summary rather than process rows.
- A user can identify and safely stop a supported local server without knowing its PID, after a confirmation naming the project and port.
- Every stop result independently verifies process exit and each expected endpoint’s post-stop state within the bounded wait: free, or still occupied with the current owner when readable.
- Duplicate discovery routes never inflate thing, port, or RSS totals.
- Missing or changed mandatory identity prevents signalling.
- VoiceOver exposes section, target, selection, confirmation, progress, and result states without relying on color.
- Resource copy consistently says prior process RSS and never claims exact RAM released.
