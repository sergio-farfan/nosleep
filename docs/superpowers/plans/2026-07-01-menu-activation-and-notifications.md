# Menu Activation & Completion Notification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make selecting a duration immediately start NoSleep, show a green dot + black (readable) status in the menu, and notify the user when a timed session ends with a one-tap "Extend 1 hour" action.

**Architecture:** Keep the native `MenuBarExtra` `.menu` style. Add a `NotificationManager` (encapsulates all `UserNotifications` code) that `CaffeinateManager` composes. Auto-activate lives in `CaffeinateManager.changeDuration`. A `runToken` generation counter plus a `stoppedByUser` flag distinguish a natural timed expiry (notify) from a user Stop or a restart (don't notify). The one piece of pure, tricky logic — the notify decision — is a `nonisolated static` function covered by unit tests; GUI/system behavior is verified by running the app.

**Tech Stack:** Swift 6, SwiftUI, `UserNotifications`, SPM, XCTest.

## Global Constraints

- macOS 14+ (`LSMinimumSystemVersion` 14.0); Swift tools 6.0 / Swift 6 language mode.
- All new Swift source files carry the GNU GPL v3 header (`Copyright (C) 2026 Sergio Farfan`).
- Manager classes are `@MainActor`-isolated.
- Keep the native `.menu` MenuBarExtra style — do **NOT** switch to `.window`.
- No new external dependencies (only Foundation / SwiftUI / UserNotifications system frameworks).
- Commits use the repo's local git identity (already set to `sergio-farfan` noreply). No Claude co-authorship.
- Verify with: `swift test` (unit), `swift build -c release` (compiles), and running the bundle (`./build.sh` then `open NoSleep.app`) with `pgrep caffeinate`.

---

## File structure

- `Package.swift` — add an XCTest `testTarget` (Task 1).
- `Tests/NoSleepTests/CaffeinateManagerTests.swift` — unit tests for the notify decision (Task 1, create).
- `Sources/NoSleep/CaffeinateManager.swift` — notify-decision static func (Task 1); behavior changes (Task 3).
- `Sources/NoSleep/NotificationManager.swift` — new; all `UserNotifications` logic (Task 2).
- `Sources/NoSleep/MenuBarView.swift` — clickable black status line + green dot + auth request (Task 4).
- `NoSleepApp.swift` — unchanged (menu-bar label already toggles by `isActive`).

---

### Task 1: Test target + notify-decision logic

**Files:**
- Modify: `Package.swift`
- Create: `Tests/NoSleepTests/CaffeinateManagerTests.swift`
- Modify: `Sources/NoSleep/CaffeinateManager.swift`

**Interfaces:**
- Produces: `nonisolated static func CaffeinateManager.shouldNotifyOnCompletion(terminatedToken: Int, currentToken: Int, stoppedByUser: Bool, duration: SleepDuration?) -> Bool`

- [ ] **Step 1: Add the test target to `Package.swift`**

Replace the `targets:` array so it reads:

```swift
    targets: [
        .executableTarget(
            name: "NoSleep",
            path: "Sources/NoSleep"
        ),
        .testTarget(
            name: "NoSleepTests",
            dependencies: ["NoSleep"],
            path: "Tests/NoSleepTests"
        )
    ]
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/NoSleepTests/CaffeinateManagerTests.swift`:

```swift
import XCTest
@testable import NoSleep

final class CaffeinateManagerTests: XCTestCase {
    func testNotifiesOnNaturalTimedExpiry() {
        XCTAssertTrue(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: false, duration: .twoHours))
    }

    func testNoNotifyWhenStoppedByUser() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: true, duration: .twoHours))
    }

    func testNoNotifyOnStaleTokenFromRestart() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 2, stoppedByUser: false, duration: .twoHours))
    }

    func testNoNotifyForIndefinite() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: false, duration: .indefinite))
    }

    func testNoNotifyForNilDuration() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: false, duration: nil))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test`
Expected: build FAILS with an error like `type 'CaffeinateManager' has no member 'shouldNotifyOnCompletion'`.

- [ ] **Step 4: Implement the static function**

In `Sources/NoSleep/CaffeinateManager.swift`, inside the `CaffeinateManager` class (e.g. just after the `@Published` properties), add:

```swift
    /// Pure decision: should a natural process termination fire a "session
    /// complete" notification? True only when the terminated run is still the
    /// current one (not a restart), the user didn't press Stop, and the session
    /// was a timed (non-indefinite) duration.
    nonisolated static func shouldNotifyOnCompletion(
        terminatedToken: Int,
        currentToken: Int,
        stoppedByUser: Bool,
        duration: SleepDuration?
    ) -> Bool {
        guard terminatedToken == currentToken else { return false }
        guard !stoppedByUser else { return false }
        guard let duration, duration != .indefinite else { return false }
        return true
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test`
Expected: PASS — `Executed 5 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Tests/NoSleepTests/CaffeinateManagerTests.swift Sources/NoSleep/CaffeinateManager.swift
git commit -m "Add notify-decision logic and unit test target"
```

---

### Task 2: NotificationManager + verify ad-hoc delivery (primary risk)

**Files:**
- Create: `Sources/NoSleep/NotificationManager.swift`
- Temporarily modify then revert: `Sources/NoSleep/MenuBarView.swift` (delivery spike only)

**Interfaces:**
- Produces: `@MainActor final class NotificationManager: NSObject` with `func requestAuthorization()`, `func postCompletion(duration: SleepDuration)`, `var onExtend: (() -> Void)?`.

- [ ] **Step 1: Create `NotificationManager.swift`**

```swift
// NotificationManager.swift
// NoSleep — macOS Menu Bar Caffeinate Utility
//
// Copyright (C) 2026 Sergio Farfan
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Foundation
import UserNotifications

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let categoryID = "SESSION_COMPLETE"
    private let extendActionID = "EXTEND_1H"
    private var didConfigure = false

    /// Invoked when the user taps the "Extend 1 hour" action.
    var onExtend: (() -> Void)?

    /// Call once at app launch. Registers the category + action, sets the
    /// delegate, and requests authorization. Kept out of `init` so the type is
    /// safe to construct in unit tests without touching UNUserNotificationCenter.
    func requestAuthorization() {
        guard !didConfigure else { return }
        didConfigure = true

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let extend = UNNotificationAction(identifier: extendActionID,
                                          title: "Extend 1 hour",
                                          options: [])
        let category = UNNotificationCategory(identifier: categoryID,
                                              actions: [extend],
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Deliver the "session complete" banner with the Extend action.
    func postCompletion(duration: SleepDuration) {
        let content = UNMutableNotificationContent()
        content.title = "NoSleep"
        content.body = "Your \(duration.label) session has ended."
        content.categoryIdentifier = categoryID
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show the banner even though a menu-bar app is effectively always active.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        Task { @MainActor [weak self] in
            if actionID == self?.extendActionID { self?.onExtend?() }
            completionHandler()
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build -c release`
Expected: `Build complete!`

- [ ] **Step 3: Add a temporary delivery spike to `MenuBarView.swift`**

At the top of `MenuBarView` (below the `@ObservedObject` properties) add a temporary probe, and attach `.onAppear` to the outer `VStack` (add `// TEMP` markers so it's easy to remove):

```swift
    @State private var probe = NotificationManager()   // TEMP
```

Attach to the `VStack` (after `.frame(width: 220)`):

```swift
        .onAppear {   // TEMP
            probe.requestAuthorization()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                probe.postCompletion(duration: .oneHour)
            }
        }
```

- [ ] **Step 4: Verify notification delivery on the ad-hoc build**

Run:
```bash
./build.sh && open NoSleep.app
```
Then click the menu-bar cup to open the menu (fires `.onAppear`). Grant the notification permission prompt. Within ~3 seconds a banner titled **NoSleep** — "Your 1 hour session has ended." should appear; hover it (or open Notification Center) to reveal the **Extend 1 hour** button.

Expected: banner appears AND the Extend action is present.
If NO banner appears: STOP — this is the ad-hoc-signing delivery risk. Re-evaluate (e.g., confirm the app is run as `NoSleep.app`, check `System Settings → Notifications → NoSleep`) before continuing. Quit the app: `pkill -x NoSleep` (only the freshly launched copy; check `pgrep -x NoSleep` first if another instance may be running).

- [ ] **Step 5: Remove the temporary spike**

Delete the two `// TEMP` blocks added in Step 3 from `MenuBarView.swift`. Confirm no `probe` / `TEMP` remains:

Run: `grep -n "TEMP\|probe" Sources/NoSleep/MenuBarView.swift`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add Sources/NoSleep/NotificationManager.swift
git commit -m "Add NotificationManager for session-complete notifications"
```

---

### Task 3: CaffeinateManager behavior (auto-activate, tokens, extend, completion)

**Files:**
- Modify: `Sources/NoSleep/CaffeinateManager.swift`

**Interfaces:**
- Consumes: `NotificationManager` (Task 2); `CaffeinateManager.shouldNotifyOnCompletion` (Task 1).
- Produces: `func extendOneHour()`; `changeDuration` now always (re)starts; `let notifications: NotificationManager`.

- [ ] **Step 1: Add state + compose NotificationManager**

In `CaffeinateManager`, add these stored properties next to `process` / `timer`:

```swift
    private var stoppedByUser = false
    private var runToken = 0
    private var activeDuration: SleepDuration?
    let notifications = NotificationManager()
```

Update `init()` to wire the extend action (keep the existing UserDefaults line):

```swift
    init() {
        let saved = UserDefaults.standard.integer(forKey: "selectedDuration")
        self.selectedDuration = SleepDuration(rawValue: saved) ?? .fourHours
        notifications.onExtend = { [weak self] in self?.extendOneHour() }
    }
```

- [ ] **Step 2: Update `start()` to stamp a run token and active duration**

Replace `start()` with:

```swift
    func start() {
        stop()

        runToken += 1
        let token = runToken
        stoppedByUser = false

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")

        var args = ["-d", "-i"]
        if selectedDuration != .indefinite {
            args += ["-t", "\(selectedDuration.rawValue)"]
            remainingSeconds = selectedDuration.rawValue
        } else {
            remainingSeconds = 0
        }
        proc.arguments = args
        activeDuration = selectedDuration

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTermination(token: token)
            }
        }

        do {
            try proc.run()
        } catch {
            return
        }

        process = proc
        isActive = true

        if selectedDuration != .indefinite {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.tick()
                }
            }
        }
    }
