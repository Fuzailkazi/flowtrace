# Local Servers View Design

## Goal

Give users one click from FlowTrace's sidebar to see the eligible local TCP
listeners FlowTrace can identify, understand which project each belongs to,
open one in a browser, or deliberately stop one. This is a supporting “what
was running?” work-context surface, not a server-management dashboard.

Screenshot capture and retrieval remain part of the same work-memory product:
screenshots will live with their app, window, project, time, and activity context
and be browsed from Memories. This feature does not change that direction.

## Entry point and information architecture

- Add a **Local servers** item directly below **Now** in the existing sidebar.
- Show the current number of detected servers beside the item when available.
- Selecting it opens a dedicated route in the existing workspace window.
- Keep project-level server details in Now and Place Recall as they are today;
  this view is the complete overview, not a replacement for contextual details.

## Content and interaction

- Show a clear heading, the number of active servers, and when the list was last
  refreshed.
- Group server rows by project. Put servers without a resolvable project in an
  **Other local servers** group rather than dropping them.
- Each row shows the port as the primary identifier, process name, project (or
  working-directory context when no project is found), and the local address.
- **Open** opens the local address in the default browser.
- **Stop…** opens a destructive confirmation that names the process, PID, and
  port. On confirmation, reuse `ProcessStopper`'s executable-identity check and
  graceful termination. Refresh the list and report success or a useful failure.
- Provide a visible refresh action and refresh on entry. Avoid a high-frequency
  timer that repeatedly runs process and Git discovery while the user is idle.
- Provide distinct loading, empty, read-failure, and refreshed states. An empty
  state should say that no eligible local listeners were found. If a refresh
  fails after a previous successful read, keep those results visible with a
  clear stale/error indicator and retry action; do not make failure look empty.

## Discovery and privacy boundary

- Keep discovery read-only and local. Do not connect to, probe, or send requests
  to discovered services.
- Eligibility is a concrete process-table rule, not a guess at whether a
  command is a “dev server”: list each TCP listener whose owning process has a
  working directory under the current user's home folder. This may include a
  user-owned local service that is not a development server, and excludes
  listeners whose working directory cannot be read or is outside the home
  folder. Resolve one working directory per PID using the existing `lsof`
  discovery path. Resolve project roots when possible; retain other eligible
  listeners under their working-directory label.
- Display `http://localhost:<port>` as the address, matching FlowTrace's
  existing `LiveServer.address` behavior. Do not infer service protocol or test
  reachability; opening is the user's explicit action.
- Do not expand the view to every operating-system listener or present it as a
  complete inventory of all network services. Existing onboarding consent and
  the app's local-first posture continue to govern when the view is available.
- Stop only through `ProcessStopper`, which rechecks the executable identity
  immediately before sending SIGTERM. Never add force-kill or shell-command
  behavior.

## Visual direction

- Follow FlowTrace's existing SwiftUI Journal tokens, typography, spacing, and
  light/dark palettes. The view should feel like a focused page in the current
  workspace, not a separate admin console.
- Keep the list scannable: project headings with compact rows, aligned port and
  process labels, and restrained secondary metadata. Use semantic live/status
  color only where it communicates real state.
- Reuse the existing server-open and stop-confirmation patterns where possible.
  Keep the destructive stop action secondary to opening and identifying a
  server.

## Out of scope

- Starting, restarting, configuring, or proxying servers.
- Port scanning, health checks, HTTP metadata inspection, or service probing.
- Listing listeners whose process working directory is outside the user's home
  folder or cannot be read.
- Reorganizing screenshot capture, Memories, or the main product navigation.

## Acceptance criteria

1. One sidebar click opens a single view containing all eligible local
   listeners found by the discovery rules, grouped by project or working folder.
2. A row identifies its localhost port and process, and can open the local URL.
3. Stop requires confirmation, revalidates process identity, uses graceful
   termination, and refreshes/report results afterward.
4. Empty, loading, and failure cases are distinguishable and understandable.
5. Discovery runs off the main actor and does not perform network requests.
6. Existing Now and Place Recall server actions continue to work.
7. The page follows existing theme tokens and works in system, light, and dark
   appearance without resetting the main window identity.
