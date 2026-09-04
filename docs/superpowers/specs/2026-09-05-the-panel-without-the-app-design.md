# The panel, without the app

Sub-project **A3**. Prompted by direct observation rather than analysis: pressing the capture shortcut brings the **whole FlowTrace window** forward, over the browser or editor you were in. The owner's words: *"Whenever I click on my key to get the model up, I always get the app up as well. I don't want that to happen. I just want the model to come up… I just want the icon to be there."*

This supersedes the ordering in `docs/strategy/2026-09-04-habit-and-adoption.md`, which ranked the menu-bar surface as the highest-leverage retention item. It is the same change: making FlowTrace a menu-bar-resident app is what both fixes the panel *and* creates the surface that brings someone back.

## Problem

The panel is supposed to appear over what you are doing and hand focus straight back — the design comment in `QuickCapturePanel` says exactly that. Instead the main window comes up too. Two mechanisms combine, and neither is a bug in isolation:

1. **`NSApp.activate(ignoringOtherApps: true)` activates the whole app.** `QuickCaptureController.present()` calls it because a *regular* app's window cannot take keyboard focus while another app is frontmost. The comment above that line records losing this fight once already: `.nonactivatingPanel` was removed because the panel "appeared and then silently refused every keystroke."
2. **The panel declines to be the main window** (`canBecomeMain: false`, `QuickCapturePanel.swift:41`), so on activation macOS looks for one — and `AppLifecycle.applicationShouldHandleReopen` obligingly runs `sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)`. The window was never closed, only hidden, because `applicationShouldTerminateAfterLastWindowClosed` returns `false` to keep the global shortcut alive.

So the app does precisely what a Dock-resident app is supposed to do. The product wants something else.

Two secondary faults belong in the same change, because they are the same complaint:

- **The panel is a dashboard, not a notepad.** 520×200, with a "Right now" header, the app name, a tab count, an open-span duration, and a "Just before this" list of recent activity. The ask was *"just a notepad… that just opens up and I'm able to write."*
- **The shortcut story contradicts itself in three places.** `README.md` says ⌥Space is the default; `CaptureTrigger` offers ⌃⌥N and registers nothing until chosen; onboarding's recorder is seeded from `HotKeyShortcut.default` (⌥Space) directly beneath advice to avoid ⌥Space. This is audit item 0.4 and it is cheap to fix while in this code.

## Approach

**Make FlowTrace a menu-bar-resident app, and let the panel be the primary surface.**

This is the architecture every tool that reliably takes typed input over any app uses — Raycast, Alfred, Spotlight: an accessory-policy app with no Dock icon, a floating panel, and an explicit activate. An accessory app activating does not switch the menu bar, does not bounce a Dock icon, and has no main window for macOS to go looking for.

A note on the comparison the owner drew: **Wispr Flow is not a usable model for the mechanism.** It takes *voice* (`NSMicrophoneUsageDescription`: "Allow Wispr Flow microphone access to transcribe your speech"), so its pill never needs keyboard focus at all. Copying its shape without its input method would reproduce the current problem. The look is worth borrowing; the architecture is not.

Rejected alternatives:

- **`.nonactivatingPanel` alone.** Already tried and reverted — a non-activating panel cannot become key while another app is active, which is the whole problem. It becomes viable *only* in combination with accessory policy, which is what this design does.
- **Guarding `applicationShouldHandleReopen` while the panel is up.** A one-line patch that stops the window appearing. Rejected as the primary fix because it treats the symptom: the app would still activate, still steal the menu bar, still show a Dock icon, and the panel would still be fighting for key status. Worth keeping as a belt-and-braces guard (§3), not as the answer.
- **Capturing keystrokes with a `CGEventTap` so the panel never needs focus.** Would work without activation, and is how some launchers behave — but it requires Accessibility, means intercepting global keyboard input, and is a far more invasive privacy posture for an app whose entire claim is that it reads only what the machine already wrote. Refused.

### What "accessory" costs, stated honestly

An accessory app has no menu bar of its own. That removes the app menu, and with it the `CommandMenu` shortcuts the app currently defines (⌘1/⌘2/⌘3 navigation, ⌘, for Settings, ⌘N). The standard remedy is to switch policy at runtime — `.accessory` while resident, `.regular` while the main window is open, back to `.accessory` when it closes. That is a real state machine with real edge cases (Settings opened from the menu bar with no main window; the window closed while Settings is still open), and §2 specifies it rather than leaving it to be discovered.

## Design

### 1. The app is accessory by default

- `Scripts/bundle.sh` adds `<key>LSUIElement</key><true/>` to the generated `Info.plist`. This is what removes the Dock icon and the ⌘-Tab entry.
- `MenuBarExtra` already exists (`FlowTraceApp.swift:51`) and becomes the app's permanent presence. Its label is currently the SF Symbol `point.3.filled.connected.trianglepath.dotted`; the repository now has `Resources/MenuBarGlyph.svg`, and a **template** image (monochrome, auto-inverting) is what belongs in a menu bar. The app icon proper is not a menu-bar asset.
- `AppLifecycle.applicationShouldHandleReopen` loses its reason to exist — there is no Dock icon to click. It is replaced by the menu bar's existing "Open FlowTrace" item.

### 2. Policy switching, specified

A single owner for the transition, so it cannot be half-applied:

```swift
/// The app lives in the menu bar. It becomes a regular app only while a real
/// window is on screen, because an accessory app has no menu bar of its own —
/// and without one there is no ⌘, and no ⌘1/2/3.
@MainActor
enum ActivationPolicy {
    /// How many windows want the app to be regular. A count, not a flag: the
    /// main window and Settings can be open at once, and the first one to
    /// close must not demote the app under the second.
    private static var claims = 0

    static func claimRegular()
    static func releaseRegular()
}
```