```

- [ ] **Step 3: Update `stop()` to record a user-initiated stop**

Replace `stop()` with:

```swift
    func stop() {
        stoppedByUser = true
        timer?.invalidate()
        timer = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        isActive = false
        remainingSeconds = 0
    }
```

- [ ] **Step 4: Auto-activate in `changeDuration` and add `extendOneHour`**

Replace `changeDuration(_:)` with:

```swift
    func changeDuration(_ duration: SleepDuration) {
        selectedDuration = duration
        start()
    }
```

Add `extendOneHour()` (e.g. right after `changeDuration`):

```swift
    func extendOneHour() {
        selectedDuration = .oneHour
        start()
    }
```

- [ ] **Step 5: Rewrite `handleTermination` to take a token and notify on natural expiry**

Replace `handleTermination()` with:

```swift
    private func handleTermination(token: Int) {
        // Ignore stale terminations from a session that was already replaced.
        guard token == runToken else { return }

        let completed = activeDuration
        let notifiable = Self.shouldNotifyOnCompletion(
            terminatedToken: token,
            currentToken: runToken,
            stoppedByUser: stoppedByUser,
            duration: completed
        )

        timer?.invalidate()
        timer = nil
        process = nil
        isActive = false
        remainingSeconds = 0
        stoppedByUser = false
        activeDuration = nil

        if notifiable, let completed {
            notifications.postCompletion(duration: completed)
        }
    }
