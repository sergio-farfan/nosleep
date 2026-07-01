# Design: Auto-activate, clearer active state, and completion notification

**Date:** 2026-07-01
**Author:** Sergio Farfan
**Status:** Approved (pending spec review)

## Context

NoSleep is a menu-bar caffeinate utility (SwiftUI `MenuBarExtra`, default native
`.menu` style). Three usability gaps prompted this work:

1. Selecting a duration does **not** start NoSleep — the user must separately click
   Start. It should activate immediately on selection.
2. The in-menu active status is **hard to read**: the status dot is grey (not green)
   and the countdown text is faint. `MenuBarView.swift:33` already sets
   `.foregroundStyle(.green)`, but the native menu ignores it.
3. When a timed session ends, **nothing tells the user** — the Mac silently returns to
   normal sleep behavior.

### Why the status line is grey (root cause)

In the native `.menu` style, macOS renders **non-interactive** items (plain `Text` /
`Label`) as *disabled* — greyed out — and overrides any `foregroundStyle`. Interactive
items (`Button`) render in the normal label color (black in light mode, white in dark).
This is visible in the current UI: "Inactive" (a `Label`) is grey while "Start" (a
`Button`) is black. Native menus also do not support arbitrary text colors. Therefore
"make the countdown black" means "make that line an interactive item," and "make the dot
green" means "use a pre-colored icon rather than `foregroundStyle`."

## Goals

- Selecting any duration immediately activates NoSleep and starts the countdown.
- The active status line renders in normal (black/high-contrast) text with a green dot.
- On natural completion of a timed session, show a notification with a single
  **"Extend 1 hour"** action that starts a fresh 1-hour session.

## Non-goals / Out of scope

- Switching to `.window` MenuBarExtra style (explicitly declined — keep the native menu).
- Showing the countdown in the menu bar itself (declined — keep it in the menu only).
- Bold countdown text (not possible in the native menu; declined).
- Developer ID signing / notarization.

## Confirmed decisions

| # | Decision |
|---|----------|
| Auto-activate | Selecting **any** duration (including Indefinite) immediately (re)starts. Indefinite runs with no countdown (∞). Re-picking while active restarts with the new duration. Stop and Start buttons remain. |
| Green dot | Rendered as a **pre-colored** green icon (a green-tinted `circle.fill` `NSImage`, or 🟢 emoji fallback), not via `foregroundStyle`. |
| Black countdown | The status line becomes a **clickable `Button`** (so the native menu renders it black); clicking it toggles start/stop. Current font kept (no bold). Layout otherwise unchanged; the separate Start/Stop button stays. |
| Completion notification | Fires only on **natural expiry of a timed session** (not on user Stop, not for Indefinite). One action, **"Extend 1 hour"**, starts a fresh 1-hour session. |
| Extend semantics | "Extend 1 hour" sets the selected duration to 1 hour and starts — the menu radio will then show 1 hour. |

## Architecture

Four files; one new. The completion→notification→extend loop is encapsulated in a new
`NotificationManager` that `CaffeinateManager` composes, so no app-level wiring is needed
and all `UserNotifications` code lives in one place.

### `NotificationManager.swift` (new)

`@MainActor final class NotificationManager: NSObject, UNUserNotificationCenterDelegate`

- **Responsibilities:** request notification authorization; register a
  `SESSION_COMPLETE` category containing a single `EXTEND_1H` action ("Extend 1 hour");
  set itself as `UNUserNotificationCenter.current().delegate`; deliver the completion
  banner; handle the action response.
- **Interface:**
  - `func requestAuthorization()` — `requestAuthorization(options: [.alert, .sound])`.
  - `func postCompletion(duration: SleepDuration)` — builds a `UNMutableNotificationContent`
    (title "NoSleep", body e.g. "Your \(duration.label) session has ended.",
    `categoryIdentifier = "SESSION_COMPLETE"`) and adds it with an immediate (nil) trigger.
  - `var onExtend: (() -> Void)?` — invoked when the user taps "Extend 1 hour".
