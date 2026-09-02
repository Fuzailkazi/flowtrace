# UX unification and smart capture

## Problem

Two things are true at once about FlowTrace right now:

1. **Capturing "why" is still a blank box.** `QuickCaptureView` already loads
   the activity that led up to this moment (`leadingUp`) and displays it as
   read-only context, but never uses it to help answer the question it's
   asking. You retype context FlowTrace already has.
2. **The app is visually two apps stitched together.** `Now`, `Timeline`,
   `SessionsRail`, and `QuickCaptureView` (8 files) use a newer "Journal"
   design language — warm paper/ink colors, restrained typography, diary-like
   framing. Everything else — `Dashboard`, `ThreadDetail`, `CaptureSheet`,
   `Settings`, `Onboarding` (16 files) — still uses the older, generic
   `Theme` system: dense stacked Cards, colored Chips, small system-font
   labels. Moving from Now into a thread, or into Capture, changes the
   texture of the app under you.
3. **Navigation is effectively hidden.** The old `Sidebar` (badge counts for
   proposals needing attention, active/paused/completed threads) is dead
   code — not instantiated anywhere. Everything besides Now/Timeline lives
   behind a small "More" toolbar ellipsis, as plain menu text with no counts
   or attention markers.

None of this is one broken screen. It's the seams between screens, and the
things that used to be visible (what needs attention) that no longer are.

## Approach

Fix it in five phases, each independently shippable, each landing as its own
reviewable commit(s) rather than one large diff:

1. **Smart Capture** — pre-fill/suggest the "why" text in `QuickCaptureView`
   from context FlowTrace already has. Self-contained; already in the Journal
   style. *(Fully designed below — this is what's being built now.)*
2. **Navigation** — replace the buried "More" menu with a persistent,
   glanceable nav surface in the Journal style, with badges for what needs
   attention (proposals, blocked threads) — the thing `Sidebar` used to do,
   restyled rather than resurrected as-is.
3. **Thread surfaces** — port `Dashboard` ("Unfinished work"), `ThreadDetail`,
   `ThreadCard`/`ProposalCard`, `ThreadListView`, `SearchResultsView`,
   `CaptureRows` from `Theme` to `Journal`. Highest-traffic surfaces after
   Now/Timeline.
4. **Capture Sheet** — restyle the manual multi-mode dialog (`CaptureSheet`,
   `CaptureModes`, `NewThreadSheet`) to match.
5. **Settings & Onboarding** — lowest traffic, last.

Phases 2–5 are captured here only at the summary level (goal, scope, files
touched). Each gets its own focused design pass immediately before its
implementation starts, once we've seen how the earlier phases actually land
— this avoids over-designing later phases whose specifics may shift once
Phase 1 and 2 are built and used for a while.

---

## Phase 1 — Smart Capture (fully designed)

### Goal

When the Quick Capture panel ("why are you here?") opens, show at most one
suggested answer, built only from records FlowTrace already stores. Never
auto-fill silently; always require an explicit accept, and always let the
user tell it's a suggestion versus their own words.

### Suggestion sources, in priority order

Only the first source that produces a non-empty result is used — this is a
single best-guess, not a set of competing options.

1. **Project note** — if a recent agent-session activity event (the
   currently-open activity, or the most recent one in `leadingUp`) carries
   `metadata["cwd"]`, and a `ProjectNote` exists for that repository
   (`store.projectNote(for:)` — the same "what you're building here" note
   shown on the Now view), suggest its `building` text. Highest trust: it's
   your own sentence about this exact project.
2. **Tab note** — if `resolved.url` is set and `store.noteForTab(url:)`
   returns a non-empty note, suggest it. Also your own words, about this
   exact page.
3. **Last agent prompt** — from `leadingUp`, the most recent event with a
   non-empty `metadata["asked"]` or `.note`, condensed via
   `AgentSession.condense`. Framed explicitly as "Last asked: …", never
   presented as if it were a note you wrote — it's observed, not authored.

If none of the three produce anything, no suggestion is shown. Silence is
the correct default here, consistent with `BriefBuilder`'s existing rule
("a hook that produces noise gets uninstalled").

### Interaction

- A single tappable row appears under the text field, only while the field
  is empty:
  `💭 "fix the login redirect bug"                    Tab to use`
  (source 3 instead reads `💭 Last asked: "…"`.)
- **Tab** (while the field is empty and focused) or a **click** on the row
  fills the field with the suggested text — selects it so typing replaces it
  outright, but it is fully editable and nothing is saved until Return is
  pressed.
- As soon as the field becomes non-empty by any means, the row disappears.
- This mirrors the existing "Edit first" pattern on `ProposalCard` for
  detected work: suggest, never auto-commit.

### Architecture

A new pure, deterministic, unit-testable type in `FlowTraceCore`, matching
the shape of `DeterministicSummarizer` and `BriefBuilder` — no network, no
inference beyond stored records, fully traceable to what's shown:

```swift
public struct CaptureSuggestionInput: Sendable {
    public var projectNote: String?
    public var tabNote: String?
    public var lastAgentPrompt: String?
}

public struct CaptureSuggestion: Sendable, Equatable {
    public enum Source: Sendable, Equatable { case projectNote, tabNote, agentPrompt }
    public var text: String
    public var source: Source
}

public enum CaptureSuggester {
    public static func suggest(_ input: CaptureSuggestionInput) -> CaptureSuggestion?
}
```

`QuickCaptureView.load()` gathers the three raw inputs (already-available
store calls plus the existing `leadingUp` fetch — no new storage, no new git
reads) and calls `CaptureSuggester.suggest`. The view stays thin; all
priority/selection logic is testable independent of SwiftUI.

### Testing

`CaptureSuggesterTests.swift` alongside the existing `DetectorTests.swift` /
`BriefTests.swift`, covering: priority order (project note beats tab note
beats agent prompt), each source in isolation, and the all-nil → nil case.

### Manual verification

Since this is a UI-facing capture flow, verify by hand in the running app
(per the `run` skill) once implemented:
- Open a repo with a saved project note, trigger Quick Capture from that
  app → suggestion appears, matches the note, Tab fills it.
- Open a browser tab with a saved tab note → suggestion appears from the tab
  note, not the project note (tab note doesn't apply here so this confirms
  source selection, not priority — use a case with *both* available to
  confirm project note wins).
- Trigger Quick Capture somewhere with no matching source → no suggestion
  row appears at all.
- Start typing without accepting → row disappears; accepting then editing
  the text still saves the edited text.

---

## Phases 2–5 — summary only (design deferred)

| Phase | Goal | Primary files |
|---|---|---|
| 2. Navigation | Replace the "More" toolbar menu with a persistent, glanceable nav in the Journal style; restore attention badges (proposals, blocked threads) that `Sidebar` used to show | `FlowTraceApp.swift` (`MainWindow`/`chrome`), a new Journal-styled nav component, `AppModel` route handling |
| 3. Thread surfaces | Port from `Theme` to `Journal` | `Dashboard/DashboardView.swift`, `Dashboard/ThreadCard.swift`, `Dashboard/ThreadListView.swift`, `Dashboard/SearchResultsView.swift`, `Dashboard/CaptureRows.swift`, `ThreadDetail/ThreadDetailView.swift`, `ThreadDetail/ThreadDetailSections.swift` |
| 4. Capture Sheet | Port from `Theme` to `Journal` | `Capture/CaptureSheet.swift`, `Capture/CaptureModes.swift`, `Capture/NewThreadSheet.swift` |
| 5. Settings & Onboarding | Port from `Theme` to `Journal` | `Settings/SettingsView.swift`, `Settings/ShortcutRecorder.swift`, `Onboarding/OnboardingView.swift` |

`Dashboard/Sidebar.swift` (the old, currently-dead nav component) is retired
once Phase 2 ships its replacement, rather than migrated.