```

- [ ] **Step 6: Verify unit tests still pass and it compiles**

Run: `swift test`
Expected: PASS (5 tests).
Run: `swift build -c release`
Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add Sources/NoSleep/CaffeinateManager.swift
git commit -m "Auto-activate on duration select; notify on timed completion"
```

---

### Task 4: MenuBarView — black clickable status, green dot, request auth

**Files:**
- Modify: `Sources/NoSleep/MenuBarView.swift`

**Interfaces:**
- Consumes: `manager.toggle()`, `manager.isActive`, `manager.formattedRemaining`, `manager.notifications.requestAuthorization()`.

- [ ] **Step 1: Replace the status line with a clickable (black) button + green dot**

In `MenuBarView.swift`, replace the current status `if manager.isActive { … } else { … }` block (the `Label("Active …")` / `Label("Inactive" …)`) with:

```swift
            // Status line — a Button so the native menu renders it in full
            // (black) text; the dot is a pre-colored (non-template) image so it
            // shows green regardless of the menu's monochrome symbol tinting.
            Button {
                manager.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(nsImage: MenuBarView.statusDot(active: manager.isActive))
                    Text(manager.isActive
                         ? "Active — \(manager.formattedRemaining) left"
                         : "Inactive")
                }
            }
            .padding(.horizontal, 4)
```

- [ ] **Step 2: Add the `statusDot` helper and the launch auth request**

Add this helper inside `struct MenuBarView` (e.g. below `body`):