- **Delegate methods** (`nonisolated`, hop to `@MainActor`):
  - `willPresent` → return `[.banner, .sound]` so it shows even though a menu-bar app is
    effectively always "active."
  - `didReceive` → if `actionIdentifier == "EXTEND_1H"`, call `onExtend?()`.

### `CaffeinateManager.swift` (changes)

- Compose `let notifications = NotificationManager()`; in `init`, set
  `notifications.onExtend = { [weak self] in self?.extendOneHour() }`.
- `changeDuration(_:)`: set `selectedDuration`, then **always** `start()` (currently it
  only restarts when already active). This is the auto-activate behavior.
- `extendOneHour()`: `selectedDuration = .oneHour; start()`.
- **Distinguish natural expiry from user Stop / restart** (see concurrency note):
  - `private var stoppedByUser = false` — set `true` in `stop()`.
  - `private var runToken = 0` — incremented in `start()`; the `terminationHandler`
    captures its token.
  - `private var activeDuration: SleepDuration?` — captured in `start()`.
  - `handleTermination(token:)`: ignore if `token != runToken` (stale termination from a
    restarted session). Otherwise reset state as today; if `!stoppedByUser` and
    `activeDuration` is a timed value, call `notifications.postCompletion(duration:)`.
    Reset `stoppedByUser = false`.

### `MenuBarView.swift` (changes)

- Replace the status `Label` with a `Button { manager.toggle() }` whose label is
  `HStack { <green/grey dot icon>; Text(status) }`. Enabled → renders black. Active shows
  the green dot + "Active — \(formattedRemaining) left"; inactive shows a hollow/grey dot +
  "Inactive."
- The green dot uses a pre-colored icon (not `foregroundStyle`).
- Everything else (Start/Stop button, Duration list, Start at Login, Quit) unchanged. The
  Duration buttons already call `changeDuration`, which now auto-activates.

### `NoSleepApp.swift` (changes)

- Menu-bar label unchanged (cup outline/fill by `isActive`).
- Trigger `caffeinateManager.notifications.requestAuthorization()` once at launch (e.g. a
  `.task` on the menu content, or in `NotificationManager` setup).

## Concurrency note (important)

`Process.terminationHandler` runs on a background thread and hops to `@MainActor`. On a
**restart** (`changeDuration` → `start()` → `stop()` terminates the old process, then a new
process launches), the old process's handler fires *asynchronously*, possibly after the new
session is live. A naive `stoppedByUser`-only check could then fire a spurious "completed"
notification for the restarted session. The **`runToken` generation counter** prevents this:
each `start()` bumps the token, the handler captures its token, and a handler whose token no
longer matches is ignored. `stoppedByUser` then only needs to distinguish a user Stop of the
*current* session from its natural expiry.

## Risks & verification

- **Ad-hoc signing + notifications (primary risk):** `UNUserNotificationCenter` can be
  unreliable for ad-hoc-signed, non-notarized apps, and only works when run as a bundled
  `.app` (not `swift run`). Apple docs don't cover this edge, so it will be **verified
  empirically early**: build `NoSleep.app`, run a short session, and confirm the banner
  *and* the "Extend 1 hour" button appear and work. If delivery fails, revisit before
  building the rest.
- **Testing expiry quickly:** the shortest preset is 15 min. During development, verify the
  completion path with a temporary short timer (removed before completion).
- **API validation:** exact `UserNotifications` API usage will be checked against Apple's
  official documentation during implementation.

## Verification checklist

1. Pick a duration while inactive → NoSleep activates and the countdown starts.
2. Re-pick a different duration while active → restarts with the new duration; **no**
   completion notification fires from the restart.
3. Menu shows a **green** dot and **black** "Active — …" text; clicking the line toggles.
4. Click Stop → deactivates; **no** notification.
5. Let a (temporarily shortened) timed session expire → banner "Your … session has ended."
   with "Extend 1 hour"; tapping it starts a fresh 1-hour session (menu shows 1 hour).
6. Indefinite → activates with ∞; never fires a completion notification.
7. `swift build -c release` compiles; `pgrep caffeinate` reflects start/stop.