`claimRegular()` sets `.regular` on the first claim; `releaseRegular()` returns to `.accessory` when the count reaches zero. Claims are taken when the main window or Settings appears and released on disappear (SwiftUI `.onAppear`/`.onDisappear` on the scene roots). The counter is what prevents the classic bug — closing the main window while Settings is open demoting the app and stranding Settings without a menu bar.

**The capture panel never claims.** It is shown while the app is accessory, which is the entire point.

### 3. The panel takes focus without taking over

`present()` keeps `NSApp.activate(ignoringOtherApps: true)` — an accessory app's activation is cheap and does not reorder another app's windows — and the panel keeps `canBecomeKey: true`. What changes is that there is no longer a main window for macOS to promote, and no Dock icon to raise.

Two guards, because the failure is silent and expensive:

- `applicationShouldHandleReopen` returns `true` without ordering any window front while a capture panel is on screen. Belt and braces: if a reopen event arrives mid-capture, it must not drag the window up.
- The existing instrumentation stays and is the acceptance test. `QuickCapturePanel` already logs, 250 ms after presenting, whether the panel is key **and whether the text field became first responder**. Today's evidence is 1 success in 6 opens; the bar for this sub-project is **6 in 6, across a browser, an editor, a terminal and a full-screen app**, with the paired "N chars reached the field" line non-zero every time.

### 4. A notepad, not a dashboard

The panel becomes one line plus, at most, one line of context.

- **Keep:** the text field; the place or page it will land on (one line — `flowtrace` or the page title, which A2 supplies); the smart-capture suggestion row when there is one; the save/cancel hints.
- **Remove from the panel:** the "Right now" eyebrow, the separate app-name row, the tab count, the open-span duration, and the entire "Just before this" list. That list is genuinely useful — it moves to the main window's Today view, where there is room to read it and no cost to appearing.
- **Size:** width around 460, height driven by content rather than the fixed 200. The panel should look like a single input, because that is what it is.

This is deliberately a subtraction. Everything removed is already available one keystroke away in the window; none of it is worth the 200 ms of reading that currently sits between pressing the key and typing.

### 5. One shortcut story

While in this code, resolve the three-way contradiction (audit 0.4):

- Seed the onboarding recorder from `CaptureTrigger.suggestion` so the recorder, the button label, the hint and the Reset link all name the same key.
- Register the trigger **before** advancing the onboarding step, so a clash is reported on the screen that can still show it — today `shortcutFailure` is written after the step has moved on.
- Correct `README.md` to say the key is chosen on first run, with the offered default named once.
- One name for the action everywhere. It is currently "Why Am I Here?…" in the menu, "Add a note here" in the menu bar, and "why are you here?" in the panel.

### 6. Out of scope

The menu-bar popover's *content* — the forgotten count, the mini-Now list — is the retention lever from the habit document and deserves its own pass; this sub-project only makes the menu bar the app's home and keeps the popover as it is. Also out: Accessibility for window titles (its own small change), anything from sub-projects B (consent) or C (redaction), and the voice input that Wispr Flow's comparison invites.

### 7. Decisions to confirm at review

1. **No Dock icon at all**, versus a preference for it. An accessory app is a real behaviour change: FlowTrace disappears from ⌘-Tab and the Dock, and is reachable only from the menu bar and its shortcut. That is what was asked for, and it is what Raycast and Alfred do, but it should be a deliberate choice rather than a side effect.
2. **How much context survives in the panel.** §4 cuts to one line. The "Just before this" list is the most defensible casualty — it is the thing that turns a blank box into a prompt. Confirm that moving it to Today is acceptable.

## Testing

Little of this is reachable from the Core-only `TestKit` harness — it is app lifecycle, window server and AppKit policy. That is a real constraint, so the acceptance criteria are instrumented rather than unit-tested:

- `ActivationPolicy`'s claim counter is pure and testable if it is factored to take an injectable setter rather than calling `NSApp` directly: claim/claim/release leaves the app regular; the second release demotes it; releasing below zero is a no-op rather than a crash.
- Everything else is the manual pass, read from `debug.log`, which the instrumentation added in `a185b2a` already produces in the right shape.

## Manual verification

Rebuild and relaunch with `Scripts/dev.sh` — note that `bundle.sh` alone builds without replacing the running app, which is how an earlier test run was performed against a stale binary.

1. **No Dock icon, and a menu-bar glyph is present.** FlowTrace does not appear in ⌘-Tab.
2. **The complaint, directly.** In Brave, press the key: the panel appears over the page and **the FlowTrace window does not**. Repeat in VS Code, in Terminal, and in a full-screen app. Four for four.
3. **Typing lands, every time.** `debug.log` shows `field ready: true` and a non-zero "chars reached the field" for all four. This is the number that was 1 in 6.
4. **Focus returns.** After Return or Escape, the app you were in is frontmost again, with its own window unmoved.
5. **The window still works.** Menu bar → Open FlowTrace: the window appears *and has a menu bar* (⌘, opens Settings, ⌘1/⌘2/⌘3 navigate). Close it: no Dock icon returns.
6. **The counter holds.** Open the main window, open Settings, close the main window first — Settings must keep its menu bar. Close Settings: the app returns to the menu bar only.
7. **Quitting.** Menu bar → Quit actually quits, and the open activity span is closed (the recorder's terminate observer, added in sub-project A).
8. **The shortcut story.** A fresh onboarding names the same key in the recorder, the button, the hint and the README, and a deliberate clash (bind something the system owns) is reported on the shortcut step rather than after it.