```swift
    /// A small filled circle rendered as a non-template NSImage so it keeps its
    /// color (green = active, grey = inactive) inside the native menu.
    static func statusDot(active: Bool) -> NSImage {
        let size = NSSize(width: 9, height: 9)
        let image = NSImage(size: size)
        image.lockFocus()
        (active ? NSColor.systemGreen : NSColor.tertiaryLabelColor).setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
```

Attach `.onAppear` to the outer `VStack` (after `.frame(width: 220)`), so authorization is requested the first time the menu is shown:

```swift
        .onAppear { manager.notifications.requestAuthorization() }
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build -c release`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/NoSleep/MenuBarView.swift
git commit -m "Menu: clickable black status line with green active dot"
```

---

### Task 5: End-to-end verification (GUI + system)

**Files:** none permanent (a temporary edit in `CaffeinateManager.swift` is made and reverted).

- [ ] **Step 1: Build and launch**

```bash
./build.sh && open NoSleep.app
```

- [ ] **Step 2: Auto-activate + green/black status**

Open the menu, click **2 hours**. Reopen the menu.
Expected: status shows a **green** dot and **Active — 2h 0m left** in normal black text; `pgrep caffeinate` prints a PID.

- [ ] **Step 3: Restart does not notify**

With it active, pick **4 hours**.
Expected: still active (now "4h 0m left"); **no** completion notification appears from the restart.

- [ ] **Step 4: Clicking the status toggles; Stop does not notify**

Click the status line (or **Stop**).
Expected: status becomes **Inactive**; `pgrep caffeinate` prints nothing; **no** notification.

- [ ] **Step 5: Natural expiry → notification → Extend (temporary short timer)**

Temporarily edit `Sources/NoSleep/CaffeinateManager.swift`: change `case fifteenMin = 900` to `case fifteenMin = 5`. Then:

```bash
./build.sh && open NoSleep.app
```
Open the menu, pick **15 minutes**, wait ~5 seconds.
Expected: a banner "Your 15 minutes session has ended." appears with an **Extend 1 hour** action; clicking it starts a fresh session — `pgrep caffeinate` prints a PID and the menu shows **Active — 1h 0m left** with **1 hour** selected.

Revert the edit (`case fifteenMin = 900`) and rebuild:
```bash
./build.sh
```

- [ ] **Step 6: Indefinite activates with ∞**

Open the menu, pick **Indefinite**.
Expected: status shows **Active — ∞ left**; `pgrep caffeinate` prints a PID (no `-t`). Click Stop to finish.

- [ ] **Step 7: Final checks and commit**

Run: `swift test` (5 pass) and `swift build -c release` (compiles). Confirm the temporary edit is reverted:
`grep -n "fifteenMin" Sources/NoSleep/CaffeinateManager.swift` → should show `= 900`.

```bash
git add -A
git commit -m "Verify menu activation and completion-notification flow" --allow-empty
```

---

## Self-review

**Spec coverage:**
- Auto-activate (any pick incl. Indefinite) → Task 3 `changeDuration` + Task 5 Steps 2/6. ✓
- Green dot via pre-colored icon (not `foregroundStyle`) → Task 4 `statusDot`. ✓
- Black countdown via clickable item → Task 4 Button. ✓
- Completion notification, timed-only, Extend 1 hour → Tasks 2/3, Task 5 Step 5. ✓
- No notify on user Stop / restart (runToken + stoppedByUser) → Task 1 logic + Task 3 wiring + Task 5 Steps 3/4. ✓
- Extend sets duration to 1 hour → Task 3 `extendOneHour` + Task 5 Step 5. ✓
- Ad-hoc delivery risk verified early → Task 2 Step 4. ✓
- Slow-expiry testing via temporary short timer → Task 5 Step 5. ✓

**Placeholder scan:** none — all steps show concrete code/commands.

**Type consistency:** `shouldNotifyOnCompletion(terminatedToken:currentToken:stoppedByUser:duration:)`, `handleTermination(token:)`, `postCompletion(duration:)`, `requestAuthorization()`, `onExtend`, `extendOneHour()`, `statusDot(active:)` are used identically across tasks. ✓

**Known visual uncertainty:** The green dot uses a non-template `NSImage`, which should render in color in the native menu. If Task 5 Step 2 shows a monochrome dot, the fallback is to prefix the status `Text` with a 🟢/⚪ emoji (guaranteed color) — noted here because the user prefers no emojis, so the NSImage approach is tried first.
