# NoSleep code review — 2026-09-10
Whole-repository review at commit `f3547fe` (v1.1.0).

**Status (2026-09-11):** every finding in sections 1 and 2 (bugs) was fixed in v1.2.0 — commits `dea3f84` and `8b1025d` — after two further adversarial verification passes over the fixes themselves. Sections 3–6 (improvements, tests, docs) remain open; the docs items partly landed with the 1.2.0 README and article updates. Produced by a multi-agent workflow: 10 lens-specific finders, root-cause dedup, three-lens adversarial verification (reproduce / skeptic / impact) for every bug and every medium-severity item, a single reproduce-and-judge verifier for low-severity improvements, and a completeness critic that drove two further targeted rounds.
| | |
|---|---|
| Rounds | 3 |
| Raw findings | 132 |
| Root-cause clusters verified | 78 |
| Confirmed | 71 |
| Refuted | 7 |
| Agents | 181 |

Baseline: `swift build` and `swift test` pass (5 tests) on Swift 6.3.3 / macOS 27. Verifiers experimented in temporary copies of the repo; the repository itself was not modified.

**Votes** column: each verifier lens and whether it upheld (`ok`) or refuted (`REFUTE`) the finding, with its confidence. Items with a dissenting vote are still reported but should be read with that dissent in mind.

## Summary of what to fix first

1. **First-launch default is Indefinite, not 4 hours** (`CaffeinateManager.swift:83`). `integer(forKey:)` returns 0 for a missing key and 0 is `.indefinite`.
2. **caffeinate child is orphaned on crash / force-quit / kill** (`CaffeinateManager.swift:113`). Add `-w <own pid>`; verified to compose with `-t`.
3. **Countdown timer never fires while the menu is open and drifts permanently** (`CaffeinateManager.swift:139`). Schedule in `.common` mode and compute remaining time from a deadline instead of decrementing.
4. **1 Hz `@Published` tick costs ~2 % CPU with the menu closed** (`CaffeinateManager.swift:179`, `NoSleepApp.swift:23`). Publish only when the visible string changes, and migrate to `@Observable`.
5. **`CaffeinateManager()` aborts the process outside an .app bundle** (`CaffeinateManager.swift:85`), so `swift run` crashes and no test can construct the manager.
6. **Stale “Extend 1 hour” notification kills the current session** (`CaffeinateManager.swift:168`). Clear delivered notifications on stop and guard `extendOneHour()` on `!isActive`.
7. **Start at Login bakes an absolute path and mirrors plist existence, not launchd/BTM state** (`LoginItemManager.swift`). Replace with `SMAppService.mainApp`.
8. **DMG script hard-codes `/Volumes/NoSleep` and detaches once with no retry** (`package-dmg.sh:48,94`). Capture the device node from `hdiutil attach` and retry detach on EBUSY.

## 1. Bugs in the app (Swift)

### Fresh install defaults to Indefinite, not 4 hours: integer(forKey:) returns 0 == .indefinite, so `?? .fourHours` is dead code

- **Location:** `Sources/NoSleep/CaffeinateManager.swift:83`
- **Severity / category:** medium / bug
- **Votes:** reproduce:ok(0.95), skeptic:ok(0.92), impact:ok(0.9)

**What is wrong.** `UserDefaults.standard.integer(forKey: "selectedDuration")` returns 0 when the key is absent, and `SleepDuration.indefinite.rawValue == 0`, so `SleepDuration(rawValue: 0)` succeeds and yields `.indefinite`; the `?? .fourHours` fallback is unreachable except for a corrupted value. Verified empirically by multiple reviewers (fresh `UserDefaults(suiteName:)` -> `integer(forKey:)` = 0 -> `.indefinite`; a probe build under a never-used bundle id rendered 'Active — ∞ left' with no duration ever selected). The code and plan (line 315) both express a 4-hour intent; the actual default is the one preset with no `-t`, no countdown and no completion notification, and the first thing a new user sees is the awkward '∞ left' status. The manager also reads/writes the process-global `UserDefaults.standard` (lines 54, 82), so in the xctest host any test that sets `selectedDuration` would leak into the `com.apple.dt.xctest.tool` domain on the developer's machine.

**How it fails.** First launch on a clean machine (or after the README's uninstall step `defaults delete com.nosleep.app`): menu shows 'Indefinite' selected instead of '4 hours'; user clicks Start (or the status line) -> `caffeinate -d -i` runs with no `-t`; the Mac never idle-sleeps (laptop battery drains) until the user notices the ∞ status and stops it, and no completion notification can ever fire.

**Suggested fix.**

File: Sources/NoSleep/CaffeinateManager.swift

1) Replace lines 52-56 (the @Published property) and add the key + injected store:

    @Published var selectedDuration: SleepDuration {
        didSet {
            defaults.set(selectedDuration.rawValue, forKey: Self.durationKey)
        }
    }

    // `nonisolated` is required: a plain `static let` on a @MainActor class is
    // main-actor-isolated and cannot be referenced from XCTest methods in Swift 6.
    nonisolated static let durationKey = "selectedDuration"
    private let defaults: UserDefaults

2) Replace lines 81-86 (init) with a pure decoder + injected-defaults init (same pattern as the existing `shouldNotifyOnCompletion`):

    /// Pure decision: the duration to restore from a stored raw value.
    /// `nil` = key never written (fresh install) -> 4 hours.
    /// Do NOT use `integer(forKey:)` here: it returns 0 for a missing key and
    /// 0 is `.indefinite`, which silently made Indefinite the first-run default.
    nonisolated static func restoredDuration(from stored: Int?) -> SleepDuration {
        guard let stored, let saved = SleepDuration(rawValue: stored) else { return .fourHours }
        return saved
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selectedDuration = Self.restoredDuration(
            from: defaults.object(forKey: Self.durationKey) as? Int)
        notifications.onExtend = { [weak self] in self?.extendOneHour() }
        notifications.requestAuthorization()
    }

(NoSleepApp.swift:23 `CaffeinateManager()` keeps compiling via the default argument. Existing users are unaffected: a stored 0 still decodes to .indefinite, stored 900/1800/.../36000 decode unchanged; no on-disk format change.)

Absolute-minimum alternative if you want a 2-line patch only (lines 82-83):
    let saved = UserDefaults.standard.object(forKey: "selectedDuration") as? Int
    self.selectedDuration = saved.flatMap(SleepDuration.init(rawValue:)) ?? .fourHours

3) Add Tests/NoSleepTests/DurationPersistenceTests.swift. IMPORTANT: do not construct `CaffeinateManager` in tests — `init` calls `notifications.requestAuthorization()` -> `UNUserNotificationCenter.current()`, which aborts the xctest host (no app bundle, "bundleProxyForCurrentProcess is nil", signal 6). Test the pure decoder instead:

    import XCTest
    @testable import NoSleep

    final class DurationPersistenceTests: XCTestCase {
        func testMissingKeyDefaultsToFourHours() {
            XCTAssertEqual(CaffeinateManager.restoredDuration(from: nil), .fourHours)   // fails on today's code path
        }
        func testExplicitZeroIsIndefinite() {
            XCTAssertEqual(CaffeinateManager.restoredDuration(from: 0), .indefinite)
        }
        func testValidSavedValueIsRestored() {
            XCTAssertEqual(CaffeinateManager.restoredDuration(from: 1800), .thirtyMin)
        }
        func testUnknownSavedValueFallsBackToFourHours() {
            XCTAssertEqual(CaffeinateManager.restoredDuration(from: 1234), .fourHours)
        }
        /// Pins the trap that caused the bug: a fresh suite reads 0 via integer(forKey:) but nil via object(forKey:).
        func testFreshDefaultsSuiteYieldsNilNotZero() {
            let suite = "NoSleepTests.\(UUID().uuidString)"
            let d = UserDefaults(suiteName: suite)!
            defer { d.removePersistentDomain(forName: suite) }
            XCTAssertEqual(d.integer(forKey: CaffeinateManager.durationKey), 0)
            XCTAssertNil(d.object(forKey: CaffeinateManager.durationKey) as? Int)
            XCTAssertEqual(CaffeinateManager.restoredDuration(
                from: d.object(forKey: CaffeinateManager.durationKey) as? Int), .fourHours)
        }
    }

Verified in a scratch copy: `swift build` clean under Swift 6 language mode, `swift test` = 10 tests, 0 failures.

Avoid: changing `.indefinite` to rawValue -1 (would silently migrate existing Indefinite users to 4 hours). `register(defaults:)` is acceptable but order-dependent and process-global; the explicit decode above is clearer. Optionally (separate UX item, not needed for this bug) label the Start button "Start (\(manager.selectedDuration.label))" in MenuBarView.swift:49 so the duration that will be used is visible before pressing it.

---

### caffeinate child is orphaned when NoSleep dies any way other than the Quit menu item; add `-w <own pid>`

- **Location:** `Sources/NoSleep/CaffeinateManager.swift:113`
- **Severity / category:** medium / bug
- **Votes:** reproduce:ok(0.97), skeptic:ok(0.95), impact:ok(0.9)

**What is wrong.** The child is spawned with only `-d -i [-t N]` and the sole teardown path is `stop()`, reached from `cleanup()` on the 'Quit NoSleep' button (MenuBarView.swift:92-95). There is no `NSApplication.willTerminateNotification`/`applicationWillTerminate` hook, `Process` puts the child in its own process group, and macOS does not kill children on parent death. Verified: a Swift parent that launches `/usr/bin/caffeinate -d -i -t 60` via `Process` and is then SIGKILLed leaves caffeinate running with PPID 1. So a crash (including the bundle-less NSException in F1), Force Quit / Cmd-Opt-Esc, Activity Monitor Quit, `kill`/`pkill -x NoSleep` (which the plan itself instructs), AppleScript `quit`, or a SIGTERM at logout all leave `caffeinate -d -i` holding its IOPM assertions with no UI attached — for Indefinite, until logout. README.md:145 promises 'When you quit NoSleep ... the caffeinate process is terminated', which is false for these paths. On relaunch (or via the LaunchAgent at next login) the new instance shows 'Inactive' while the orphan still holds the assertion, and Start spawns a second caffeinate. `man caffeinate` documents `-w pid` ('Waits for the process with the specified pid to exit. Once the process exits, the assertion is also released'); several reviewers verified `-w` composes with `-t` on this machine: `-t 2 -w <alive pid>` exits at ~2.1 s, `-t 30 -w <pid that exits at 1 s>` exits at ~1.0 s, and `-w <parent>` exits within ~1 s of the parent being SIGKILLed — so the existing terminationHandler/natural-expiry logic is unaffected.

**How it fails.** User selects Indefinite (icon fills). Later NoSleep crashes or is Force Quit from Activity Monitor. The cup icon disappears but `pgrep caffeinate` still shows the child; the display and system never sleep until the user finds and kills it by hand or reboots. With Start at Login enabled, the next login starts a fresh NoSleep showing 'Inactive' while the old caffeinate still keeps the Mac awake.

**Suggested fix.**

Sources/NoSleep/CaffeinateManager.swift:113 — replace
    var args = ["-d", "-i"]
with
    // -w <own pid>: caffeinate releases its assertions and exits as soon as
    // NoSleep's process disappears for ANY reason (crash, Force Quit, kill,
    // AppleScript quit, logout), so the child can never be orphaned.
    // -t still applies; whichever of -t / -w fires first ends the session.
    var args = ["-d", "-i", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
Leave the rest of start() (optional -t append at :114-119), stop()'s explicit proc.terminate() at :151-153 (still needed for immediate release on Stop/Quit and on restart in changeDuration/extendOneHour), the terminationHandler/handleTermination logic, and the Quit button's cleanup() call unchanged — none of them are affected. No NSApplicationDelegateAdaptor/applicationWillTerminate is needed; -w covers every graceful and ungraceful exit path. Verified: builds under Swift 6 strict concurrency and all 5 tests pass with this exact change.

README.md ~:141-145 ('How It Works'): add a bullet `- \`-w <NoSleep pid>\` — caffeinate exits on its own if NoSleep exits for any reason (crash, Force Quit, kill), so it is never left running without the app` so the existing sentence at :145 ('When you quit NoSleep ... the caffeinate process is terminated') becomes accurate.

Optional (adds test coverage for this bug): extract argument construction into `nonisolated static func caffeinateArguments(for duration: SleepDuration, ownPID: Int32) -> [String]` in CaffeinateManager, call it from start(), and add an XCTest in Tests/NoSleepTests/CaffeinateManagerTests.swift asserting the result contains ["-w", "\(pid)"] for every SleepDuration and contains/omits "-t" for timed/indefinite respectively.

---

### Countdown is a decremented counter on a .default-mode Timer: frozen while the menu is open, permanently drifts from caffeinate's real deadline

- **Location:** `Sources/NoSleep/CaffeinateManager.swift:139`
- **Severity / category:** medium / bug
- **Votes:** reproduce:ok(0.95), skeptic:ok(0.9), impact:ok(0.85)

**What is wrong.** `Timer.scheduledTimer(withTimeInterval:repeats:block:)` registers only in `RunLoop.Mode.default`. The `.menu`-style MenuBarExtra is an NSMenu; while it is tracking, the main run loop runs in `NSEventTrackingRunLoopMode`, so the timer does not fire — exactly when the user is looking at the countdown (README advertises 'Live countdown'). Verified empirically by multiple reviewers: in an AppKit process, over 1-2.5 s of `.eventTracking`/menu tracking a .default-mode 100 ms timer fired 0 times while a `.common`-mode timer fired 10-25 times; a probe also confirmed SwiftUI DOES live-update the open NSMenuItem title when state changes, so the freeze is purely the timer mode. Because `tick()` does `remainingSeconds -= 1` per fire and a repeating NSTimer coalesces all missed intervals into one late fire, every second the menu is held open (or any main-thread stall) is lost forever, so the display runs ahead of caffeinate's `-t` deadline for the rest of the session and then jumps straight to Inactive. The same counter design cannot resynchronise after system sleep (lid close is not prevented by `-d -i`). Clock-choice evidence: `nm /usr/bin/caffeinate` shows `-t` uses dispatch_after/mach_absolute_time (does not advance while asleep) and no dispatch_walltime, so a `Date()` deadline would undercount after a lid-close sleep, whereas `ProcessInfo.processInfo.systemUptime` shares caffeinate's semantics. `tick()` and `handleTermination` are also `private`, so the boundary logic at lines 177-184 has no tests (see F11/F12). The `Task { @MainActor }` hop inside the block is unnecessary (the timer already fires on the main thread) and adds a queue turn during which a stale tick can land on a freshly restarted session.

**How it fails.** Start a 15-minute session, open the menu and read it for 20-40 s: the text stays at e.g. 'Active — 14m 40s left' the whole time. Close it: the counter is now 20-40 s behind reality. Repeat a few times during the session and at the real 15:00 mark caffeinate exits and the completion notification arrives while the menu still says 'Active — 1m 30s left', then flips to Inactive without ever passing through 0. Laptop lid closed for 30 minutes mid-session: on wake the counter has fired once and lost ~30 minutes of ticks.

**Suggested fix.**

All edits in Sources/NoSleep/CaffeinateManager.swift plus one new test file. No changes to MenuBarView/NoSleepApp needed.

1) After line 78 (`private var activeDuration: SleepDuration?`) add the deadline and a pure helper following the existing shouldNotifyOnCompletion pattern:

    /// Uptime-clock deadline of the current timed session. Same clock as
    /// caffeinate's dispatch_time-based `-t`, so both pause during system sleep.
    private var deadlineUptime: TimeInterval = 0

    /// Pure: whole seconds left until `deadline`, clamped at 0, rounded up so the
    /// display never reads 0 while caffeinate is still running.
    nonisolated static func remainingSeconds(deadline: TimeInterval, now: TimeInterval) -> Int {
        max(0, Int((deadline - now).rounded(.up)))
    }

2) In start(), line 116 (inside `if selectedDuration != .indefinite`), after `remainingSeconds = selectedDuration.rawValue` add:
            deadlineUptime = ProcessInfo.processInfo.systemUptime + Double(selectedDuration.rawValue)

3) Replace lines 139-143 (the Timer.scheduledTimer block) with a common-modes timer and no Task hop:
            // .common so the countdown keeps ticking while the NSMenu is open
            // (menu tracking runs the main run loop in NSEventTrackingRunLoopMode,
            // where .default-mode timers never fire).
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t

4) Replace tick() at lines 177-184 (make it internal so it is callable if ever needed, and recompute from the deadline instead of decrementing so missed fires resynchronise):
    func tick() {
        guard isActive, timer != nil else { return }
        remainingSeconds = Self.remainingSeconds(
            deadline: deadlineUptime, now: ProcessInfo.processInfo.systemUptime)
        if remainingSeconds <= 0 {
            timer?.invalidate()
            timer = nil
        }
    }
(stop()/handleTermination already invalidate the timer and zero remainingSeconds; clearing deadlineUptime there is optional.)

5) Add Tests/NoSleepTests/CountdownTests.swift testing ONLY the pure function (do NOT instantiate CaffeinateManager: its init calls UNUserNotificationCenter.current(), which aborts the xctest bundle with NSInternalInconsistencyException under `swift test`):
    import XCTest
    @testable import NoSleep
    final class CountdownTests: XCTestCase {
        func testElapsed90s()        { XCTAssertEqual(CaffeinateManager.remainingSeconds(deadline: 3600, now: 90), 3510) }
        func testMissedTicksResync() { XCTAssertEqual(CaffeinateManager.remainingSeconds(deadline: 3600, now: 125), 3475) }
        func testFractionRoundsUp()  { XCTAssertEqual(CaffeinateManager.remainingSeconds(deadline: 100, now: 99.2), 1) }
        func testExactDeadlineZero() { XCTAssertEqual(CaffeinateManager.remainingSeconds(deadline: 100, now: 100), 0) }
        func testClampsAtZero()      { XCTAssertEqual(CaffeinateManager.remainingSeconds(deadline: 100, now: 130), 0) }
    }

Verified in a scratch copy: builds with zero warnings under Swift 6 language mode / macOS 14 target; all 10 tests pass. Do not use Date()/CFAbsoluteTime for the deadline (would undercount across lid-close sleep, which caffeinate's dispatch_time deadline excludes). Skip the suggested .onAppear/didWakeNotification hooks: with a .common timer the value is at most 1 s stale when the menu opens and the uptime clock already covers wake. When reporting, drop the "lost 30 minutes after lid close" scenario: the current counter and caffeinate both exclude sleep time and remain within ~1 s of each other; the real, reproducible symptoms are the freeze while the menu is open and the cumulative drift it causes.

---

### 1 Hz @Published tick costs ~2 % CPU all session long with the menu closed

- **Location:** `Sources/NoSleep/CaffeinateManager.swift:179`
- **Severity / category:** medium / bug
- **Votes:** reproduce:ok(0.95), skeptic:ok(0.9), impact:ok(0.85)

**What is wrong.** Every second `tick()` assigns `remainingSeconds` (line 179). Because it is `@Published` on the App-root `@StateObject`, each assignment forces a full MenuBarExtra scene update even though nothing visible changes. Measured on the user's running instance (8 h session, menu closed): steady 1.3–2.1 % CPU, 66–80 context switches/s, 7 min 17 s cumulative CPU over 25 h (the `caffeinate` child used 0.02 s in 5 h 22 m). Reproduced in a temp build: 1.6–2.1 % CPU, ~115 CSW/s. A `sample` profile shows the ~20 ms per tick goes to `MenuBarExtraHost.requestUpdate` → `MenuBarExtraController.updateButton` re-setting the NSStatusBarButton image/title (re-rasterising the SF Symbol), Auto Layout, a CA commit to WindowServer, then AppKit's `-[NSStatusItem _updateReplicants]` re-snapshotting the item in both appearances (34 % of busy samples). `MenuBarView.body`/`statusDot` are only ~5 % of busy samples and no `NSMenu` frames appear, so fixing the dot rasterisation alone will not help. The publish rate is 60x the visible change rate: above 1 h `formattedRemaining` shows `Xh Ym`, so 3 599 of every 3 600 publishes produce an identical string. Controlled variants: timer firing but not publishing → 0.0 % / 1.4 CSW/s; no timer → 0.0 % / 0.15 CSW/s; deadline + publish-on-change → 0.0 % / ~5 CSW/s. The README markets the app as 'lightweight'. Distinct from the already-noted counter-drift issue: this is the CPU cost of publishing, not the correctness of the value. Complementary to F5 (@Observable), which reduces the cost of each remaining publish.

**How it fails.** User picks '8 hours' at 09:00 and closes the menu. From then on the process wakes every second, re-renders the status-bar button, commits to WindowServer and re-snapshots the item, burning ~20 ms CPU/s (~9.6 CPU-minutes over the workday, plus WindowServer recomposites) while the displayed text 'Active — 7h 59m left' does not change for 60 s at a time and is not even on screen. Reproduce: `top -pid $(pgrep -x NoSleep) -stats pid,cpu,csw -s 5 -l 7` during a timed session shows 1.6–2.1 % CPU and ~100 CSW/s; stop the session and it drops to 0.0 %.

**Suggested fix.**

Goal: zero timer wake-ups and zero publishes while the menu is closed (for every duration, not just >1 h), a drift-free countdown that also updates live while the menu is open, and a testable formatter. All changes in Sources/NoSleep/CaffeinateManager.swift unless noted. Verified to build warning-free under Swift 6 and pass tests in a scratch copy.

1. Line 51 — replace the per-second counter with the rendered string, published only on change:
```swift
/// Rendered countdown ("7h 59m", "12m 5s", "9s"); published only when the visible string changes.
@Published private(set) var remainingText = ""
```
2. After line 75 (`private var timer: Timer?`) add:
```swift
private var deadline: Date?                       // wall-clock end of the timed session
private var menuObservers: [NSObjectProtocol] = []
```
3. Lines 88-101 — make `formattedRemaining` derive from the active session and move the h/m/s branches into a pure, unit-testable helper (same pattern as `shouldNotifyOnCompletion`):
```swift
var formattedRemaining: String {
    guard isActive else { return "" }
    if activeDuration == .indefinite { return "∞" }
    return remainingText
}

nonisolated static func format(seconds: Int) -> String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    let s = seconds % 60
    if m > 0 { return "\(m)m \(s)s" }
    return "\(s)s"
}
```
4. In `init()` (after line 85) — run the 1 Hz refresh only while the dropdown is actually open. NSMenu posts these for the MenuBarExtra menu (verified: object is SwiftUI.SwiftUIMenu, begin arrives before items are populated, and the .menu-style item title updates live). Use `queue: nil` so delivery is synchronous on the posting (main) thread — main-queue blocks are starved during menu tracking:
```swift
let nc = NotificationCenter.default
menuObservers = [
    nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] _ in
        MainActor.assumeIsolated { self?.startRefreshTimer() }
    },
    nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { [weak self] _ in
        MainActor.assumeIsolated { self?.stopRefreshTimer() }
    },
]
```
(`import SwiftUI` already re-exports AppKit, so `NSMenu` resolves; add `import AppKit` if you prefer it explicit. The manager is an App-root @StateObject and lives for the process, so no `deinit`/removeObserver is needed.)

5. `start()` lines 114-119: replace `remainingSeconds = selectedDuration.rawValue` with `deadline = Date(timeIntervalSinceNow: TimeInterval(selectedDuration.rawValue))` and `remainingSeconds = 0` with `deadline = nil`. Lines 138-144: delete the `Timer.scheduledTimer { Task { @MainActor ... } }` block and replace it with a single `refreshRemainingText()` (one publish so the text is correct if the menu is re-opened before the first tracking refresh).

6. `stop()` lines 149-150 and 156: replace with `stopRefreshTimer()`, `deadline = nil`, and `if !remainingText.isEmpty { remainingText = "" }` (stop() runs at the top of every start(); the guard avoids a redundant status-item redraw).

7. Lines 177-184 — replace `tick()` with:
```swift
private func startRefreshTimer() {
    guard timer == nil, deadline != nil else { return }
    refreshRemainingText()                            // fresh before SwiftUI populates the items
    let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.refreshRemainingText() }   // synchronous: a Task hop would never run while the menu is tracking
    }
    t.tolerance = 0.1                                 // only runs while the menu is open; keep seconds smooth
    RunLoop.main.add(t, forMode: .common)             // default-mode timers do not fire during NSMenu tracking
    timer = t
}

private func stopRefreshTimer() {
    timer?.invalidate()
    timer = nil
}

private func refreshRemainingText() {
    guard isActive, let deadline else { return }
    let remaining = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
    let text = Self.format(seconds: remaining)
    if text != remainingText { remainingText = text }
    if remaining <= 0 { stopRefreshTimer() }
}
```
8. `handleTermination(token:)` lines 198-202: replace `timer?.invalidate(); timer = nil` with `stopRefreshTimer()`, add `deadline = nil`, and replace `remainingSeconds = 0` with `if !remainingText.isEmpty { remainingText = "" }`. Expiry detection continues to come from `caffeinate -t` + terminationHandler; the timer is purely cosmetic.

9. Tests/NoSleepTests/CaffeinateManagerTests.swift — add:
```swift
func testFormatRemaining() {
    XCTAssertEqual(CaffeinateManager.format(seconds: 28800), "8h 0m")
    XCTAssertEqual(CaffeinateManager.format(seconds: 3600), "1h 0m")
    XCTAssertEqual(CaffeinateManager.format(seconds: 3599), "59m 59s")
    XCTAssertEqual(CaffeinateManager.format(seconds: 65), "1m 5s")
    XCTAssertEqual(CaffeinateManager.format(seconds: 0), "0s")
}
```
No changes needed in MenuBarView.swift or NoSleepApp.swift (`remainingSeconds` has no other readers).

Fallback if you would rather not depend on NSMenu notifications: keep steps 1-3, 5-9 but start the `.common`/`assumeIsolated` timer in `start()` and never stop it until stop()/termination (the original suggestion, with `tolerance = 0.5`). That yields 0 % CPU above 1 h but still ~2 % for the 15 m/30 m presets and the final hour of every session, so the gated version is preferred. Do not gate on `onAppear`/`onDisappear` of the menu content: `.task` on it did not fire at launch in .menu style and close detection is unverified.

Verify: build NoSleep.app, pick "15 minutes" (worst case for the old code), close the menu, run `top -pid $(pgrep -x NoSleep) -stats pid,cpu,csw -s 5 -l 7` — expect 0.0 % CPU and <1 CSW/s (vs ~2 % / ~100 CSW/s before); open the menu and confirm the status line counts down live every second and shows the correct wall-clock remainder after being closed for several minutes. Complementary to F5 (@Observable), which additionally keeps the remaining publishes from redrawing the status item.

---

### App-root @StateObject amplifies every publish into a status-item redraw; migrate to @Observable

- **Location:** `Sources/NoSleep/NoSleepApp.swift:23`
- **Severity / category:** medium / improvement
- **Votes:** reproduce:ok(0.92), skeptic:ok(0.93), impact:ok(0.78)

**What is wrong.** `@StateObject private var caffeinateManager` (NoSleepApp.swift:23) subscribes the whole `App` body to `objectWillChange`, which `ObservableObject` fires for any `@Published` property. So a change to `remainingSeconds` — a value only the (closed) menu content reads — dirties the `MenuBarExtra` scene, and SwiftUI's `MenuBarExtraController.updateButton` unconditionally re-sets the NSStatusBarButton image and title, re-lays out, commits to WindowServer and lets AppKit re-snapshot the item for its replicants, even though `isActive` (the only thing the label reads) is unchanged. Two isolating variants prove the observation granularity is the amplifier, not what the views read: making the label a constant `Image(systemName: "cup.and.saucer.fill")` still costs 1.9–2.0 % CPU, and replacing the menu content with a static `Text` still costs 1.6–1.7 %. Migrating `CaffeinateManager` to the Observation framework (`@Observable`, available since the package's own floor `.macOS(.v14)`) with no other change — still publishing at 1 Hz — drops the process to 0.1 % CPU and ~2 CSW/s, because per-property tracking means the label is only invalidated by `isActive` and the menu content is only tracked while the menu is actually open. Complementary to F1: it makes each remaining publish (start/stop, minute boundaries, Extend) cost one label diff instead of a status-item redraw plus replicant snapshot, and it is the idiomatic model for the deployment target.

**How it fails.** Any `@Published` write on `CaffeinateManager` — `remainingSeconds` each second today, and each `remainingText` change or `isActive`/`selectedDuration` write after a publish-rate fix — triggers `NSStatusBarButton setImage:`/`setTitle:`, Auto Layout, a CoreAnimation commit and two appearance-switching replicant snapshots (~20 ms of main-thread work) although the menu-bar glyph is identical before and after.

**Suggested fix.**

Migrate both model classes to the Observation framework (macOS 14+, the package's own floor). Four files, ~19 lines; no `import Observation` is required (Foundation re-exports it on this SDK — adding it is harmless but unnecessary). No test changes needed.

1) Sources/NoSleep/CaffeinateManager.swift
   lines 48-52: replace
       @MainActor
       final class CaffeinateManager: ObservableObject {
           @Published var isActive = false
           @Published var remainingSeconds: Int = 0
           @Published var selectedDuration: SleepDuration {
   with
       @MainActor
       @Observable
       final class CaffeinateManager {
           var isActive = false
           var remainingSeconds: Int = 0
           var selectedDuration: SleepDuration {
   (keep the existing `didSet` on lines 53-55 unchanged — verified it still fires under @Observable and persists to UserDefaults.)
   lines 74-78: prefix each private field with `@ObservationIgnored` (optional but recommended; nothing observes them):
       @ObservationIgnored private var process: Process?
       @ObservationIgnored private var timer: Timer?
       @ObservationIgnored private var stoppedByUser = false
       @ObservationIgnored private var runToken = 0
       @ObservationIgnored private var activeDuration: SleepDuration?
   line 79 `let notifications = NotificationManager()` stays as-is (lets are never tracked).

2) Sources/NoSleep/LoginItemManager.swift
   lines 21-22: `@MainActor` / `final class LoginItemManager: ObservableObject {`  ->  `@MainActor` / `@Observable` / `final class LoginItemManager {`
   line 25: `@Published var isEnabled: Bool`  ->  `var isEnabled: Bool`

3) Sources/NoSleep/NoSleepApp.swift
   lines 23-24:
       @State private var caffeinateManager = CaffeinateManager()
       @State private var loginManager = LoginItemManager()
   (Apple's documented ObservableObject -> Observable migration for App/Scene roots. Note the object is now created when NoSleepApp is instantiated in main() rather than at first body evaluation; the only effect is that UNUserNotificationCenter's delegate is set marginally earlier, which is the recommended timing.)

4) Sources/NoSleep/MenuBarView.swift
   lines 22-23:
       var manager: CaffeinateManager
       var loginManager: LoginItemManager
   (`@Bindable` is not needed: the Toggle on lines 82-85 already uses a hand-built Binding and there are no `$manager.x` projections.)

Result: the MenuBarExtra label is invalidated only by `isActive`; `remainingSeconds`/`formattedRemaining` are tracked only by the menu content and only while the menu is open, so the 1 Hz tick no longer redraws the NSStatusItem. Verified: Swift 6 strict-mode build (debug and clean universal release as in build.sh) with zero warnings, 5/5 tests green. Keep the publish-rate fix (F1) as well — but note F1 alone cannot eliminate the per-second publish for sessions under 1 h or the final hour of longer ones, because `formattedRemaining` (CaffeinateManager.swift:96-100) intentionally shows seconds in that range; this change is what removes the status-item redraw in those cases.

---

### CaffeinateManager.init() calls UNUserNotificationCenter.current(); aborts swift test hosts and any unbundled run (swift run)

- **Location:** `Sources/NoSleep/CaffeinateManager.swift:85`
- **Severity / category:** medium / bug
- **Votes:** reproduce:ok(0.96), skeptic:ok(0.9), impact:ok(0.85)

**What is wrong.** `init()` unconditionally calls `notifications.requestAuthorization()`, which executes `UNUserNotificationCenter.current()` (NotificationManager.swift:38). Outside a registered .app bundle that raises `NSInternalInconsistencyException: bundleProxyForCurrentProcess is nil` and the process dies with SIGABRT. Verified in temp copies by several reviewers: (a) the bare `.build/debug/NoSleep` / `swift run` exits 134 within a second, before any menu-bar UI appears; (b) a one-line test `@MainActor func test() { _ = CaffeinateManager() }` kills the entire xctest run with signal 6 — even though `Bundle.main.bundleIdentifier` there is `com.apple.dt.xctest.tool`, so a bare `bundleIdentifier != nil` guard would NOT protect tests. This contradicts the doc comment at NotificationManager.swift:31-33 ('Kept out of `init` so the type is safe to construct in unit tests'), the approved spec (design.md:106-110: trigger at launch from NoSleepApp) and the plan (Task 3 init has no call; Task 4 uses `.onAppear`). Consequences: the 5 existing tests only pass because none instantiate the manager; every instance behaviour — first-launch default, `formattedRemaining`, start/stop/toggle/changeDuration/extendOneHour, tick, handleTermination token/stoppedByUser interplay, onExtend wiring — has zero automated coverage. `let notifications = NotificationManager()` (line 79) is also a non-injectable concrete `let`, so a spy cannot be substituted. README (lines 28-36, 54-69) and dev-to-article.md:230 present the project as a plain SPM package and never warn that `swift run` aborts; the spec only recorded the softer 'notifications need a bundle' limitation, which the implementation escalated to a hard crash.

**How it fails.** Developer adds `@MainActor func testStartSetsActive() { let m = CaffeinateManager(); m.start(); XCTAssertTrue(m.isActive) }` -> `swift test` terminates with 'libc++abi: terminating due to uncaught exception of type NSException' before any assertion, taking the other 5 green tests down with it. Separately, a contributor clones the repo and runs `swift run` -> process aborts immediately with the NSException; no menu-bar icon, nothing in README explains why. Any regression in the runToken/stoppedByUser ordering ships undetected because no test can construct the manager.

**Suggested fix.**

Keep launch-time registration (the author moved it into init on purpose; do NOT relocate to `.task`/`.onAppear` on the menu content — that is lazy and can drop the 'Extend 1 hour' response when the app is relaunched from the notification). Make the call safe and injectable instead:

1) Sources/NoSleep/NotificationManager.swift
   - Above the class add the seam:
     ```swift
     @MainActor
     protocol NotificationPosting: AnyObject {
         var onExtend: (() -> Void)? { get set }
         func requestAuthorization()
         func postCompletion(duration: SleepDuration)
     }
     ```
     and declare `final class NotificationManager: NSObject, NotificationPosting, UNUserNotificationCenterDelegate`.
   - Add inside the class:
     ```swift
     /// UNUserNotificationCenter.current() traps ("bundleProxyForCurrentProcess is nil")
     /// unless the process runs from an .app bundle. `swift run`, the bare
     /// .build/… binary and the xctest host are not bundles → no notifications there.
     nonisolated static let isSupported = Bundle.main.bundleURL.pathExtension == "app"
     ```
   - Line 35: `guard Self.isSupported, !didConfigure else { return }`
   - Line 53: first statement of `postCompletion(duration:)`: `guard Self.isSupported else { return }`
   - Lines 31-33: replace the now-false comment with: "Call once at launch. CaffeinateManager.init runs during app launch (via @StateObject), which satisfies the UNUserNotificationCenterDelegate 'before the app finishes launching' requirement. No-op outside an .app bundle, so the type is safe in `swift run` and unit tests."

2) Sources/NoSleep/CaffeinateManager.swift
   - Line 79: `let notifications: any NotificationPosting`
   - Line 81: `init(notifications: any NotificationPosting = NotificationManager()) { self.notifications = notifications; …` keeping lines 82-85 unchanged. (NoSleepApp.swift:23 needs no change — the default argument is used.)
   - Optional, not required: if you prefer zero side effects in init, add `@NSApplicationDelegateAdaptor` and call `requestAuthorization()` from `applicationDidFinishLaunching`; the delegate must then own/receive the NotificationManager instance. Not worth the plumbing for this app.

3) Tests/NoSleepTests/CaffeinateManagerTests.swift — add
   ```swift
   @MainActor final class NotificationSpy: NotificationPosting {
       var onExtend: (() -> Void)?
       var authorizationRequests = 0
       var posted: [SleepDuration] = []
       func requestAuthorization() { authorizationRequests += 1 }
       func postCompletion(duration: SleepDuration) { posted.append(duration) }
   }
   ```
   and `@MainActor` tests: `testInitRequestsAuthorizationOnce` (spy.authorizationRequests == 1, !isActive, formattedRemaining == ""), `testInitWiresExtendToOneHourRestart` (`spy.onExtend?()` → selectedDuration == .oneHour, isActive, formattedRemaining == "1h 0m"; then `cleanup()` → !isActive), and `testDefaultInitDoesNotTrapOutsideBundle` (`CaffeinateManager()` then `notifications.postCompletion(duration: .oneHour)` must not abort). All three verified green in a temp copy alongside the existing 5.

4) README.md 'Build from source' (after line 32) and 'Run' (around line 66): add one line — "Run NoSleep as the bundled `NoSleep.app` (`./build.sh && open NoSleep.app`). `swift run` works for development but notifications are unavailable because the bare binary is not an .app bundle." (Accurate only after step 1; today `swift run` aborts.)

Leave `UserDefaults` injection to the separate F2 finding.

---

### Tapping a stale 'Extend 1 hour' notification kills whatever session is running and replaces it with 1 hour

- **Location:** `Sources/NoSleep/CaffeinateManager.swift:168`
- **Severity / category:** medium / bug
- **Votes:** reproduce:ok(0.88), skeptic:ok(0.8), impact:ok(0.75)

**What is wrong.** `extendOneHour()` unconditionally sets `selectedDuration = .oneHour` and calls `start()`, which `stop()`s the live session. Delivered notifications persist in Notification Center indefinitely and are never removed when a new session starts, so the action can be triggered long after the session it belonged to ended, clobbering whatever the user has started since; the only cue is the radio moving to '1 hour'.

**How it fails.** A 2-hour session ends at 16:00 and the banner sits in Notification Center. At 16:10 the user picks '8 hours' for an overnight task. At 16:30 they tidy Notification Center and click 'Extend 1 hour' on the old NoSleep item -> the 8-hour session is terminated and replaced with a 1-hour one; the Mac sleeps at 17:30 instead of 00:10.

**Suggested fix.**

Three small edits (compile-verified, Swift 6 strict-concurrency clean, 5/5 tests pass):

1) Sources/NoSleep/NotificationManager.swift - add after postCompletion(duration:) (after line 64):

    /// Remove any delivered "session complete" banners from Notification
    /// Center so a stale "Extend 1 hour" action cannot be tapped after a new
    /// session has started (or after the app quit). No-op until configured so
    /// the type stays safe to construct in unit tests.
    func clearDelivered() {
        guard didConfigure else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

2) Sources/NoSleep/CaffeinateManager.swift, stop() (line 147) - insert right after `stoppedByUser = true` (line 148):

        // Any earlier "session ended" notification is now moot; drop it so its
        // "Extend 1 hour" action can't later replace a newer session.
        notifications.clearDelivered()

   Placing it in stop() covers every transition with one call site: start() (line 104) calls stop() first, user Stop, and cleanup() on Quit.

3) Sources/NoSleep/CaffeinateManager.swift, extendOneHour() (line 168) - add a guard as first statement:

    func extendOneHour() {
        // Honour the action only for the session it announced: if a newer
        // session is already running, a stale notification must not replace it.
        guard !isActive else { return }
        selectedDuration = .oneHour
        start()
    }

Rationale for the shape: keeps all UserNotifications code inside NotificationManager (spec architecture); `didConfigure` guard means tests can construct the manager once F1/F11 make init() test-safe; `removeAllDeliveredNotifications()` is sufficient because the app posts exactly one category with a nil trigger (no pending requests to clear); the isActive guard is defense in depth against the async XPC removal race. Do NOT make extend additive (contradicts the approved spec and the enum-based radio/formattedRemaining) and do not bother with userInfo token stamping (more code, no extra safety). Follow-up once the manager is constructible in tests (F1/F11): a test that sets up an active session, calls extendOneHour(), and asserts selectedDuration and runToken are unchanged.

---

### LaunchAgent bakes the current executable path at enable time; breaks silently for moved/DMG/translocated bundles — use SMAppService.mainApp

- **Location:** `Sources/NoSleep/LoginItemManager.swift:51`
- **Severity / category:** medium / bug
- **Votes:** reproduce:ok(0.9), skeptic:ok(0.9), impact:ok(0.9)

**What is wrong.** `enable()` writes `~/Library/LaunchAgents/com.nosleep.app.plist` with `ProgramArguments[0] = Bundle.main.executablePath` at the moment the toggle is flipped, and `isEnabled` is derived solely from the plist file's existence (line 35). That path is wrong for the most common first-run flows: running from the mounted DMG (`/Volumes/NoSleep/...`), a still-quarantined copy in ~/Downloads (Gatekeeper App Translocation yields a random read-only `/private/var/folders/.../AppTranslocation/<UUID>/d/NoSleep.app`), the build directory, or any later move/rename. `install.sh` even carries a PlistBuddy patch (lines 21-27) to repair one of these cases, and the DMG install path — the recommended one — has no equivalent. The toggle also stays ON if the user disables the item in System Settings > Login Items ('Allow in the Background'), which does not delete the plist. The plist lacks `AssociatedBundleIdentifiers` (`man launchd.plist` says legacy plists installed by an app should include it), so the Login Items UI cannot attribute it to NoSleep, and a raw LaunchAgent triggers the 'Background Items Added' alert. The project targets macOS 14; `SMAppService.mainApp` (ServiceManagement, macOS 13+, verified in the SDK header) tracks the bundle by identity, appears under 'Open at Login' with the app icon, reports a truthful `status` (`.enabled/.notRegistered/.requiresApproval/.notFound`), works for ad-hoc-signed bundles and needs no sandbox — the dev-to article's stated reason for avoiding it is wrong (see F24).

**How it fails.** User opens the DMG, double-clicks NoSleep to try it, enables Start at Login, then drags it to /Applications and ejects the DMG. Next login: launchd logs 'Could not find and/or execute program' for `/Volumes/NoSleep/NoSleep.app/Contents/MacOS/NoSleep`, NoSleep does not start, yet the menu toggle still shows Start at Login enabled because the plist exists. Same for a developer whose plist points at ~/projects/git/nosleep/NoSleep.app after they install the DMG and delete the build.

**Suggested fix.**

1) Replace Sources/NoSleep/LoginItemManager.swift body (lines 19-71) with an SMAppService-backed implementation (compiles clean in Swift 6 mode; verified):

```swift
import Foundation
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var requiresApproval: Bool = false
    @Published private(set) var lastError: String?

    private let service = SMAppService.mainApp

    /// Plist written by NoSleep <= 1.1.0; removed on first launch of the new version.
    private let legacyPlistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.nosleep.app.plist")

    init() {
        migrateLegacyPlistIfNeeded()
        refresh()
    }

    /// Re-read the system's view. Called at launch and after toggle(); also call when the menu opens.
    func refresh() {
        let status = service.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    func toggle() {
        lastError = nil
        do {
            switch service.status {
            case .enabled, .requiresApproval:
                try service.unregister()
            default:
                guard Self.isRunningFromInstallableLocation else {
                    lastError = "Move NoSleep to the Applications folder first."
                    break
                }
                try service.register()
            }
        } catch {
            if service.status == .requiresApproval {
                // register() throws kSMErrorLaunchDeniedByUser when the user turned
                // NoSleep off in System Settings > Login Items; send them there.
                SMAppService.openSystemSettingsLoginItems()
            } else {
                lastError = error.localizedDescription
            }
        }
        refresh()
    }

    /// False when running from a mounted disk image, a Gatekeeper-translocated copy,
    /// or a bare executable (swift run) — none of those paths exist at next login.
    private static var isRunningFromInstallableLocation: Bool {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app"
            && !url.path.hasPrefix("/Volumes/")
            && !url.path.contains("/AppTranslocation/")
    }

    private func migrateLegacyPlistIfNeeded() {
        guard FileManager.default.fileExists(atPath: legacyPlistURL.path) else { return }
        try? FileManager.default.removeItem(at: legacyPlistURL)
        try? service.register()   // preserve the user's earlier "Start at Login" choice
    }
}
```
(The legacy plist is RunAtLoad-only with KeepAlive=false, so deleting the file is sufficient; no `launchctl bootout` needed.)

2) Sources/NoSleep/MenuBarView.swift lines 82-87: keep the Toggle binding as is (it only reads isEnabled and calls toggle()); optionally surface state below it:
```swift
if loginManager.requiresApproval {
    Text("Blocked in System Settings > Login Items").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
} else if let err = loginManager.lastError {
    Text(err).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
}
```
and add `.onAppear { loginManager.refresh() }` on the outer VStack as a best-effort refresh when the menu opens (untested whether .menu-style MenuBarExtra fires it per open; status is refreshed at launch and after every toggle regardless).

3) install.sh: delete lines 8 and 21-27 (the PLIST_PATH variable and the PlistBuddy repair block) — the location is no longer baked in.

4) README.md: line 45 and 75 — "Start at Login — registers NoSleep as a Login Item (System Settings > General > Login Items)"; line 86 — drop "and updates the LaunchAgent path if Start at Login is enabled"; lines 107-108 in Uninstall — replace with "Turn off Start at Login in the menu (or System Settings > General > Login Items) before deleting the app; if you upgraded from 1.1.0 or earlier also `rm -f ~/Library/LaunchAgents/com.nosleep.app.plist`"; line 124 comment — "SMAppService login item". dev-to-article.md lines 19 and 131-151: replace the LaunchAgent section and the incorrect "requires a sandboxed app" claim (coordinate with F24).

5) Only if the raw plist must be kept (not recommended): in LoginItemManager.swift enable() add `"AssociatedBundleIdentifiers": "com.nosleep.app"` to the dict at lines 49-54 per man launchd.plist, refuse to write when `isRunningFromInstallableLocation` is false, and derive isEnabled from `SMAppService.statusForLegacyPlist(at: plistURL) == .enabled` instead of file existence (line 35) so the toggle reflects a System Settings denial.

---

### 'Start at Login' is modeled as a Bool from plist existence, not BTM/launchd state; can get stuck checked-but-off and cannot show 'requires approval'

- **Location:** `Sources/NoSleep/LoginItemManager.swift:35`
- **Severity / category:** medium / bug
- **Votes:** reproduce:ok(0.85), skeptic:ok(0.8), impact:ok(0.8)

**What is wrong.** `isEnabled` is set once in `init()` (line 35) to `fileExists(~/Library/LaunchAgents/com.nosleep.app.plist)` and is only ever mutated by the app's own enable()/disable(). On macOS 13+ the authoritative switch is Background Task Management: System Settings > General > Login Items & Extensions > 'Allow in the Background'. Turning NoSleep off there does `launchctl disable gui/<uid>/com.nosleep.app`, which per launchctl(1) 'persists across boots' and 'cannot be loaded ... until it is once again enabled' — the plist is left on disk. The app never consults `launchctl print`/`print-disabled` or `SMAppService.mainApp.status` (verified on this machine to be the real truth source: `state = running`, `type = LaunchAgent`, with a BTM-attached LWCR). Because BTM's disable is keyed by label, toggle() (remove plist, then rewrite an identical plist) cannot re-enable it. The snapshot is also never refreshed, so any external change (System Settings, the README's `rm -f` uninstall step, install.sh) is invisible until relaunch. The UI compounds this: MenuBarView.swift:82-85 renders a two-state Toggle whose `set:` closure discards the requested value and just calls `toggle()`. Under BTM there is a third, common state — registered but not allowed (SMAppService `.requiresApproval`: user previously switched it off in System Settings, MDM-managed Macs, or the 'Background Items Added' alert dismissed and later disabled). Nothing in the UI can show this and there is no affordance to open the relevant System Settings pane, although Apple provides `SMAppService.openSystemSettingsLoginItems()` precisely for this.

**How it fails.** User enables Start at Login in the menu, later flips NoSleep off under 'Allow in the Background' in System Settings, logs out and back in. NoSleep does not launch. User opens NoSleep manually: the menu still shows 'Start at Login' checked. Clicking it unchecks (deletes plist); clicking again re-checks (rewrites plist) — but launchd's disabled state for com.nosleep.app persists, so it still never launches at login while the UI claims it will. The Toggle renders either checked (misleading: it will not launch) or unchecked (misleading: clicking appears broken), and the user cannot discover that approval in System Settings > General > Login Items & Extensions is required. There is no in-app path out of this state.

**Suggested fix.**

1) Rewrite Sources/NoSleep/LoginItemManager.swift (whole file body after the license header) to use SMAppService.mainApp as the single source of truth, refreshed on every menu open, with a bootout-free migration (this exact code compiled warning-free in Swift 6 mode and tests pass):

```swift
import AppKit
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    /// Authoritative Background Task Management state (what System Settings shows).
    @Published private(set) var status: SMAppService.Status = .notRegistered

    /// Checked in the menu when registered, even if the user still has to approve it.
    var isRegistered: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    private let legacyPlistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.nosleep.app.plist")
    private var menuObserver: NSObjectProtocol?

    init() {
        migrateLegacyLaunchAgentIfNeeded()
        refresh()
        // .menu-style MenuBarExtra is an NSMenu: re-read BTM state each time it opens so
        // changes made in System Settings (or a moved/deleted bundle) are reflected.
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        do {
            switch (enabled, status) {
            case (true, .requiresApproval):
                SMAppService.openSystemSettingsLoginItems()   // register() cannot override the user's choice
            case (true, _):
                try SMAppService.mainApp.register()
            case (false, _):
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LoginItemManager: %@ failed: %@", enabled ? "register" : "unregister",
                  String(describing: error))
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// v1.1.0 and earlier wrote ~/Library/LaunchAgents/com.nosleep.app.plist. Remove it so launchd
    /// and BTM never both start the app, carrying the user's choice over. Do NOT `launchctl bootout`:
    /// when the app was started by that agent this process *is* the job and bootout would kill it.
    private func migrateLegacyLaunchAgentIfNeeded() {
        guard FileManager.default.fileExists(atPath: legacyPlistURL.path) else { return }
        let legacyStatus = SMAppService.statusForLegacyPlist(at: legacyPlistURL)
        try? FileManager.default.removeItem(at: legacyPlistURL)
        if legacyStatus == .enabled, Bundle.main.bundleIdentifier != nil {   // skip under `swift run`
            try? SMAppService.mainApp.register()
        }
    }
}
```
Notes: `SMAppService.mainApp.status` is safe unbundled (returns `.notFound`), so only `register()` needs the bundle guard. Do not refresh from the Binding getter (publishing during view update). Keep `isEnabled` out of the API to force call sites to use `status`.

2) Sources/NoSleep/MenuBarView.swift:81-87 — honor the requested value and surface the approval state:
```swift
// Start at Login — mirrors System Settings > General > Login Items & Extensions
Toggle("Start at Login", isOn: Binding(
    get: { loginManager.isRegistered },
    set: { loginManager.setEnabled($0) }
))
.padding(.horizontal, 8)
.padding(.vertical, 2)

if loginManager.requiresApproval {
    Button("Needs approval — Open Login Items Settings…") {
        loginManager.openSystemSettings()
    }
    .padding(.horizontal, 4)
}
```

3) Housekeeping so docs/scripts stop referencing the legacy plist: install.sh — delete `PLIST_PATH` (line 8) and the PlistBuddy block (lines 21-27; BTM tracks the bundle, and reinstalling into the same ~/Applications path keeps the registration). README.md:45,75,86 — say "Start at Login (macOS Login Item; manage it under System Settings > General > Login Items & Extensions)"; README.md:101-108 — replace `rm -f ~/Library/LaunchAgents/com.nosleep.app.plist` with "turn off Start at Login in the menu (or remove NoSleep under System Settings > General > Login Items) before deleting the app". dev-to-article.md:131-151 — remove the incorrect claim that SMAppService requires sandboxing (it requires code signing; ad-hoc is fine).

4) Caveat to document in the commit: BTM keys login items to code identity; with ad-hoc signing (cdhash-based requirement, no Team ID) a rebuilt/updated app may show `.notFound`/`.notRegistered` until the user re-enables — the status-driven UI now reports that honestly instead of a stale checkmark.

Minimal alternative (if the LaunchAgent must stay): keep the plist code but replace LoginItemManager.swift:35 with `self.status = SMAppService.statusForLegacyPlist(at: url)` (verified: .enabled when present/allowed, .notRegistered when absent, .requiresApproval when turned off in System Settings), add the same NSMenu.didBeginTrackingNotification refresh, and the same `requiresApproval` button in MenuBarView. ~25 lines, no migration, but keeps the fragile absolute executable path and the non-LaunchServices launch.

---

### terminationHandler ignores terminationReason/status; an external kill of caffeinate posts 'Your N session has ended' and an Indefinite kill is silent

- **Location:** `Sources/NoSleep/CaffeinateManager.swift:123`
- **Severity / category:** low / bug
- **Votes:** reproduce:ok(0.92), skeptic:ok(0.6), impact:ok(0.8)

**What is wrong.** The `terminationHandler` discards the `Process` argument (`_`), so `handleTermination` treats any termination of the current run not preceded by `stop()` as natural expiry. Foundation exposes the distinction directly and it was verified on this machine: natural `-t` expiry -> `terminationReason == .exit`, `terminationStatus == 0`; `terminate()`/SIGTERM -> `.uncaughtSignal`/15; SIGKILL -> `.uncaughtSignal`/9. The spec (line 51) says the notification fires 'only on natural expiry of a timed session'. Consequences: (1) `killall caffeinate`, a cleanup script, another power tool, an OOM kill or caffeinate exiting non-zero right after launch all pass the token/stoppedByUser/duration checks and post 'Your 4 hours session has ended.' with an Extend button; (2) an Indefinite session killed externally just flips to 'Inactive' with no notification, though that is exactly when the user relies on the assertion. Reading the reason also makes `stoppedByUser` largely redundant (the SIGTERM from `stop()` is already distinguishable), reducing cross-thread state. `Process` is not Sendable, so the reason/status must be read inside the handler before the `Task { @MainActor }` hop.

**How it fails.** User starts a 2-hour session at 14:00; a script or another utility runs `pkill caffeinate` at 14:05 -> banner 'Your 2 hours session has ended.' The user concludes the timer was wrong. Alternatively: Indefinite for an overnight download, caffeinate killed -> no banner, the cup icon quietly goes hollow, the Mac sleeps mid-download.

**Suggested fix.**

All paths relative to <repo>. Verified to compile with zero warnings under Swift 6 strict concurrency and pass 10/10 tests.

1) Sources/NoSleep/CaffeinateManager.swift L62-72 -- add an `exitedNormally` input to the pure decision and a sibling decision for the unexpected-stop case:

    nonisolated static func shouldNotifyOnCompletion(
        terminatedToken: Int,
        currentToken: Int,
        stoppedByUser: Bool,
        exitedNormally: Bool,
        duration: SleepDuration?
    ) -> Bool {
        guard terminatedToken == currentToken else { return false }
        guard !stoppedByUser else { return false }
        guard exitedNormally else { return false }
        guard let duration, duration != .indefinite else { return false }
        return true
    }

    /// caffeinate died for the current run without the user pressing Stop and
    /// without a clean exit (e.g. `killall caffeinate`). Timed or indefinite.
    nonisolated static func shouldNotifyUnexpectedStop(
        terminatedToken: Int,
        currentToken: Int,
        stoppedByUser: Bool,
        exitedNormally: Bool
    ) -> Bool {
        guard terminatedToken == currentToken else { return false }
        guard !stoppedByUser else { return false }
        return !exitedNormally
    }

2) Sources/NoSleep/CaffeinateManager.swift L123-127 -- read the outcome on the handler's thread (Process is not Sendable) and pass only a Bool across the hop:

        proc.terminationHandler = { [weak self] p in
            let exitedNormally = p.terminationReason == .exit && p.terminationStatus == 0
            Task { @MainActor [weak self] in
                self?.handleTermination(token: token, exitedNormally: exitedNormally)
            }
        }

3) Sources/NoSleep/CaffeinateManager.swift L186-209 -- `private func handleTermination(token: Int, exitedNormally: Bool)`; pass `exitedNormally: exitedNormally` into shouldNotifyOnCompletion; compute `let unexpected = Self.shouldNotifyUnexpectedStop(terminatedToken: token, currentToken: runToken, stoppedByUser: stoppedByUser, exitedNormally: exitedNormally)` BEFORE the state reset (stoppedByUser is cleared there); then replace the tail with:

        if notifiable, let completed {
            notifications.postCompletion(duration: completed)
        } else if unexpected {
            notifications.postUnexpectedStop()
        }

   Keep `stoppedByUser`: stop()'s SIGTERM is indistinguishable by reason/status from an external `pkill caffeinate`, so it is the only thing that suppresses the unexpected-stop banner on a user Stop / Quit. (Optional larger refactor: bump runToken in stop() so its own handler goes stale, then delete stoppedByUser.)

4) Sources/NoSleep/NotificationManager.swift, after L64 -- add:

    func postUnexpectedStop() {
        let content = UNMutableNotificationContent()
        content.title = "NoSleep"
        content.body = "NoSleep stopped unexpectedly — your Mac can sleep again."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

   (No category/action: 'Extend 1 hour' reads wrong for an Indefinite session; the user re-picks a duration from the menu.)

5) Tests/NoSleepTests/CaffeinateManagerTests.swift -- add `exitedNormally: true` to the 4 natural-expiry rows (L24-25, L34-35, L39-40, L44-45) and `exitedNormally: false` to the stoppedByUser row (L29-30); add:

    func testNoNotifyWhenKilledExternally() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: false, exitedNormally: false, duration: .twoHours))
    }
    func testUnexpectedStopWhenKilledExternally() {
        XCTAssertTrue(CaffeinateManager.shouldNotifyUnexpectedStop(
            terminatedToken: 1, currentToken: 1, stoppedByUser: false, exitedNormally: false))
    }
    func testNoUnexpectedStopWhenStoppedByUser() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyUnexpectedStop(
            terminatedToken: 1, currentToken: 1, stoppedByUser: true, exitedNormally: false))
    }
    func testNoUnexpectedStopOnNaturalExpiry() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyUnexpectedStop(
            terminatedToken: 1, currentToken: 1, stoppedByUser: false, exitedNormally: true))
    }
    func testNoUnexpectedStopOnStaleToken() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyUnexpectedStop(
            terminatedToken: 1, currentToken: 2, stoppedByUser: false, exitedNormally: false))
    }

Minimal spec-compliant subset if the extra banner is not wanted: steps 1 (first function only, with the `guard exitedNormally`), 2, the `exitedNormally:` plumbing in 3, and the testNoNotifyWhenKilledExternally row in 5. Optional: `import os` and `Logger(subsystem: "com.nosleep.app", category: "caffeinate").error("caffeinate exited unexpectedly")` in the `else if unexpected` branch (subsystem matches build.sh:9).

Manual verification: start a 15-minute session, run `killall caffeinate` in Terminal -> menu shows Inactive and the banner reads 'NoSleep stopped unexpectedly…' (not 'Your 15 minutes session has ended.'); Stop and Quit produce no banner; a temporarily shortened `-t` still produces the completion banner with Extend.

---

### Failed `proc.run()` is swallowed: previous session already killed, partial state left behind, no user feedback

- **Location:** `Sources/NoSleep/CaffeinateManager.swift:131`
- **Severity / category:** low / bug
- **Votes:** reproduce:ok(0.93), skeptic:REFUTE(0.7), impact:ok(0.7)

**Reviewer note.** The skeptic lens found the leftover state unobservable (every reader is behind an `isActive` guard) and self-healing on the next start. The real gap is the missing user feedback and log line when caffeinate cannot be launched.

**What is wrong.** `start()` first calls `stop()` (SIGTERMing any live session), then mutates published state (`remainingSeconds = duration` at line 116, `activeDuration = selectedDuration` at 121, `runToken += 1`, `stoppedByUser = false`) before `try proc.run()` at line 130. If `run()` throws (EAGAIN/process-table limit, EACCES, a locked-down/MDM Mac, a future macOS that moves the binary), the `catch` just `return`s with no logging: `isActive` is false but `remainingSeconds` is the full duration and `activeDuration` is non-nil, violating the otherwise-held invariant `remainingSeconds > 0 => isActive`. `formattedRemaining` hides this behind its `isActive` guard, but the user has just clicked a duration, the radio moved, the previous session was terminated, and the menu silently says 'Inactive'.

**How it fails.** User is Active (2h) and at the per-user process limit (runaway build); picks 4h. `stop()` kills the running caffeinate, the new spawn fails, the icon flips to inactive with '4 hours' selected and `remainingSeconds == 14400` internally; no error anywhere. The user assumes the click did not register and the Mac sleeps mid-task.

**Suggested fix.**

Sources/NoSleep/CaffeinateManager.swift

1. Add `import os` after `import SwiftUI` (line 20).

2. After `@Published var remainingSeconds: Int = 0` (line 51) add:
```swift
/// Human-readable reason the last `start()` failed to launch caffeinate; nil once a launch succeeds.
@Published private(set) var lastError: String?
```

3. Replace lines 78-86 (`activeDuration` decl through `init`) with an injectable init so the failure path is unit-testable (the test host has no bundle, so `UNUserNotificationCenter.current()` in `init` throws NSInternalInconsistencyException):
```swift
private var activeDuration: SleepDuration?
private let executablePath: String
private static let logger = Logger(subsystem: "com.nosleep.app", category: "CaffeinateManager")
let notifications = NotificationManager()

init(executablePath: String = "/usr/bin/caffeinate",
     configureNotifications: Bool = true) {
    self.executablePath = executablePath
    let saved = UserDefaults.standard.integer(forKey: "selectedDuration")
    self.selectedDuration = SleepDuration(rawValue: saved) ?? .fourHours
    notifications.onExtend = { [weak self] in self?.extendOneHour() }
    if configureNotifications { notifications.requestAuthorization() }
}
```
(`NoSleepApp.swift:23` keeps `CaffeinateManager()` unchanged.)

4. In `start()` (lines 110-136): use `URL(fileURLWithPath: executablePath)`; delete the `remainingSeconds = ...` writes at 116/118 and `activeDuration = selectedDuration` at 121; replace the do/catch and the two lines after it with:
```swift
do {
    try proc.run()
} catch {
    // Nothing was launched: state is already the stopped state; tell the user why the click did nothing.
    Self.logger.error("caffeinate failed to launch: \(error.localizedDescription, privacy: .public)")
    lastError = "Couldn't start caffeinate: \(error.localizedDescription)"
    return
}

// Commit session state only once the process is actually running.
lastError = nil
process = proc
activeDuration = selectedDuration
remainingSeconds = selectedDuration == .indefinite ? 0 : selectedDuration.rawValue
isActive = true
```
(Safe ordering: the terminationHandler hops to MainActor via `Task`, which cannot run until `start()` returns.)

5. In `stop()` after `remainingSeconds = 0` (line 156) add `activeDuration = nil` so `activeDuration != nil` iff a process for the current `runToken` was launched.

Sources/NoSleep/MenuBarView.swift - after the status Button's `.padding(.horizontal, 4)` (line 40), before the first `Divider()`:
```swift
if let error = manager.lastError {
    Text(error)
        .font(.caption)
        .padding(.horizontal, 8)
}
```
(A plain `Text` in the `.menu` style renders as a disabled grey row automatically; no `.disabled()`/`.foregroundStyle` needed. Menu closes on click, so the user sees it on reopen; the cup icon flipping to outline is the immediate cue.)

Tests/NoSleepTests/CaffeinateManagerTests.swift - add:
```swift
@MainActor
func testLaunchFailureLeavesInactiveAndZeroRemaining() {
    let m = CaffeinateManager(executablePath: "/nonexistent/caffeinate", configureNotifications: false)
    m.selectedDuration = .fourHours
    m.start()
    XCTAssertFalse(m.isActive)
    XCTAssertEqual(m.remainingSeconds, 0)
    XCTAssertEqual(m.formattedRemaining, "")
    XCTAssertNotNil(m.lastError)
    XCTAssertEqual(m.selectedDuration, .fourHours)
}
```

Drop from the original suggestion: the `FileManager.default.isExecutableFile(atPath: "/usr/bin/caffeinate")` launch check (the binary is on the sealed system volume; the realistic failure is EAGAIN at spawn time, which a pre-check cannot detect) and the inline per-call `Logger(...)` with `"\(error)"` (renders `<private>` in Console for release builds without `privacy: .public`).

---

### `try?` swallows plist write/remove failures but `isEnabled` flips anyway; toggle reports a state that was never persisted

- **Location:** `Sources/NoSleep/LoginItemManager.swift:62`
- **Severity / category:** low / bug
- **Votes:** reproduce:ok(0.9), skeptic:ok(0.85), impact:ok(0.85)

**What is wrong.** In `enable()`, `try? data.write(to:options:)` discards failure and line 63 unconditionally sets `isEnabled = true`; in `disable()`, `try? removeItem` likewise ignores failure and `isEnabled = false` runs regardless; `guard let execPath ... else { return }` makes the toggle silently snap back. The published state therefore diverges from disk whenever `~/Library/LaunchAgents` is unwritable (root-owned after a sudo'd installer, a regular file at that path, MDM/profile restrictions, read-only home) or the plist is not removable, and nothing is surfaced to the user. `init()` also never validates that `ProgramArguments[0]` still points at the running binary, so a stale plist reads as 'enabled' (see F6 for the path root cause). The MenuBarView binding `set: { _ in loginManager.toggle() }` (MenuBarView.swift:84) discards the desired value and only works because SwiftUI's Toggle always calls `set(!get())`; a value-taking API is the natural place to make `isEnabled` reflect the actual outcome.

**How it fails.** `~/Library/LaunchAgents` exists but is not writable by the user. User flips Start at Login ON: the toggle shows ON, no plist is written, the app does not start at login, and on next launch the toggle silently reads OFF again with no explanation. Conversely a failed removal shows OFF while the agent still launches at login.

**Suggested fix.**

Two files. Keep this fix independent of F6 (do NOT add ProgramArguments[0] validation here; if F6 lands with SMAppService.mainApp, delete LoginItemManager entirely instead).

1) Sources/NoSleep/LoginItemManager.swift — replace lines 21-71 with:

```swift
@MainActor
final class LoginItemManager: ObservableObject {
    private static let plistLabel = "com.nosleep.app"

    // Single definition (init at lines 33-34 currently duplicates the path).
    private static let plistURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(plistLabel).plist")

    /// Mirrors what is on disk; only flips after a successful write/remove.
    @Published private(set) var isEnabled: Bool

    /// Reason the last enable/disable failed; nil after a success.
    @Published private(set) var lastError: String?

    init() {
        self.isEnabled = FileManager.default.fileExists(atPath: Self.plistURL.path)
    }

    func setEnabled(_ on: Bool) {
        do {
            if on { try writePlist() } else { try removePlist() }
            isEnabled = on
            lastError = nil
        } catch {
            // Re-sync with disk instead of trusting the requested value.
            isEnabled = FileManager.default.fileExists(atPath: Self.plistURL.path)
            lastError = "Couldn't \(on ? "enable" : "disable") Start at Login: \(error.localizedDescription)"
        }
    }

    private func writePlist() throws {
        guard let execPath = Bundle.main.executablePath else {
            throw CocoaError(.fileNoSuchFile,
                             userInfo: [NSLocalizedDescriptionKey: "Executable path unavailable."])
        }
        let plist: [String: Any] = [
            "Label": Self.plistLabel,
            "ProgramArguments": [execPath],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        try FileManager.default.createDirectory(
            at: Self.plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: Self.plistURL, options: .atomic)
    }

    private func removePlist() throws {
        do {
            try FileManager.default.removeItem(at: Self.plistURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already absent — that is the desired end state. (Verified: removeItem throws CocoaError code 4 here.)
        }
    }
}
```

2) Sources/NoSleep/MenuBarView.swift — line 84: change `set: { _ in loginManager.toggle() }` to `set: { loginManager.setEnabled($0) }`, and after the Toggle's `.padding(.vertical, 2)` (line 87) insert:

```swift
            if let error = loginManager.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
```

(Renders as a disabled menu row in .menu style, same as the "Duration:" caption at line 59. The localizedDescription is ~95 chars and will widen the native menu; if that is undesirable, shorten to "Couldn't update ~/Library/LaunchAgents" and log `error` with os.Logger. An NSAlert after `NSApp.activate(ignoringOtherApps: true)` is the more immediate alternative but pulls AppKit into the manager; not needed for this rare path.)

Verified in a temp copy: builds clean under Swift 6 strict concurrency, 5/5 tests pass. Toggle behaviour on success is unchanged; on failure the checkbox stays in its true on-disk state and the reason appears under it.

---

### Quitting leaves an actionable Extend banner that cold-launches the quit app in the background

- **Location:** `Sources/NoSleep/CaffeinateManager.swift:173`
- **Severity / category:** low / bug
- **Votes:** reproduce:ok(0.7), skeptic:REFUTE(0.7), impact:ok(0.6)

**Reviewer note.** Platform-standard behaviour and arguably intended. It is resolved as a side effect of the stale-Extend fix (clearing delivered notifications in `stop()`, which `cleanup()` calls on Quit).

**What is wrong.** The cold-start path is never handled explicitly. `cleanup()` (line 173, called from the Quit menu item at MenuBarView.swift:93) only calls `stop()`; it does not remove delivered notifications, and there is no app delegate so nothing runs on termination either. A completion banner therefore stays in Notification Center after the user quits (or the app crashes). Because `EXTEND_1H` has no `.foreground` option (NotificationManager.swift:41-43), tapping it later makes usernotificationsd launch NoSleep in the background via LaunchServices; the `@StateObject` init installs the delegate during `applicationWillFinishLaunching` (verified empirically on this machine), `didReceive` fires, and `extendOneHour()` starts a 1 h `caffeinate` with no age or state check. The only visible sign is a cup icon reappearing in the menu bar of an LSUIElement app the user deliberately quit. Whether a cold-start Extend should be honored at all is undecided in code, spec, plan and README. Related to but distinct from the already-noted stale-Extend-replaces-running-session issue: this is the quit/cold-start path and the missing cleanup on quit.

**How it fails.** Timed session ends at 17:00, banner delivered. User reads it, opens the menu and picks Quit NoSleep (app exits, banner remains in Notification Center). Next morning the user clears Notification Center and clicks 'Extend 1 hour' on the leftover banner. NoSleep relaunches in the background with no Dock icon or window, `selectedDuration` is overwritten to 1 hour, and the Mac is kept awake for an hour although the user quit the utility.

**Suggested fix.**

Policy: honor "Extend 1 hour" only while the banner is fresh (<= 15 min), on both the running and cold-start paths; additionally clear delivered banners on Quit as best-effort hygiene. Verified to compile warning-free under Swift 6 and pass 8/8 tests.

1) Sources/NoSleep/NotificationManager.swift
   - Line 25: replace `private let extendActionID = "EXTEND_1H"` with
       `private nonisolated static let extendActionID = "EXTEND_1H"`
     (must be `nonisolated`, otherwise the class's @MainActor isolation makes it unreadable from the pure function below — hard compile error.)
   - After line 26 (`private var didConfigure = false`) add:
       /// An Extend tap older than this is stale: delivered banners persist in
       /// Notification Center indefinitely and across app quit/relaunch.
       nonisolated static let maxExtendAge: TimeInterval = 15 * 60

       nonisolated static func shouldHandleExtend(actionID: String, age: TimeInterval) -> Bool {
           actionID == extendActionID && age >= 0 && age <= maxExtendAge
       }
   - Line 41: `UNNotificationAction(identifier: Self.extendActionID, ...)`.
   - Before `postCompletion` (line 52) add:
       /// Remove delivered "session complete" banners so a quit app leaves no
       /// actionable Extend button behind (best-effort: async XPC before exit).
       func clearDelivered() {
           UNUserNotificationCenter.current().removeAllDeliveredNotifications()
       }
   - didReceive (lines 80-84) becomes:
       let actionID = response.actionIdentifier
       let age = Date().timeIntervalSince(response.notification.date)
       let handle = Self.shouldHandleExtend(actionID: actionID, age: age)
       Task { @MainActor [weak self] in
           if handle { self?.onExtend?() }
           completionHandler()
       }

2) Sources/NoSleep/CaffeinateManager.swift lines 173-175:
       func cleanup() {
           notifications.clearDelivered()   // best-effort; the age guard is the reliable backstop
           stop()
       }
   (No app delegate / applicationWillTerminate needed; do not add a separate 'reject cold-start Extend' rule — a fresh tap after quit should legitimately relaunch NoSleep.)

3) Tests/NoSleepTests/CaffeinateManagerTests.swift — append before the closing brace (line 47):
       func testExtendHonoredWhenFresh() {
           XCTAssertTrue(NotificationManager.shouldHandleExtend(actionID: "EXTEND_1H", age: 30))
       }
       func testExtendIgnoredWhenStale() {
           XCTAssertFalse(NotificationManager.shouldHandleExtend(
               actionID: "EXTEND_1H", age: NotificationManager.maxExtendAge + 1))
       }
       func testDefaultTapIgnored() {
           XCTAssertFalse(NotificationManager.shouldHandleExtend(
               actionID: "com.apple.UNNotificationDefaultActionIdentifier", age: 1))
       }

4) README.md Run section (after the Quit bullet, line 76): add one line, e.g.
   "- **Extend 1 hour** (on the session-ended notification) — starts a fresh 1-hour session; ignored if the notification is older than 15 minutes. If NoSleep has been quit, a fresh tap relaunches it in the menu bar."

5) Optionally record the decision in docs/superpowers/specs/2026-07-01-menu-activation-and-notifications-design.md 'Confirmed decisions' table: "Extend freshness | Honored only within 15 min of delivery; delivered banners are cleared on Quit."

---

## 2. Bugs in build, install and packaging scripts

### Mount point hard-coded to /Volumes/NoSleep; a pre-mounted same-named volume makes the script eject the wrong disk and fail convert

- **Location:** `package-dmg.sh:48`
- **Severity / category:** medium / bug
- **Votes:** reproduce:ok(0.95), skeptic:ok(0.9), impact:ok(0.85)

**What is wrong.** `MOUNT_DIR="/Volumes/${VOL_NAME}"` is assumed (line 23) and the output of `hdiutil attach` is discarded (line 48). Verified on this machine: if a volume named NoSleep is already mounted, the new image mounts at '/Volumes/NoSleep 1' while its Finder volume name is still 'NoSleep'. Cascade: the AppleScript `tell disk "NoSleep"` (line 55) targets an ambiguous/wrong disk, `SetFile -a C "$MOUNT_DIR"` (line 89) flags the wrong volume, `hdiutil detach "$MOUNT_DIR"` (line 94) ejects the user's pre-existing volume, `hdiutil convert` (line 97) fails with 'Resource busy' because the temp image is still attached, and `cleanup()` cannot recover because `[ -d /Volumes/NoSleep ]` is now false — leaving NoSleep-tmp.dmg mounted at '/Volumes/NoSleep 1' and on disk. Same outcome after any earlier run killed with SIGKILL or a closed terminal (temp image left mounted).

**How it fails.** Maintainer opens the previously released NoSleep-1.1.0.dmg to sanity-check it (mounted read-only at /Volumes/NoSleep), then runs ./package-dmg.sh to build the next version: 'Warning: Finder layout not applied' (misleading), the release DMG is ejected, `hdiutil convert` fails, the script exits non-zero without producing the new DMG, and a writable NoSleep-tmp image stays attached at '/Volumes/NoSleep 1'.

**Suggested fix.**

All edits in package-dmg.sh (the repo copy is read-only; these are the changes to make):

1) Pre-flight, insert immediately after line 23 (`MOUNT_DIR="/Volumes/${VOL_NAME}"`), i.e. before staging, the trap, and the `rm -f "$DMG_TMP" "$DMG_FINAL"` at line 42:

    if [ -e "$MOUNT_DIR" ]; then
        echo "Error: a volume named '${VOL_NAME}' is already mounted at ${MOUNT_DIR}" >&2
        echo "       (an opened NoSleep DMG, or a leftover ${DMG_TMP} from an aborted run)." >&2
        echo "       Eject it first:  hdiutil detach \"${MOUNT_DIR}\"   and re-run." >&2
        exit 1
    fi

2) Replace lines 26-31 (STAGING + cleanup + trap) so cleanup detaches by device node, with a forced fallback, and is safe under `set -u`:

    STAGING="$(mktemp -d)"
    DEV_NODE=""
    cleanup() {
        if [ -n "$DEV_NODE" ]; then
            hdiutil detach "$DEV_NODE" >/dev/null 2>&1 \
                || hdiutil detach "$DEV_NODE" -force >/dev/null 2>&1 || true
        fi
        rm -rf "$STAGING"
    }
    trap cleanup EXIT INT TERM

3) Replace line 48 (`hdiutil attach "$DMG_TMP" -readwrite -noverify -noautoopen >/dev/null`) with capture + verification (stdout only is captured, so hdiutil's deprecation WARNING on stderr does not affect parsing):

    ATTACH_OUT="$(hdiutil attach "$DMG_TMP" -readwrite -noverify -noautoopen)"
    DEV_NODE="$(printf '%s\n' "$ATTACH_OUT" | awk '/^\/dev\//{print $1; exit}')"   # whole-disk node, e.g. /dev/disk4
    ACTUAL_MOUNT="$(printf '%s\n' "$ATTACH_OUT" | grep -o '/Volumes/.*' | head -n1)"
    if [ -z "$DEV_NODE" ] || [ "$ACTUAL_MOUNT" != "$MOUNT_DIR" ]; then
        echo "Error: image attached as '${DEV_NODE:-?}' at '${ACTUAL_MOUNT:-<none>}', expected ${MOUNT_DIR}." >&2
        exit 1   # EXIT trap detaches DEV_NODE
    fi

   Keep the existing `sleep 2` (line 49). Lines 55 (`tell disk "${VOL_NAME}"`) and 89 (`SetFile -a C "$MOUNT_DIR"`) can stay as they are: the check above now guarantees they refer to this run's volume.

4) Replace line 94 (`hdiutil detach "$MOUNT_DIR" >/dev/null`) with a device-node detach that tolerates the common Finder "Resource busy" flake and then disarms cleanup so it cannot detach a reused disk number:

    hdiutil detach "$DEV_NODE" >/dev/null \
        || { sleep 2; hdiutil detach "$DEV_NODE" -force >/dev/null; }
    DEV_NODE=""

Do not switch to `hdiutil attach -mountpoint "$STAGING/mnt"`: the Finder AppleScript addresses the volume as `disk "NoSleep"`, which is only reliable for volumes mounted under /Volumes; changing that would require rewriting the layout script with POSIX paths and risks breaking the styled window, which is the script's purpose. Optional follow-ups (not required): one line in README.md under "Package a DMG" — "Eject any mounted NoSleep volume before running package-dmg.sh"; and, if desired, have the pre-flight auto-detach only when `hdiutil info -plist` shows the occupant's image-path is this repo's NoSleep-tmp.dmg.

---

### Single hdiutil detach under set -e: transient EBUSY aborts the release and leaves NoSleep-tmp.dmg mounted

- **Location:** `package-dmg.sh:94`
- **Severity / category:** medium / bug
- **Votes:** reproduce:ok(0.85), skeptic:ok(0.8), impact:ok(0.8)

**What is wrong.** Line 94 runs `hdiutil detach "$MOUNT_DIR"` exactly once with no retry and no `-force`, under `set -euo pipefail`. Right after Finder has been scripted to open, restyle and close the volume window (lines 56/69), Finder's asynchronous .DS_Store write, QuickLook's thumbnail pass over NoSleep.app, Spotlight/mds indexing of the new volume, or fseventsd can still hold the volume for a moment, and DiskArbitration dissents the unmount. hdiutil prints `couldn't unmount "diskN" - Resource busy` and exits 16 (EBUSY, see man hdiutil COMMON ERRORS). `set -e` aborts the script before `hdiutil convert` (line 97), so no NoSleep-<version>.dmg is produced. The EXIT trap's cleanup (line 28) then issues one more immediate detach with output discarded and `|| true`, which typically fails for the same reason milliseconds later and says nothing, so the developer is left with /Volumes/NoSleep still mounted and NoSleep-tmp.dmg still attached, with no message. Verified in a temp copy with a 4-second file holder standing in for Finder: script exit 16, volume still mounted, tmp dmg present, final dmg absent, and a detach issued a few seconds later succeeded — exactly what a retry loop would absorb. This is the well-known reason create-dmg wraps detach in a retry loop keyed on exit 16 and appdmg retries on 'Resource busy'. The leftover attachment also feeds the already-reported pre-mounted-volume failure on the next run (line 42 `rm -f` unlinks the mounted backing file; the new image lands on `/Volumes/NoSleep 1`).

**How it fails.** Automation granted; layout applied; Finder/quicklookd still has a file open on the volume when line 94 runs → `hdiutil: couldn't unmount "disk4" - Resource busy`, exit 16 → script aborts before convert, no release DMG → cleanup's single detach also fails silently → /Volumes/NoSleep stays mounted → next ./package-dmg.sh run ejects/lays out the wrong disk and convert fails with Resource busy; the release engineer has to detach and re-run by hand.

**Suggested fix.**

In package-dmg.sh:

1. Insert a detach helper before cleanup() (i.e. between line 26 `STAGING="$(mktemp -d)"` and line 27):

# Detach with retries: Finder/QuickLook/Spotlight often keep a fresh volume open for a
# few seconds after the layout step, and hdiutil then exits 16 (EBUSY, see hdiutil(1)
# COMMON ERRORS). Retry only on EBUSY; any other error fails fast with hdiutil's message.
detach_volume() {  # $1 = mount point or /dev entry
    local attempt rc err
    for attempt in 1 2 3 4 5; do
        err="$(hdiutil detach "$1" 2>&1 >/dev/null)" && return 0
        rc=$?
        if [ "$rc" -ne 16 ]; then
            echo "$err" >&2
            return "$rc"
        fi
        echo "    Volume busy, retrying detach ($attempt/5)…"
        sleep "$attempt"
    done
    echo "    Warning: $1 still busy after retries; forcing eject." >&2
    hdiutil detach -force "$1" >/dev/null 2>&1
}

2. Replace line 28 in cleanup() so a leftover mount is never silent:

    if [ -d "$MOUNT_DIR" ]; then
        detach_volume "$MOUNT_DIR" \
            || echo "Warning: $MOUNT_DIR is still mounted; run: hdiutil detach -force '$MOUNT_DIR'" >&2
    fi

3. Replace line 94 `hdiutil detach "$MOUNT_DIR" >/dev/null` with:

detach_volume "$MOUNT_DIR"

Notes: total polite wait is 15 s (1+2+3+4+5) before -force, matching create-dmg's behaviour; -force stays a last resort because a forced eject can lose Finder's in-flight .DS_Store, which is acceptable under the script's existing "layout is best effort, DMG still valid" contract. On the hard-failure path cleanup() re-runs the helper once more (another 15 s) — harmless; if you want to avoid it, set `MOUNTED=1` after line 48, `MOUNTED=0` after the line-94 detach, and guard cleanup on `$MOUNTED` instead of `[ -d "$MOUNT_DIR" ]`. Once the pre-mounted-volume finding is fixed, pass the dev-entry from `hdiutil attach -plist` to detach_volume instead of the mount point; the helper accepts either. Capturing stderr also suppresses the macOS 27 "hdiutil detach ... is deprecated" WARNING that currently leaks through line 94's stdout-only redirect, while still printing it (with the real error) if a detach genuinely fails.

---

### `trap cleanup EXIT INT TERM`: Ctrl-C runs cleanup then the script continues; NoSleep-tmp.dmg is never cleaned up

- **Location:** `package-dmg.sh:31`
- **Severity / category:** low / bug
- **Votes:** reproduce:ok(0.97), skeptic:ok(0.9), impact:ok(0.8)

**What is wrong.** Verified with an equivalent script: SIGINT while in `if wait "$OSA_PID"` runs `cleanup()` (detaches the volume, deletes STAGING) but does not terminate the script, because a trapped INT only returns and `wait` inside an `if` condition is exempt from `set -e`. The script then prints the 'Finder layout not applied' warning, fails at `hdiutil detach` (line 94) because the volume is already gone, and runs `cleanup()` a second time. In every failure path `NoSleep-tmp.dmg` (line 22) is left behind because cleanup never removes it.

**How it fails.** User presses Ctrl-C while the Finder layout step is waiting. Output shows 'Warning: Finder layout not applied (Automation denied or timed out)…' followed by an hdiutil detach error, exit status 1, and NoSleep-tmp.dmg left in the repo root.

**Suggested fix.**

In package-dmg.sh replace lines 27-31 with:

cleanup() {
    # Optional: stop the layout job and its watchdog if we are interrupted (guards needed: set -u, may run before line 76)
    kill "${OSA_PID:-}" "${WATCHER:-}" 2>/dev/null || true
    if [ -d "$MOUNT_DIR" ]; then
        hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 \
            || hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$STAGING"
    rm -f "$DMG_TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

Rationale: signals now terminate the script (the `exit` in the INT/TERM handler fires the EXIT trap exactly once), so Ctrl-C can no longer fall through into the else branch, print the misleading 'Finder layout not applied' warning, trip `hdiutil detach` at line 94, or continue on to `hdiutil convert`; the throwaway `NoSleep-tmp.dmg` is removed on every exit path; the `-force` fallback handles the volume still being held open by the Finder window the AppleScript opened. If finding F5 (detach by captured device node) is also applied, use `${DEV_NODE:-$MOUNT_DIR}` in place of `$MOUNT_DIR` above. Line 98 (`rm -f "$DMG_TMP"`) may stay or be deleted; it becomes redundant.

---

### Timeout kills the subshell, not osascript; the watcher's `sleep 45` is orphaned and holds stdout open

- **Location:** `package-dmg.sh:77`
- **Severity / category:** low / bug
- **Votes:** reproduce:ok(0.95), skeptic:ok(0.92), impact:ok(0.8)

**What is wrong.** `kill "$OSA_PID"` (line 77) and `kill "$WATCHER"` (line 79) target background subshell PIDs (`apply_layout` is a function, so `$!` is the subshell, not osascript). Verified: killing a bash subshell does not kill its child, so (a) on timeout the TCC-blocked `osascript` keeps running and may apply the layout to whatever disk is named NoSleep after the script has moved on to detach/convert, and (b) on success the `sleep 45` child survives for the remaining time holding the script's stdout/stderr open.

**How it fails.** (a) Terminal lacks Automation -> Finder permission; the TCC prompt appears; after 45 s the script prints 'timed out', detaches and converts. The user later clicks Allow: the orphaned osascript runs `tell disk "NoSleep"` against a disk that no longer exists (or a real NoSleep volume mounted later) and errors/mutates it. (b) `DMG=$(./package-dmg.sh | tail -1)` or a CI step piping output blocks up to 45 s after 'Done!' because the orphan sleep still holds the pipe.

**Suggested fix.**

In package-dmg.sh replace lines 52-85 so osascript runs directly in the background (no function wrapper, so `$!` is osascript's own PID) and the timeout is enforced by a poll loop in the main shell (no watcher subshell => nothing can be orphaned):

```bash
echo "==> Applying Finder layout (best effort — needs Automation → Finder permission)…"
# Run osascript itself in the background (not via a function, so $! is osascript's own
# PID) and enforce the timeout from this shell, so nothing is left orphaned if the
# TCC prompt is never answered.
osascript <<APPLESCRIPT &
tell application "Finder"
    tell disk "${VOL_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "${APP_NAME}.app" of container window to {150, 190}
        set position of item "Applications" of container window to {450, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
OSA_PID=$!

LAYOUT_TIMEOUT=45
for (( i = 0; i < LAYOUT_TIMEOUT; i++ )); do
    kill -0 "$OSA_PID" 2>/dev/null || break
    sleep 1
done
if kill -0 "$OSA_PID" 2>/dev/null; then
    kill "$OSA_PID" 2>/dev/null || true   # kills osascript itself, not a wrapper subshell
fi
if wait "$OSA_PID" 2>/dev/null; then
    echo "    Layout applied."
else
    echo "    Warning: Finder layout not applied (Automation denied or timed out)."
    echo "    The DMG is still valid. Grant your terminal 'Automation → Finder' in"
    echo "    System Settings → Privacy & Security, then re-run for the styled window."
fi
```

Notes: keep the heredoc delimiter unquoted (the body relies on `${VOL_NAME}`/`${APP_NAME}` expansion); `for ((...))`, `kill -0`, and `wait <pid>` are all bash 3.2 features; every `sleep 1` is a foreground child and is reaped, and there is no `WATCHER` variable or subshell any more. Optional hardening (2 lines): initialise `OSA_PID=""` near line 23 and add `[ -n "${OSA_PID:-}" ] && kill "$OSA_PID" 2>/dev/null || true` as the first line of `cleanup()` (line 28) so a Ctrl-C during the TCC prompt does not orphan osascript either (background jobs in a non-interactive shell inherit SIGINT ignored, so Ctrl-C alone will not stop it). Do not rely on `timeout(1)`: macOS does not ship it.

---

### background@2x.png is staged but never used by Finder; the DMG background is blurry on every Retina Mac

- **Location:** `package-dmg.sh:64`
- **Severity / category:** low / bug
- **Votes:** reproduce:ok(0.88), skeptic:ok(0.85), impact:ok(0.85)

**What is wrong.** generate-art.swift renders a 1200x800 @2x background (line 173) and package-dmg.sh line 38 copies it into `.background/`, but Finder's `background picture` takes exactly one file and line 64 points at `background.png`. The `@2x` sibling convention is an NSBundle/NSImage(named:) mechanism; Finder does not consult it for icon-view backgrounds (which is why create-dmg/appdmg build a multi-representation TIFF instead). Additionally the @2x rep is written with `rep.size = 1200x800` (generate-art.swift:56), i.e. tagged 72 dpi, so even a consumer honouring @2x would treat it as a different-sized image rather than a HiDPI variant. Net effect: the ~187 KB @2x file is dead weight inside the DMG and every Retina Mac shows the 600x400 image upscaled 2x. Verified in a scratch copy: `tiffutil -cathidpicheck assets/dmg-background.png assets/dmg-background@2x.png -out bg.tiff` succeeds and produces a 2-directory TIFF (600x400 @72dpi + 1200x800 @144dpi, sRGB, alpha preserved); `/usr/bin/tiffutil` is present.

**How it fails.** Build the DMG and open it on any Retina Mac (all currently shipping Macs): the arrow and 'Drag NoSleep to Applications to install' caption are visibly soft next to the crisp 128 px app icon and Applications alias, while the @2x asset shipped in the image is never displayed.

**Suggested fix.**

Required change, package-dmg.sh only (tiffutil is in the base OS at /usr/bin/tiffutil):

Replace lines 36-39:
```bash
mkdir -p "$STAGING/.background"
# Finder reads exactly one background file and ignores the @2x-sibling
# convention, so merge both PNGs into a two-page (72 dpi + 144 dpi) TIFF;
# Finder picks the 144 dpi page on Retina displays. Falls back to the 1x PNG.
BG_NAME="background.png"
if [ -f "$BACKGROUND" ] && [ -f "$BACKGROUND2X" ] && command -v tiffutil >/dev/null 2>&1; then
    tiffutil -cathidpicheck "$BACKGROUND" "$BACKGROUND2X" -out "$STAGING/.background/background.tiff"
    BG_NAME="background.tiff"
elif [ -f "$BACKGROUND" ]; then
    cp "$BACKGROUND" "$STAGING/.background/background.png"
fi
[ -f "$ICON" ] && cp "$ICON" "$STAGING/.VolumeIcon.icns"
```
(this drops the never-used `background@2x.png` copy from old line 38; the @2x PNG is now consumed into the TIFF instead.)

Replace line 64 inside the AppleScript heredoc (it is an unquoted heredoc, so `${...}` already expands, as `${VOL_NAME}`/`${APP_NAME}` do):
```
        set background picture of theViewOptions to file ".background:${BG_NAME}"
```

Do not redirect tiffutil's output: its "2 images written" and any -cathidpicheck size-mismatch warning go to stderr and are useful. Note for the changelog/README: the DMG grows by roughly 170 KB (LZW TIFF 419 KB replaces 249 KB of PNGs; zlib-9 in UDZO barely compresses either), which is the cost of actually displaying the @2x art.

Optional hygiene (not needed for the DMG; tiffutil derives the 144 dpi tag from the `@2x` filename), scripts/generate-art.swift: make the standalone @2x PNG self-describing by giving the 1200x800 rep a 600x400 point size. Line 40: `func makeContext(width: Int, height: Int, pointSize: NSSize? = nil) -> (NSBitmapImageRep, NSGraphicsContext)`; line 56: `rep.size = pointSize ?? NSSize(width: width, height: height)` (keep it after `NSGraphicsContext(bitmapImageRep:)` so the context CTM stays in pixels); line 116-117: `func drawDMGBackground(width: Int, height: Int, scale: Int = 1, path: String)` with `makeContext(width: width, height: height, pointSize: NSSize(width: width / scale, height: height / scale))`; line 173: pass `scale: 2`. Verified pixel-identical output tagged 144 dpi. If applied, re-run ./make-icons.sh and commit the regenerated assets/dmg-background@2x.png.

---

### install.sh replaces the bundle without quitting the running instance; the new copy never launches

- **Location:** `install.sh:18`
- **Severity / category:** medium / bug
- **Votes:** reproduce:REFUTE(0.2), skeptic:ok(0.85), impact:ok(0.85)

**Reviewer note.** The reproduce verifier tested this on macOS 27 and found that `open` on the new copy *does* launch a second process, so the title's claim that the new copy never launches is wrong. What remains true: the old instance keeps running from the deleted bundle, its caffeinate child keeps running, and two NoSleep instances can coexist. Treat this as 'install.sh should quit the running instance first', not as a failed update.

**What is wrong.** The script `rm -rf`s and re-copies NoSleep.app while an instance (from the build dir, ~/Applications, or launched by the LaunchAgent) may be running. The old process keeps running old code from its deleted bundle, the LaunchAgent plist is rewritten but never reloaded, and the suggested `open ~/Applications/NoSleep.app` (line 29) just activates the already-running instance because LaunchServices matches on bundle identifier `com.nosleep.app` rather than launching the new binary. The user believes the update took effect when it did not.

**How it fails.** User has NoSleep 1.0 running from ~/Applications with Start at Login enabled, pulls 1.1.0, runs `./build.sh && ./install.sh`, then `open ~/Applications/NoSleep.app`. The menu still shows 1.0 behaviour (no auto-activate, no completion notification) until they manually Quit and relaunch — and if they don't notice, until next login.

**Suggested fix.**

File: install.sh. Insert the quit block after line 15 (`mkdir -p "$HOME/Applications"`) and before line 17/18 (`rm -rf "$DEST"`); replace line 29. Do NOT use osascript (TCC prompt, and the Apple-event quit path skips manager.cleanup() anyway) and do NOT add launchctl bootstrap alongside `open` (double instance).

```bash
mkdir -p "$HOME/Applications"

# Quit any running instance first. Otherwise the old binary keeps running from the
# deleted bundle and `open` merely re-activates it (LaunchServices matches on bundle
# id), so the update silently never takes effect. NoSleep has no
# applicationWillTerminate hook (only the Quit button calls manager.cleanup()), so
# also kill its caffeinate child — capture it BEFORE killing the app, because it is
# reparented to launchd afterwards. Never pkill caffeinate globally (other tools use it).
UID_="$(id -u)"
WAS_RUNNING=0
for pid in $(pgrep -u "$UID_" -x "$APP_NAME" || true); do
    WAS_RUNNING=1
    kids="$(pgrep -P "$pid" -x caffeinate || true)"
    echo "==> Quitting running ${APP_NAME} (pid ${pid})…"
    kill "$pid" 2>/dev/null || true
    # shellcheck disable=SC2086  # intentionally unquoted: may hold several pids
    [ -n "$kids" ] && kill $kids 2>/dev/null || true
done
for _ in $(seq 1 20); do
    pgrep -u "$UID_" -x "$APP_NAME" >/dev/null || break
    sleep 0.25
done
pgrep -u "$UID_" -x "$APP_NAME" >/dev/null && pkill -9 -u "$UID_" -x "$APP_NAME" || true

echo "==> Installing ${APP_NAME}.app to ~/Applications…"
rm -rf "$DEST"
cp -R "$APP_BUNDLE" "$DEST"
# ... PlistBuddy block (lines 21-27) unchanged ...

if [ "$WAS_RUNNING" = 1 ]; then
    echo "==> Relaunching ${APP_NAME} from ~/Applications…"
    open "$DEST"
else
    echo "==> Done! Launch with:  open ~/Applications/${APP_NAME}.app"
fi
```

Notes: `|| true` on every pgrep is required under `set -euo pipefail` (a no-match pgrep exits 1 and would abort the script). The LaunchAgent needs no launchctl call: KeepAlive=false means launchd will not restart the killed job, the rewritten plist is re-read at next login, and in the common case (as on this machine) the loaded job's program path already equals $DEST. If launchd-managed relaunch is wanted instead, use `launchctl bootout "gui/$UID_/com.nosleep.app" 2>/dev/null || true; launchctl bootstrap "gui/$UID_" "$PLIST_PATH"` (RunAtLoad launches it) INSTEAD OF `open "$DEST"`, never both. Optionally add a one-line README note under "Install to ~/Applications" that install.sh quits and relaunches a running instance.

---

### On macOS 26+, the <=32 px .icns reps make Finder show the icon shrunk on a gray plate

- **Location:** `make-icons.sh:22`
- **Severity / category:** medium / bug
- **Votes:** reproduce:ok(0.9), skeptic:ok(0.88), impact:ok(0.85)

**What is wrong.** make-icons.sh emits explicit 16 px and 32 px representations (lines 22-24: icon_16x16, icon_16x16@2x, icon_32x32). On this macOS 27.0 host, IconServices (NSWorkspace.icon(forFile:), the same path Finder, Open/Save panels, Spotlight and System Settings use) renders a legacy .icns app icon that carries <=32 px reps on a light-gray 'legacy' backplate with the artwork shrunk inside it: at 16 px the coloured artwork occupies only ~10x12 px of the 14 px body, at 32 px roughly two thirds, and the plate pixels are neutral gray (173-212). Controls isolate the trigger: an otherwise identical bundle whose .icns contains only the 1024 px rep renders full-body with no plate at 16/32 px, while an 824-grid-correct version of the same art and even a solid-blue on-grid icon still get the plate when they include the small reps. At 64 px and above no plate appears for any variant, so the trigger is specifically the <=32 px representation types, not the artwork shape or size (distinct from the already-reported 902-vs-824 grid issue). Native icons (Calculator, Terminal) fill the whole 14 px body at 16 px.

**How it fails.** User on macOS 26/27 installs NoSleep.app, opens /Applications in Finder list or column view (16 pt), the Open panel, Spotlight, or Login Items on a non-Retina display: every other app icon is a full-size squircle while NoSleep appears as a small brown thumbnail framed inside a gray square, looking like a broken or placeholder icon. Same in the DMG window sidebar and any 16/32 px context.

**Suggested fix.**

1) make-icons.sh — delete lines 22-24 (`gen 16 icon_16x16.png`, `gen 32 icon_16x16@2x.png`, `gen 32 icon_32x32.png`) and add a guard comment so nobody re-adds them. Lines 18-31 become:

# gen <pixel-size> <iconset-filename>
gen() {
    sips -z "$1" "$1" "$MASTER" --out "${ICONSET}/$2" >/dev/null
}
# Intentionally no 16x16 / 16x16@2x / 32x32 reps. On macOS 26+ IconServices draws any
# .icns that carries <=32 px reps shrunk on a gray "legacy" plate at 16/32 px (Finder
# list/column view, Open panels, sidebar). Without them it derives those sizes from the
# 64 px rep with no plate; macOS 14/15 simply downsample the 64 px rep as before.
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png

2) Regenerate and commit the tracked binary asset — the script change alone is inert because build.sh:25-26 copies assets/AppIcon.icns verbatim and package-dmg.sh:39 reuses it as .VolumeIcon.icns:
   ./make-icons.sh && git add assets/AppIcon.icns assets/AppIcon.png assets/dmg-background.png assets/dmg-background@2x.png
   Sanity check: `iconutil -c iconset assets/AppIcon.icns -o /tmp/chk.iconset && ls /tmp/chk.iconset` must list exactly 7 files (icon_32x32@2x.png through icon_512x512@2x.png, no icon_16x16*.png / icon_32x32.png). Then ./build.sh && ./install.sh and view /Applications in Finder list view: NoSleep should be a full-size squircle like neighbouring apps.

3) Keep as separate follow-ups, not part of this change: F13 (ship an Icon Composer .icon compiled by `xcrun actool` into Contents/Resources/Assets.car plus CFBundleIconName in build.sh's Info.plist — bypasses the legacy .icns path on 26+ while this .icns remains the 14/15 fallback) and F14 (do not add hand-tuned 16/32 px reps back; they re-trigger the plate on 26+). No Swift source changes are needed.

---

### Output path 'assets' is cwd-relative, so running the script directly writes to the wrong place

- **Location:** `scripts/generate-art.swift:36`
- **Severity / category:** low / bug
- **Votes:** reproduce:ok(0.88), skeptic:ok(0.55), impact:ok(0.7)

**What is wrong.** `let outputDir = "assets"` plus `try? createDirectory` (line 170) means the script silently creates and writes an `assets/` directory relative to whatever the current working directory is. The header comment (line 20) advertises running it directly with `swift scripts/generate-art.swift`; only make-icons.sh happens to `cd` to the repo root first. Verified: `cd /tmp/elsewhere && swift <repo>/scripts/generate-art.swift` exits 0 and creates /tmp/elsewhere/assets/{AppIcon.png,dmg-background.png,dmg-background@2x.png} while the repo's tracked assets are untouched. Also verified that `#filePath` is populated in `swift` immediate mode for both relative and absolute invocations, so the repo root can be derived reliably.

**How it fails.** Developer edits the palette and runs `swift scripts/generate-art.swift` from a subdirectory or an IDE terminal rooted elsewhere: the script prints 'wrote assets/AppIcon.png' and exits 0, but the repo's assets/ (and therefore the next ./build.sh / ./package-dmg.sh) still use the old art; a stray assets/ directory is left behind.

**Suggested fix.**

In scripts/generate-art.swift:

1. Replace line 36 (`let outputDir = "assets"`) with:

```swift
// Resolve output relative to the repo, not the caller's cwd, so
// `swift scripts/generate-art.swift` works from any directory.
// An explicit output directory may be passed as the first argument.
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // scripts/
    .deletingLastPathComponent()   // repo root
    .standardizedFileURL
let outputDir = CommandLine.arguments.dropFirst().first
    ?? repoRoot.appendingPathComponent("assets").path
```

2. Replace line 170 (`try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)`) with:

```swift
do {
    try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write("Failed to create \(outputDir): \(error)\n".data(using: .utf8)!)
    exit(1)
}
```

3. Update the header comment on line 21 from "Output PNGs are written under ./assets/." to "Output PNGs are written to <repo>/assets/ regardless of cwd, or to the directory passed as the first argument."

No changes needed in make-icons.sh (its `cd "$SCRIPT_DIR"` + default path still resolve to the same location), build.sh, package-dmg.sh, or .gitignore. Lines 111, 165-167, 172-173 need no edits: because `outputDir` is now absolute in the default case, the existing `print("wrote \(path)")` automatically prints absolute paths. Optional: if you want the explicit-argument case to print absolute paths too, normalise it with `URL(fileURLWithPath: arg).standardizedFileURL.path` before assigning to `outputDir`.

---

## 3. Improvements: app behaviour and UI

### Hand-drawn radio buttons should be Toggle/Picker items so the menu gets native checkmarks and accessibility state

- **Location:** `Sources/NoSleep/MenuBarView.swift:70`
- **Severity / category:** medium / improvement
- **Votes:** reproduce:ok(0.92), skeptic:ok(0.85), impact:ok(0.92)

**What is wrong.** Each duration is a plain `Button` whose only selection indicator is a template SF Symbol (`circle` vs `circle.inset.filled`) in the image column. A probe dump of the generated NSMenu shows all eight items with `state=0` and a 15x15 `NSSymbolImageRep`, i.e. the menu itself has no idea which one is selected: no native checkmark, no highlight-aware mark, and VoiceOver announces every item identically (menu items expose selection via `state`/AXMenuItemMarkChar, never via the image). The same probe confirmed the alternatives render natively in this MenuBarExtra: `Toggle(label, isOn:)` yields `state=1` on the selected item with no image, and `Picker(...).pickerStyle(.inline)` yields a disabled `isSectionHeader=true` 'Duration' header plus radio items with `state=1`. This also lets you delete the `HStack`, the two symbol names, `.font(.caption2)` and the 'Duration:' `Text`.

**How it fails.** VoiceOver user opens the menu and hears '15 minutes', '30 minutes', ... with no 'checked' on the active one; sighted users see a non-standard dot glyph instead of the system checkmark used by every other macOS menu — and by the adjacent 'Start at Login' item, which gets a real checkmark because it is a Toggle.

**Suggested fix.**

In Sources/NoSleep/MenuBarView.swift replace lines 56-79 (the `Divider()`, the "Duration:" `Text` header with its four modifiers, the `ForEach` of hand-drawn `Button`s, and the trailing `Divider()`) with:

```swift
            // Duration — Toggles so the native menu marks the selected preset via
            // NSMenuItem.state (a real checkmark, exposed to VoiceOver as
            // AXMenuItemMarkChar). SF Symbol images on menu items do not render
            // on macOS 27.0, so the old circle/circle.inset.filled dots vanished.
            // The setter ignores the Bool so re-picking any duration (re)starts,
            // as before. Section supplies the separators on both sides.
            Section("Duration") {
                ForEach(SleepDuration.allCases) { duration in
                    Toggle(duration.label, isOn: Binding(
                        get: { manager.selectedDuration == duration },
                        set: { _ in manager.changeDuration(duration) }
                    ))
                }
            }
```

Notes: (1) Remove both adjacent `Divider()`s (lines 56 and 79) rather than keeping them: `Section` emits its own separators; leftovers create redundant separator items (AppKit collapses them visually, so this is cleanup, not a bug). (2) Do not wrap a `Picker` in a `Section` (duplicate header). A `Picker(...).pickerStyle(.inline)` also works and its setter did fire on same-value re-selection in testing, but `Toggle`'s setter-on-every-click contract is explicit, so prefer Toggle. (3) No changes needed in CaffeinateManager: `changeDuration` (line 163) already sets `selectedDuration` and calls `start()`. (4) Verified: compiles warning-free in Swift 6 language mode with platform macOS 14; 5/5 tests pass; renders a native checkmark + grey 'Duration' section header on macOS 27.0. `Section` header rendering relies on macOS 14+ NSMenuItem.sectionHeader (deployment target is 14, not re-tested on 14.x). (5) Refresh assets/screenshot1.png afterwards (README line 8) since the dots become checkmarks. (6) Related, out of this finding's scope: the Start/Stop `Label(..., systemImage: "play.fill"/"stop.fill")` at lines 48-51 is invisible on macOS 27.0 for the same NSSymbolImageRep reason (purely decorative; consider dropping the systemImage or rendering it as a bitmap like `statusDot`); the status dot at line 34 is a bitmap and renders correctly, leave it.

---

### In-process IOPMAssertion would remove the child process, the orphan risk and the termination-race machinery

- **Location:** `Sources/NoSleep/CaffeinateManager.swift:111`
- **Severity / category:** medium / improvement
- **Votes:** reproduce:ok(0.8), skeptic:ok(0.5), impact:ok(0.7)

**What is wrong.** caffeinate is a thin wrapper around `IOPMAssertionCreateWithProperties`. Calling IOKit directly is strictly more robust: powerd binds an assertion to the creating process, so it disappears on any exit (SIGKILL/crash) with no `-w` hack; `kIOPMAssertionTimeoutKey` + `kIOPMAssertionTimeoutActionKey = kIOPMAssertionTimeoutActionRelease` gives the `-t` behaviour; there is no background `terminationHandler` thread hop, so `runToken`/`stoppedByUser` and the stale-termination race documented in the spec disappear (expiry is the app's own timer reaching zero, which then calls `postCompletion`); `pmset -g assertions` attributes the assertion to 'NoSleep' with a descriptive name; and there is no dependency on `/usr/bin/caffeinate`. Verified in a Swift probe: `import IOKit.pwr_mgt`; `IOPMAssertionCreateWithProperties([kIOPMAssertionTypeKey: kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionNameKey: "NoSleep session", kIOPMAssertionLevelKey: kIOPMAssertionLevelOn, kIOPMAssertionTimeoutKey: 3.0, kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionRelease] as CFDictionary, &id)` returned kIOReturnSuccess, showed up in `pmset -g assertions`, and was gone 4 s later. `PreventUserIdleDisplaySleep` (what `-d` creates) implies idle system sleep prevention, matching `-d -i`. Trade-off: README, the article and the spec's verification steps (`pgrep caffeinate`) all describe the wrapper design, so this is a deliberate architecture change; F3's `-w` covers the critical orphan case if the wrapper stays.

**How it fails.** Every failure mode that exists only because there is a separate child process: orphaned assertion after crash/force-quit (F3), `proc.run()` throwing and leaving partial state (F31), the misattributed external-kill notification (F10), and the async termination race that required the runToken guard.

**Suggested fix.**

Replace the child-process lifecycle in Sources/NoSleep/CaffeinateManager.swift with in-process powerd assertions (verified to build warning-free in Swift 6 mode and pass tests in a temp copy):

1. Add `import IOKit.pwr_mgt` (line 19-20). Delete `process`, `stoppedByUser`, `runToken` (:74-77), `shouldNotifyOnCompletion` (:58-72), the `terminationHandler` (:123-127), `handleTermination` (:186-209). Add:
```swift
/// Mirror `caffeinate -d -i`: BOTH assertion types (the display one alone stops covering
/// idle system sleep once the display is off for another reason / in Dark Wake).
nonisolated static let assertionTypes: [String] = [          // constants import as String, not CFString
    kIOPMAssertionTypePreventUserIdleSystemSleep,
    kIOPMAssertionTypePreventUserIdleDisplaySleep,
]
nonisolated static func assertionProperties(type: String, duration: SleepDuration) -> [String: Any] {
    var p: [String: Any] = [
        kIOPMAssertionTypeKey: type,
        kIOPMAssertionNameKey: "NoSleep - \(duration.label)",   // ASCII: pmset mangles non-ASCII
        kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
    ]
    if duration != .indefinite {                                  // powerd releases on time even if the app is stalled
        p[kIOPMAssertionTimeoutKey] = TimeInterval(duration.rawValue)
        p[kIOPMAssertionTimeoutActionKey] = kIOPMAssertionTimeoutActionRelease
    }
    return p
}
private var assertionIDs: [IOPMAssertionID] = []
private var deadline: Date?
```
2. `start()` (:103-145):
```swift
stop()
var ids: [IOPMAssertionID] = []
for type in Self.assertionTypes {
    var id = IOPMAssertionID(kIOPMNullAssertionID)
    guard IOPMAssertionCreateWithProperties(Self.assertionProperties(type: type, duration: selectedDuration) as CFDictionary, &id) == kIOReturnSuccess else {
        ids.forEach { IOPMAssertionRelease($0) }; return          // no partial state (also closes F31)
    }
    ids.append(id)
}
assertionIDs = ids; activeDuration = selectedDuration; isActive = true
if selectedDuration != .indefinite {
    remainingSeconds = selectedDuration.rawValue
    deadline = Date(timeIntervalSinceNow: TimeInterval(selectedDuration.rawValue))
    let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.tick() } }
    RunLoop.main.add(t, forMode: .common)   // keeps counting while the menu is open; expiry is now app-driven
    timer = t
} else { remainingSeconds = 0; deadline = nil }
```
3. `stop()` (:147-157): invalidate timer, `deadline = nil`, `assertionIDs.forEach { IOPMAssertionRelease($0) }` (returns kIOReturnNotFound after a powerd-side timeout — harmless), `assertionIDs = []`, `activeDuration = nil`, `isActive = false`, `remainingSeconds = 0`. No `stoppedByUser`.
4. `tick()` (:177-184):
```swift
guard isActive, let deadline else { return }
remainingSeconds = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
if remainingSeconds == 0, let completed = activeDuration {
    stop()
    notifications.postCompletion(duration: completed)   // only reachable on natural timed expiry: stop()/start() invalidate the timer synchronously
}
```
5. Tests/NoSleepTests/CaffeinateManagerTests.swift: replace the 5 token tests with tests of the pure `assertionProperties(type:duration:)` (timed => TimeoutSeconds == rawValue and TimeoutActionRelease; indefinite => no timeout keys) and `assertionTypes == ["PreventUserIdleSystemSleep","PreventUserIdleDisplaySleep"]` (needs `import IOKit.pwr_mgt`).
6. Docs: README.md:3, :46, :123, :140-145 (describe IOPM assertions; verification becomes `pmset -g assertions | grep NoSleep`); spec :147 and plan :19, :536, :546, :556, :566 replace `pgrep caffeinate`; leave dev-to-article.md as the v1.1.0 write-up or add a one-line 'since v1.2' note. No Package.swift change is needed (IOKit autolinks; universal release build verified).
If the wrapper design is kept instead, apply F3 (`-w \(ProcessInfo.processInfo.processIdentifier)`, verified compatible with `-t`) — but the runToken/terminationHandler machinery then stays.

---

### App always launches inactive; Start at Login + Indefinite gives no protection after login

- **Location:** `Sources/NoSleep/CaffeinateManager.swift:81`
- **Severity / category:** medium / improvement
- **Votes:** reproduce:ok(0.92), skeptic:ok(0.75), impact:ok(0.82)

**What is wrong.** init() (CaffeinateManager.swift:81-86) restores only `selectedDuration`; nothing on the process-start path (NoSleepApp.swift:22-34 has no launch hook, no NSApplicationDelegateAdaptor, no .task/.onAppear on the label) ever calls start(). The only callers of start() are user gestures: toggle(), changeDuration(), extendOneHour(). So every relaunch — LaunchAgent at login, relaunch after a crash, reboot for a software update — comes up as an outline cup with no caffeinate, regardless of the saved duration. v1.1 changed the mental model to 'picking a duration = protection on' (spec 'Confirmed decisions', Auto-activate row) and README:45 / dev-to-article.md:19 advertise 'Start at Login — optional LaunchAgent for auto-start' without saying what is auto-started; neither the spec table, README Features/Run, nor the article state that the app launches inactive (dev-to-article.md:127 only says 'the preference survives app restarts'). This is exactly the configuration on the review host: ~/Library/LaunchAgents/com.nosleep.app.plist installed, `defaults read com.nosleep.app` = `{ selectedDuration = 0; }` (Indefinite), NoSleep PID 1456 launched by launchd (PPID 1) at 16:13:11 Sep 9 ~1 min after console login, and its `caffeinate -d -i` child (PID 65684) started at 17:50:31 Sep 10 — ~25 hours later, when the user clicked. Fix verified trivial in a temp copy with a probe bundle ID: persisting a Bool and attaching `.onAppear { manager.startOnLaunchIfNeeded() }` to the MenuBarExtra label spawned `/usr/bin/caffeinate -d -i` within seconds of exec'ing the binary directly (as the LaunchAgent does) with no interaction; with the flag off, no child appeared. This is a product decision the spec never made.

**How it fails.** Enable Start at Login, pick Indefinite (cup fills, caffeinate running), then log out and back in (or the Mac restarts for a software update). launchd execs NoSleep; init() reads selectedDuration=0 and nothing calls start(). Menu bar shows the outline cup, `pgrep -P $(pgrep -x NoSleep) caffeinate` is empty, and the Mac idle-sleeps on its normal schedule until the user notices, opens the menu and clicks a duration. Reproduced empirically: control build launched via direct exec produced no caffeinate child; the same build with a persisted activateOnLaunch flag and a label .onAppear hook produced a `caffeinate -d -i` child without any click.

**Suggested fix.**

Add an opt-in "Activate on Launch" preference (default off), persisted like selectedDuration, and fire it once from the MenuBarExtra label's .onAppear. Total ~22 lines across three files; verified to compile warning-free under Swift 6 language mode and to leave all 5 tests green.

1) Sources/NoSleep/CaffeinateManager.swift
   - After the selectedDuration property (line 56) add:
     /// Opt-in: start a session with the saved duration as soon as the app
     /// launches (covers LaunchAgent logins, where nobody clicks anything).
     @Published var activateOnLaunch: Bool {
         didSet { UserDefaults.standard.set(activateOnLaunch, forKey: "activateOnLaunch") }
     }
   - Next to `private var activeDuration: SleepDuration?` (line 78) add:
     private var didRunLaunchHook = false
   - In init() after line 83 add:
     self.activateOnLaunch = UserDefaults.standard.bool(forKey: "activateOnLaunch")
   - After cleanup() (line 175) add:
     /// One-shot launch hook, invoked when the menu-bar item first appears.
     func startOnLaunchIfNeeded() {
         guard !didRunLaunchHook else { return }
         didRunLaunchHook = true
         guard activateOnLaunch, !isActive else { return }
         start()
     }

2) Sources/NoSleep/NoSleepApp.swift, label closure (lines 30-32): append the modifier
     Image(systemName: caffeinateManager.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
         .onAppear { caffeinateManager.startOnLaunchIfNeeded() }
   (.onAppear on the status-item label fires when MenuBarExtra creates the NSStatusItem at launch, including launchd exec; the didRunLaunchHook guard makes any re-appearance harmless. Do NOT call start() from init(): side effects in an initializer would also spawn caffeinate in any future test that constructs the manager.)

3) Sources/NoSleep/MenuBarView.swift, after the Start at Login Toggle (line 87), before the Divider:
     Toggle("Activate on Launch", isOn: $manager.activateOnLaunch)
         .padding(.horizontal, 8)
         .padding(.vertical, 2)
   Keep it independent of Start at Login (peer apps KeepingYouAwake/Amphetamine use two separate toggles; some users want only the icon at login).

4) Docs: README.md:45 -> "Start at Login — optional LaunchAgent that launches NoSleep at login (the app comes up inactive unless Activate on Launch is also on)"; add a bullet at README.md:75-76 "Activate on Launch — start a session with your saved duration every time NoSleep launches"; mirror in dev-to-article.md Features list (:19). Append a row to the spec's Confirmed decisions table (docs/superpowers/specs/...design.md:48-52) or note it in a follow-up spec: "Launch behavior: app launches inactive by default; opt-in Activate on Launch starts the saved duration."

Out of scope (deliberately): persisting a session deadline and resuming with -t <remaining>. It adds state plus a clock edge case for little gain; starting a fresh session of the saved duration matches peer behavior and is what a login-time user expects.

---

### Session expiry leaves no in-app trace; completion depends solely on a Focus-gated banner

- **Location:** `Sources/NoSleep/CaffeinateManager.swift:204`
- **Severity / category:** medium / bug
- **Votes:** reproduce:ok(0.8), skeptic:REFUTE(0.75), impact:ok(0.8)

**Reviewer note.** The skeptic lens classifies this as a product proposal that amends three recorded spec decisions (notification as the completion signal, menu-bar label unchanged). It is listed as an improvement, not a defect. The underlying observation that Focus modes and display mirroring suppress the banner is accurate.

**What is wrong.** handleTermination() (CaffeinateManager.swift:198-204) wipes activeDuration, remainingSeconds and isActive and records neither what ended nor when; the only artifact of a natural expiry is the UNUserNotification posted at :207. Three user-visible consequences share this root cause: (a) MenuBarView.swift:35-37 renders the identical 'Inactive' + grey dot for 'never started', 'user pressed Stop' and 'expired', and the Duration radio still highlights the expired preset, so the menu implies the duration is still in effect; (b) the menu-bar label (NoSleepApp.swift:30-32) is binary on isActive, so the one surface visible without interaction gives no cue to open the menu after an unnoticed expiry; (c) postCompletion() (NotificationManager.swift:54) builds a default .active interruption-level notification, which macOS suppresses under any Focus mode (default-deny for newly installed apps, including Focus mirrored from an iPhone) and when 'Allow notifications when mirroring or sharing the display' is OFF (the default) — i.e. exactly the README's headline presentation use case. A denied or never-answered permission prompt, or a Banner-style alert that auto-dismisses while the user is away/locked, drops it too. In all of those cases spec goal #3 ('nothing tells the user') is unmet and the only 'Extend 1 hour' affordance (NotificationManager.swift:41-43) is unreachable. The approved spec compounds this: 'Risks & verification' (spec :125-134) names ad-hoc signing as the 'primary risk' and checklist item 5 (:143) only checks the happy path where the banner is visible, so future implementers keep being steered to the banner as sole completion signal. Verified in a scratch copy: a `@Published private(set) var lastEnded: EndedSession?` (duration + endedAt + pure summary()) set in handleTermination under the existing `notifiable` guard, cleared in start(), plus a Text line and an Extend button in the menu, compiles under Swift 6 and is unit-testable without UNUserNotificationCenter. Verified with NSImage(systemSymbolName:) that `cup.and.saucer.badge.*` do not exist, while `moon.zzz`, `clock.badge.exclamationmark` and `cup.and.heat.waves` do, and MenuBarExtra labels accept `HStack { Image; Text }`.

**How it fails.** User starts a '2 hours' session, then presents with the display mirrored (or a Work/Do Not Disturb Focus is on, possibly mirrored from their iPhone). caffeinate exits at 2:00; the banner is suppressed; handleTermination resets everything. The menu bar shows the same hollow cup it shows when NoSleep was never started, so nothing prompts the user to look; if they do open the menu they see 'Inactive', grey dot, '2 hours' still selected, no indication protection lapsed or when, and no Extend item. The Mac idle-sleeps on stage a few minutes later.

**Suggested fix.**

Verified to compile and pass tests under Swift 6 in a scratch copy (4 files, ~50 lines).

1) Sources/NoSleep/CaffeinateManager.swift
- After the SleepDuration enum (before line 48), add:
```swift
/// A timed session that expired naturally (not stopped by the user).
struct EndedSession: Equatable, Sendable {
    let duration: SleepDuration
    let endedAt: Date
    /// e.g. "2 hours session ended at 14:32"
    func summary() -> String {
        "\(duration.label) session ended at \(endedAt.formatted(date: .omitted, time: .shortened))"
    }
}
```
- After `@Published var isActive = false` (line 50), add:
```swift
/// Set when a timed session expires naturally; cleared on the next start().
/// In-app record of the expiry that does not depend on the notification being delivered.
@Published private(set) var lastEnded: EndedSession?
```
- In start(), directly after `isActive = true` (line 136) add `lastEnded = nil` (placed after `proc.run()` succeeds so a failed launch does not erase the cue).
- In handleTermination(), change lines 206-208 to:
```swift
if notifiable, let completed {
    lastEnded = EndedSession(duration: completed, endedAt: .now)
    notifications.postCompletion(duration: completed)
}
```

2) Sources/NoSleep/MenuBarView.swift
- Replace the status label body (lines 33-38) with:
```swift
HStack(spacing: 6) {
    Image(nsImage: MenuBarView.statusDot(color: statusDotColor))
    Text(statusText)
}
```
- Add two computed properties (e.g. after `body`, before statusDot):
```swift
private var statusText: String {
    if manager.isActive { return "Active — \(manager.formattedRemaining) left" }
    if let ended = manager.lastEnded { return ended.summary() }
    return "Inactive"
}
private var statusDotColor: NSColor {
    if manager.isActive { return .systemGreen }
    if manager.lastEnded != nil { return .systemOrange }
    return .tertiaryLabelColor
}
```
- Change `static func statusDot(active: Bool)` (line 105) to `static func statusDot(color: NSColor)` and line 109 to `color.setFill()`; update the doc comment to "green = active, orange = expired, grey = inactive". Keeping the ended text inside the existing Button means it renders in normal (black) menu text and clicking it still toggles (starts, which clears lastEnded). Do NOT add a separate "Extend 1 hour" menu button — Start and the "1 hour" duration row (auto-activates) already provide that action; the gap is the cue, not the action.

3) Sources/NoSleep/NoSleepApp.swift
- Replace lines 30-32 with `Image(systemName: menuBarSymbol)` and add to the struct:
```swift
/// Filled cup while active; clock badge after a timed session expired (until the
/// next start) so an unnoticed expiry has a cue even when the notification was
/// suppressed (Focus, display mirroring, denied permission); hollow cup otherwise.
private var menuBarSymbol: String {
    if caffeinateManager.isActive { return "cup.and.saucer.fill" }
    if caffeinateManager.lastEnded != nil { return "clock.badge.exclamationmark" }
    return "cup.and.saucer"
}
```
(`clock.badge.exclamationmark` and `moon.zzz` both exist on macOS 14; `cup.and.saucer.badge.*` do not. Avoid appending Text to the label — the spec explicitly declines text in the menu bar.)

4) Tests/NoSleepTests/CaffeinateManagerTests.swift — add a locale-independent test:
```swift
func testEndedSessionSummaryNamesDurationAndTime() {
    let ended = EndedSession(duration: .twoHours, endedAt: Date(timeIntervalSince1970: 1_800_000_000))
    let summary = ended.summary()
    XCTAssertTrue(summary.hasPrefix("2 hours session ended at "), summary)
    XCTAssertGreaterThan(summary.count, "2 hours session ended at ".count)
}
```

5) Do NOT add `content.interruptionLevel = .timeSensitive` in NotificationManager.postCompletion: without the `com.apple.developer.usernotifications.time-sensitive` entitlement it is silently treated as `.active`, and adding that entitlement to the ad-hoc `codesign --sign -` bundle in build.sh:63 risks the app being killed at launch. The in-app cue is the fix.

6) docs/superpowers/specs/2026-07-01-menu-activation-and-notifications-design.md
- Confirmed decisions table: add row "Completion fallback | A natural timed expiry is also recorded in-app (`lastEnded`): the status line reads '<duration> session ended at <time>' with an orange dot and the menu-bar glyph becomes `clock.badge.exclamationmark` until the next start. In-memory only (reset on relaunch)."
- Line 108 ("Menu-bar label unchanged") → note the third, expired-state glyph.
- Risks & verification: add "Notification delivery is not guaranteed (Focus modes incl. iPhone-mirrored Focus, 'Allow notifications when mirroring or sharing the display' off by default, denied/unanswered permission, banner auto-dismiss while the user is away); the in-app ended state is the fallback."
- Verification checklist: add item 8: "Enable Do Not Disturb, let a (shortened) timed session expire without interacting: menu-bar glyph changes to the clock badge; opening the menu shows the ended line with an orange dot; picking a duration or Start clears both."
- Optionally extend README.md:145 with one sentence describing the ended-state indicator.

---

### Permission is requested at launch with no context and both requestAuthorization and add(request) discard their errors; a denial silently kills the completion/Extend feature

- **Location:** `Sources/NoSleep/NotificationManager.swift:63`
- **Severity / category:** medium / bug
- **Votes:** reproduce:ok(0.82), skeptic:REFUTE(0.8), impact:ok(0.8)

**Reviewer note.** Requesting at launch is the approved spec decision, and moving it later can drop the Extend response on a cold relaunch. Keep the launch-time request; the actionable part is logging the `granted`/`error` results, checking the result of `add(request)`, and surfacing a denied status in the menu.

**What is wrong.** `CaffeinateManager.init()` requests authorization as a side effect of `@StateObject` creation, so the system dialog appears the instant the app launches — including at login via the LaunchAgent — before the user knows what NoSleep would notify about (the pattern Apple's HIG says leads to reflexive denial). `requestAuthorization(options:) { _, _ in }` (line 49) ignores both `granted` and `error`, `UNUserNotificationCenter.current().add(request)` (line 63) has no completion handler, and nothing in the menu reflects notification status. When authorization is `.denied` or still `.notDetermined` (dialog dismissed, or launched as a login item with the prompt never answered), `add` fails with `UNErrorDomain` code 1 (notificationsNotAllowed) and nothing is logged; `postCompletion` looks like it succeeded. The spec's headline feature (completion banner + 'Extend 1 hour') then never appears and cannot be diagnosed from the app.

**How it fails.** First launch: a permission alert pops up over whatever the user is doing; they click 'Don't Allow' (common for an app they just installed and do not yet understand). Weeks later a 4-hour session ends: no banner, no sound, no Extend option, no log line. The user files a 'notifications don't work' bug; the developer cannot tell whether delivery failed, authorization failed, or the notify decision was wrong.

**Suggested fix.**

Compiled and tested variant (Swift 6 mode, zero warnings, 5/5 tests pass). Four files.

1) Sources/NoSleep/NotificationManager.swift — replace the class body:

```swift
import AppKit            // NSWorkspace
import Foundation
import os                // Logger
import UserNotifications

@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private static let log = Logger(subsystem: "com.nosleep.app", category: "notifications")
    private let categoryID = "SESSION_COMPLETE"
    private let extendActionID = "EXTEND_1H"
    private var didConfigure = false
    private var didRequest = false

    /// Last known authorization status; `.denied` drives the menu hint.
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    var onExtend: (() -> Void)?

    /// Call once at launch: delegate + category only. Does NOT prompt.
    func configure() {
        guard !didConfigure else { return }
        didConfigure = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let extend = UNNotificationAction(identifier: extendActionID, title: "Extend 1 hour", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: categoryID, actions: [extend],
                                                                 intentIdentifiers: [], options: [])])
        Task { await refreshAuthorizationStatus() }
    }

    /// Prompt once per process (no-op if already authorized/denied); refresh status on later calls.
    func requestAuthorizationIfNeeded() {
        configure()
        guard !didRequest else { Task { await refreshAuthorizationStatus() }; return }
        didRequest = true
        Task {   // inherits @MainActor, so the property write after `await` is isolated
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                Self.log.info("authorization granted=\(granted, privacy: .public)")
            } catch {
                Self.log.error("requestAuthorization failed: \(error.localizedDescription, privacy: .public)")
            }
            await refreshAuthorizationStatus()
        }
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func postCompletion(duration: SleepDuration) {
        let content = UNMutableNotificationContent()
        content.title = "NoSleep"
        content.body = "Your \(duration.label) session has ended."
        content.categoryIdentifier = categoryID
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            do { try await UNUserNotificationCenter.current().add(request) }
            catch {
                Self.log.error("add failed: \(error.localizedDescription, privacy: .public)")
                await refreshAuthorizationStatus()
            }
        }
    }

    func openNotificationSettings() {
        // Verified: LaunchServices resolves this to System Settings.app on macOS 14+; optional "?id=com.nosleep.app" also resolves.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    // willPresent / didReceive delegate methods unchanged (lines 66-85).
}
```

2) Sources/NoSleep/CaffeinateManager.swift
- line 85: `notifications.requestAuthorization()` -> `notifications.configure()` (delegate + category must still be registered at launch so the Extend action round-trips).
- after line 121 (`activeDuration = selectedDuration`): add `if selectedDuration != .indefinite { notifications.requestAuthorizationIfNeeded() }` — the prompt now appears when the user picks a timed duration (context: "we will tell you when this ends"), and each later timed start refreshes the status so the menu hint disappears once the user re-enables alerts in System Settings.
  (If you prefer to keep the spec's request-at-launch behaviour, keep `requestAuthorization()`'s original call site but still adopt the logging + status parts; otherwise update docs/superpowers/specs/...-design.md lines 109-110 to "on first timed start".)

3) Sources/NoSleep/MenuBarView.swift
- line 23: add `@ObservedObject var notifications: NotificationManager` (nested ObservableObjects do not propagate through `@ObservedObject var manager`, so it must be observed directly).
- before the Quit `Divider()` at line 89:
```swift
if notifications.authorizationStatus == .denied {
    Divider()
    Button("Turn On Completion Alerts\u{2026}") { notifications.openNotificationSettings() }
        .padding(.horizontal, 4)
}
```
  (A Button renders as a normal clickable menu item; a plain Text would be greyed out per the spec's own .menu-style note.)

4) Sources/NoSleep/NoSleepApp.swift line 28:
`MenuBarView(manager: caffeinateManager, notifications: caffeinateManager.notifications, loginManager: loginManager)`

Optional follow-up: add a line to README.md "Features/Usage" saying completion alerts require allowing notifications, and how to re-enable them (System Settings > Notifications > NoSleep).

---

### statusDot uses deprecated NSImage.lockFocus (not resolution-independent) and is re-rasterised on every body evaluation

- **Location:** `Sources/NoSleep/MenuBarView.swift:108`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.85)

**What is wrong.** `lockFocus`/`unlockFocus` are marked `API_DEPRECATED("This method is incompatible with resolution-independent drawing and should not be used. Instead, use +[NSImage imageWithSize:flipped:drawingHandler:] ...", macos(10.0, API_TO_BE_DEPRECATED))` in the SDK's NSImage.h (no compiler warning yet). Probe shows the result is an `NSCGImageSnapshotRep` 9x9 @ 18 px, a bitmap baked at the main display's scale and under whatever `NSAppearance.currentDrawing()` was when `body` ran, not when the menu draws. Because the status title changes every second while the menu is open (live update confirmed), `statusDot(active:)` allocates an offscreen context and bitmap once per second for an image with exactly two possible states. `image.isTemplate = false` is the default and can go.

**How it fails.** MacBook lid closed driving a 1x external display as main plus a 2x display: the dot is rasterised at 9x9 px and appears blurry on the 2x display (or wastes 4x pixels the other way). Auto appearance flips at sunset while the menu is open: the grey `tertiaryLabelColor` baked into the bitmap lags the menu's appearance until the next body re-evaluation. Meanwhile a bitmap is allocated every tick.

**Suggested fix.**

In Sources/NoSleep/MenuBarView.swift replace lines 103-114 with two cached, resolution-independent images built via the block-based initializer, and change line 34 to select between them. Verified to compile in the repo's Swift 6 mode (View is @MainActor, so the non-Sendable NSImage statics are MainActor-isolated; do not move them to file-scope globals or they will fail strict-concurrency checks):

```swift
    // line 34
    Image(nsImage: manager.isActive ? Self.activeDot : Self.inactiveDot)

    // replaces statusDot(active:)
    /// Resolution-independent status dots. The drawing handler runs each time
    /// the image is drawn, so backing scale and appearance resolve at draw time
    /// (lockFocus bakes a fixed-scale bitmap and is slated for deprecation).
    private static let activeDot = dot(NSColor.systemGreen)
    private static let inactiveDot = dot(NSColor.tertiaryLabelColor)

    private static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 9, height: 9), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }
```

Drop `image.isTemplate = false` (already the default). The handler only touches an immutable NSColor and a locally created NSBezierPath, so it is safe under NSImage.h's note that the block "may be invoked whenever and on whatever thread the image itself is drawn on". Optional: keep `statusDot(active:)` as a thin wrapper returning the cached image if the name is referenced elsewhere (grep shows it is only used at line 34).

---

### All padding/frame/spacing modifiers are no-ops in the .menu-style MenuBarExtra (dead code)

- **Location:** `Sources/NoSleep/MenuBarView.swift:100`
- **Severity / category:** low / simplification
- **Votes:** single:ok(0.92)

**What is wrong.** In the default `.menu` style SwiftUI bridges the content into plain `NSMenuItem`s; nothing is laid out by SwiftUI. Verified with a probe on this exact view: no generated item has a custom `view`, and the menu came out 232 pt wide, sized from the longest title plus the ⌘ column, ignoring `.frame(width: 220)`. Therefore `.padding(.horizontal, 4)` (lines 40, 54, 76, 97), `.padding(.horizontal, 8)`/`.padding(.top, 2)`/`.padding(.vertical, 2)` (lines 62-63, 86-87), `.padding(.vertical, 8)` and `.frame(width: 220)` (99-100), `VStack(alignment:spacing: 4)` (26) and `HStack(spacing: 6)` (33) have no effect and mislead the next reader. What does survive the bridge and should be kept: `.font(.caption)` and `.foregroundStyle(.secondary)` on the 'Duration:' Text are honoured via `attributedTitle` (probe: 10 pt SF, 50% alpha), and `.keyboardShortcut` becomes a real key equivalent.

**How it fails.** A maintainer widens `.frame(width:)` or adjusts padding expecting the menu to change; nothing happens and time is lost debugging. No runtime failure.

**Suggested fix.**

In Sources/NoSleep/MenuBarView.swift: (1) delete the inert layout modifiers — `.padding(.horizontal, 4)` at lines 40, 54, 76, 97; `.padding(.horizontal, 8)` + `.padding(.top, 2)` at 62-63; `.padding(.horizontal, 8)` + `.padding(.vertical, 2)` at 86-87; `.padding(.vertical, 8)` + `.frame(width: 220)` at 99-100. (2) Change `VStack(alignment: .leading, spacing: 4)` (line 26) to plain `VStack` and `HStack(spacing: 6)` (line 33) to plain `HStack` (or make the status row a `Label { Text(...) } icon: { Image(nsImage: ...) }` to mirror the Start/Stop button — either bridges to item.image + title identically). (3) Optionally drop `.font(.caption2)` on the duration-row `Image(systemName:)` at line 72 — the bridged NSImage was 15x15 with and without it. (4) KEEP `.font(.caption)` and `.foregroundStyle(.secondary)` on `Text("Duration:")` (lines 60-61; they survive as attributedTitle font/color) and both `.keyboardShortcut` calls (lines 53, 96; they become real key equivalents). (5) Add a one-line comment above `body`, e.g. `// .menu-style MenuBarExtra bridges this tree into NSMenuItems: padding/frame/spacing are ignored. Switch to .menuBarExtraStyle(.window) if custom layout is ever needed.` so the next reader does not reintroduce them. Verification: `swift build` passes and the generated menu is byte-for-byte the same structure (17 items, 175x366, same images/shortcuts/attributed title) as before the change, as measured in Variant C; visually open the menu once to confirm.

---

### Indefinite status renders as 'Active — ∞ left' and the ∞ branch keys off selectedDuration instead of the running session's activeDuration

- **Location:** `Sources/NoSleep/CaffeinateManager.swift:90`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.6)

**What is wrong.** Two problems in the same branch. (1) Wording: `formattedRemaining` returns '∞' and MenuBarView.swift:36 interpolates it into the timed template, producing 'Active — ∞ left' (confirmed in a probe's item dump); 'infinity left' reads like a broken countdown rather than a deliberate no-timeout mode, and with F2 it is currently the first status text most users see. The spec asked for the ∞ glyph; the 'left' suffix is an artifact of sharing one format string. (2) Variable: the branch consults `selectedDuration` (the menu radio) whereas `handleTermination` and the notification path use `activeDuration` (the session actually launched). They cannot diverge today only because every writer of `selectedDuration` immediately calls `start()`; `selectedDuration` is a public `@Published var` and nothing enforces the invariant, so the first code that sets the radio without restarting (a Picker binding, the preference split in F43, or making selection not auto-start) would show a timed session as '∞' or an indefinite one as '0s'. `start()` likewise re-reads `selectedDuration` for `-t`/timer decisions rather than the captured `activeDuration`.

**How it fails.** User selects Indefinite, reopens the menu and reads 'Active — ∞ left'. Any future `manager.selectedDuration = .indefinite` while a 2h session is active -> status reads 'Active — ∞ left' while caffeinate has a 2h `-t`; conversely selecting a timed value during an indefinite run shows 'Active — 0s left'.

**Suggested fix.**

Derive everything the running session displays from `activeDuration`, capture the duration once in `start()`, and move the status wording into a pure, testable function (same pattern as the existing `shouldNotifyOnCompletion`). Keep the ∞ glyph to honor spec line 48, but drop the "left" suffix for indefinite.

CaffeinateManager.swift:
```swift
// replace lines 88-101
var formattedRemaining: String {
    guard isActive, let d = activeDuration, d != .indefinite else { return "" }
    let h = remainingSeconds / 3600, m = (remainingSeconds % 3600) / 60, s = remainingSeconds % 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m \(s)s" }
    return "\(s)s"
}

/// Menu status line. Pure so it is unit-testable without constructing the manager
/// (whose init touches UNUserNotificationCenter and aborts under xctest).
nonisolated static func statusText(isActive: Bool, activeDuration: SleepDuration?, remaining: String) -> String {
    guard isActive, let d = activeDuration else { return "Inactive" }
    return d == .indefinite ? "Active — ∞ (no time limit)" : "Active — \(remaining) left"
}
var statusText: String { Self.statusText(isActive: isActive, activeDuration: activeDuration, remaining: formattedRemaining) }

// in start(), after stop()/token bump:
let duration = selectedDuration          // capture once
activeDuration = duration
var args = ["-d", "-i"]
if duration != .indefinite { args += ["-t", "\(duration.rawValue)"]; remainingSeconds = duration.rawValue } else { remainingSeconds = 0 }
...
if duration != .indefinite { timer = Timer.scheduledTimer(...) }
```
(Also set `activeDuration = nil` in `stop()` next to `isActive = false` so a stopped session cannot leak its duration into the status.)

MenuBarView.swift:35-37 -> `Text(manager.statusText)`.

Tests (Tests/NoSleepTests/CaffeinateManagerTests.swift) — add pure cases:
```swift
func testStatusIndefinite() { XCTAssertEqual(CaffeinateManager.statusText(isActive: true, activeDuration: .indefinite, remaining: ""), "Active — ∞ (no time limit)") }
func testStatusTimed()      { XCTAssertEqual(CaffeinateManager.statusText(isActive: true, activeDuration: .twoHours, remaining: "2h 0m"), "Active — 2h 0m left") }
func testStatusInactive()   { XCTAssertEqual(CaffeinateManager.statusText(isActive: false, activeDuration: nil, remaining: ""), "Inactive") }
```
Update docs/superpowers/plans/...:566 expected string ("Active — ∞ left") to the new wording so the manual checklist stays accurate. Do not use `private(set)` on `selectedDuration` — a future Picker binding legitimately needs to write it; deriving the display from `activeDuration` is what removes the coupling.

---

### 'Extend 1 hour' permanently overwrites the user's saved preferred duration via selectedDuration.didSet

- **Location:** `Sources/NoSleep/CaffeinateManager.swift:169`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.85)

**What is wrong.** `extendOneHour()` assigns `selectedDuration = .oneHour`, whose `didSet` persists to UserDefaults. The spec only requires that the menu radio show '1 hour' for the extended session; silently changing the default that Start/the status-line click will use on every future launch is a side effect a user is unlikely to expect from a one-off 'extend' tap.

**How it fails.** User's habitual setting is 8 hours. One evening they tap 'Extend 1 hour'. Next morning they open NoSleep and click Start (or the status line) expecting their usual 8 hours; they get 1 hour and the Mac sleeps mid-workday.

**Suggested fix.**

Keep `selectedDuration` (and its `didSet` persistence) as the user's saved preference, and make Extend a one-off session that never assigns it. Derive what the menu highlights from the running session instead. Compile-verified (Swift 6 strict concurrency, 5/5 tests pass):

Sources/NoSleep/CaffeinateManager.swift
```swift
// :78  expose the running session's duration to the view
@Published private(set) var activeDuration: SleepDuration?

// new: what the radio should highlight — running session while active, else the saved preference
var displayedDuration: SleepDuration { activeDuration ?? selectedDuration }

// :90  (also resolves F33)
if activeDuration == .indefinite { return "∞" }

// :103  start() takes an optional one-off duration
func start(duration: SleepDuration? = nil) {
    stop()
    let duration = duration ?? selectedDuration
    ... // replace every `selectedDuration` inside start() with `duration`
    //   (:114-116 args/-t/remainingSeconds, :121 activeDuration = duration, :138 timer guard)
}

// :147  stop(): add `activeDuration = nil` so displayedDuration reverts immediately on Stop

// :168
func extendOneHour() {
    start(duration: .oneHour)   // one-off session; saved preference untouched
}
```

Sources/NoSleep/MenuBarView.swift:70
```swift
Image(systemName: manager.displayedDuration == duration ? "circle.inset.filled" : "circle")
```

Behavior after fix: tapping "Extend 1 hour" runs a 1-hour session and the radio shows "1 hour" while it runs (spec :52 intent preserved); when it ends, the radio and Start revert to the user's saved preference (e.g. 8 hours) both within the same app run and after relaunch. `changeDuration(_:)` remains the only path that persists.

Minimal alternative if you prefer not to touch the view: drop the `didSet`, persist explicitly inside `changeDuration(_:)` only, and leave `extendOneHour()` as-is. This stops the UserDefaults rewrite but leaves in-memory `selectedDuration == .oneHour` for the rest of that app run (Start gives 1h until relaunch), which is why the version above is preferred.

Optionally add a unit test asserting that `extendOneHour()` leaves the "selectedDuration" default unchanged (requires making the UserDefaults instance injectable, since `CaffeinateManager.init` currently also calls `notifications.requestAuthorization()`).

---

### No single-instance guard: LaunchAgent copy plus a manually opened copy run side by side with independent caffeinate children

- **Location:** `Sources/NoSleep/NoSleepApp.swift:22`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.92)

**What is wrong.** Nothing prevents two NoSleep processes. The LaunchAgent execs the binary directly (bypassing LaunchServices' launch-time de-duplication), and the developer/README flow keeps a second bundle in the repo (`open NoSleep.app`) plus one in `~/Applications` (install.sh); the DMG adds a third path. Two instances each spawn their own caffeinate, both persist to the same `selectedDuration` key and the same plist, and quitting one leaves the other's assertion active, so the visible state (one cup icon stopped) no longer reflects whether the Mac can sleep.

**How it fails.** Start at Login is enabled from `~/Applications/NoSleep.app`. The developer rebuilds and runs `open NoSleep.app` from the repo: two cup icons appear; the user starts a session in one and stops it in the other; `pgrep caffeinate` still shows a child and the Mac stays awake.

**Suggested fix.**

Add a race-free single-instance guard that runs before any state is created, in Sources/NoSleep/NoSleepApp.swift (App.init runs before the @StateObject closures, so CaffeinateManager/NotificationManager are never touched by the losing instance):

```swift
@main
struct NoSleepApp: App {
    @StateObject private var caffeinateManager = CaffeinateManager()
    @StateObject private var loginManager = LoginItemManager()

    init() {
        // LaunchServices only de-duplicates by bundle *path*, and the LaunchAgent
        // exec's the binary directly, so two copies (repo, ~/Applications, /Applications)
        // can run at once. Hold an exclusive lock for the process lifetime; the kernel
        // releases it on exit or crash, so there is no stale-lock case.
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoSleep", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = Darwin.open(dir.appendingPathComponent("instance.lock").path,
                             O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK, 0o600)
        if fd < 0 && errno == EWOULDBLOCK {
            exit(0)   // another NoSleep already owns the menu-bar item
        }
        // fd intentionally kept open for the life of the process
    }
    ...
}
```

Simpler alternative (verified working against a launchd-spawned first instance, but has a small window if two copies start simultaneously): in the same init, `let me = ProcessInfo.processInfo.processIdentifier; if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me }) { exit(0) }`. Skip `other.activate()`: an LSUIElement app has no window to bring forward.

Do NOT rely on switching the login item to SMAppService/`open -b` as the fix for this: TEST 2 shows LaunchServices still launches a second copy from a different path, so the README flow (`open NoSleep.app` then `open ~/Applications/NoSleep.app`) would still yield two instances without the in-process guard. Optional hardening in install.sh: after copying, `pkill -x NoSleep` (or `osascript -e 'quit app id "com.nosleep.app"'`) so the stale repo-copy instance is not left running alongside the freshly installed one.

---

### Menu bar icon has no accessibility label; VoiceOver cannot tell active from inactive

- **Location:** `Sources/NoSleep/NoSleepApp.swift:30`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.9)

**What is wrong.** The `MenuBarExtra` label is a bare `Image(systemName:)`, so VoiceOver announces 'cup and saucer' (or 'cup and saucer fill') with no app name and no state. The only cue that a session is running is the fill variant of the glyph, which is invisible to assistive tech and to users who cannot distinguish the two small glyphs.

**How it fails.** A VoiceOver user tabs to the status item: hears 'cup and saucer, button' and cannot tell whether NoSleep is keeping the Mac awake without opening the menu and reading the status line.

**Suggested fix.**

In Sources/NoSleep/NoSleepApp.swift, replace the label at lines 30-32 with an NSImage-backed symbol that carries an explicit accessibility description (SwiftUI's .accessibilityLabel/.help are discarded because MenuBarExtra flattens the label into an NSImage on the NSStatusBarButton):

```swift
} label: {
    // MenuBarExtra (.menu style) flattens this label into an NSImage on the
    // NSStatusBarButton, so SwiftUI .accessibilityLabel/.help are dropped;
    // only the NSImage's own accessibilityDescription reaches VoiceOver.
    Image(nsImage: NSImage(
        systemSymbolName: caffeinateManager.isActive
            ? "cup.and.saucer.fill"
            : "cup.and.saucer",
        accessibilityDescription: caffeinateManager.isActive
            ? "NoSleep: keeping Mac awake"
            : "NoSleep: inactive"
    )!)
}
```

Verified: VoiceOver label becomes "NoSleep: inactive" / "NoSleep: keeping Mac awake"; the image stays a template image at the same rendered size (20x15) so appearance is unchanged; builds cleanly under Swift 6 language mode. Do NOT use `.accessibilityLabel(...)`, `.help(...)`, or `Label(...).labelStyle(.iconOnly)` on the label — all three were tested and have no effect on the status item. A hover tooltip is not achievable through SwiftUI in this configuration; drop that part of the original suggestion. Optional: also update dev-to-article.md/README if they describe the label code.

---

### willPresent omits .list, so a foreground-delivered completion banner is not kept in Notification Center

- **Location:** `Sources/NoSleep/NotificationManager.swift:72`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.85)

**What is wrong.** When `willPresent` is invoked (only when NoSleep is the active app at delivery time), the returned options replace the default presentation. `[.banner, .sound]` shows a transient banner that auto-dismisses after a few seconds and is not added to Notification Center. The whole point of this notification is the actionable 'Extend 1 hour' button; if the user is away for those few seconds the action is unrecoverable. The spec's premise for implementing `willPresent` ('a menu-bar app is effectively always active') is the case where this matters most. When the app is not active the delegate is not consulted and the default (banner + list) applies, hence low severity.

**How it fails.** NoSleep is the active application when a timed session ends (the user just interacted with it); the banner appears for ~5 s while the user is looking away, disappears, and nothing remains in Notification Center to click 'Extend 1 hour'.

**Suggested fix.**

In Sources/NoSleep/NotificationManager.swift:72 change `completionHandler([.banner, .sound])` to `completionHandler([.banner, .list, .sound])` — this is exactly the header's documented replacement for the deprecated `.alert` and makes the foreground-delivery presentation identical to the system default used when NoSleep is not frontmost (banner shown, entry retained in Notification Center so "Extend 1 hour" remains actionable after the banner auto-dismisses). Update the comment on line 66 to e.g. "Show the banner and keep it in Notification Center even when NoSleep is the frontmost app (e.g. after the user clicked a previous notification)". Mirror the change in docs/superpowers/specs/2026-07-01-menu-activation-and-notifications-design.md:75 and docs/superpowers/plans/2026-07-01-menu-activation-and-notifications.md:222 so the approved spec matches the code.

---

### Notification body is ungrammatical for plural labels and the title duplicates the app name

- **Location:** `Sources/NoSleep/NotificationManager.swift:56`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.9)

**What is wrong.** `"Your \(duration.label) session has ended."` interpolates labels like '15 minutes' / '2 hours' as attributive modifiers, producing 'Your 15 minutes session has ended.' / 'Your 2 hours session has ended.' The title 'NoSleep' is redundant because macOS already shows the app name in the banner header, so the banner reads 'NoSleep / NoSleep / Your 2 hours session has ended.' The body also never says what the user actually needs to know: that the Mac can now sleep.

**How it fails.** Every completion banner for 15 min, 30 min, 2/4/8/10 h reads with a grammatical error, and a user glancing at it has to infer 'the Mac may sleep now' from 'session has ended'.

**Suggested fix.**

In Sources/NoSleep/CaffeinateManager.swift, add an attributive form next to `label` (derived from rawValue so it cannot drift from the cases):

    /// Attributive form for prose ("15-minute", "2-hour"). Empty for `.indefinite`.
    var adjectiveLabel: String {
        guard self != .indefinite else { return "" }
        return rawValue % 3600 == 0 ? "\(rawValue / 3600)-hour" : "\(rawValue / 60)-minute"
    }

In Sources/NoSleep/NotificationManager.swift:55-56 replace with:

    content.title = "Session Ended"   // title-case, no period per HIG; the system already shows the app icon
    content.body = "Your \(duration.adjectiveLabel) session is over. Your Mac can sleep again."

(Alternatively drop `content.title` entirely; HIG states the system then shows the app name in the title area, which is what the current hard-coded "NoSleep" achieves anyway. Do not put "NoSleep" in the body either; HIG says to avoid the app name in content.) Optionally add a one-line XCTest asserting `SleepDuration.fifteenMin.adjectiveLabel == "15-minute"` and `.twoHours.adjectiveLabel == "2-hour"`, and update the expected banner text quoted in docs/superpowers/plans/2026-07-01-menu-activation-and-notifications.md:269,556 so the plan matches the shipped copy.

---

### LaunchAgent omits ProcessType, so the login-launched app is classified as a throttled background daemon

- **Location:** `Sources/NoSleep/LoginItemManager.swift:49`
- **Severity / category:** low / bug
- **Votes:** reproduce:ok(0.8), skeptic:ok(0.85), impact:ok(0.85)

**What is wrong.** enable() (lines 49-54) writes a LaunchAgent with only Label/ProgramArguments/RunAtLoad/KeepAlive. With no ProcessType, launchd classifies the login-launched instance as a daemon, not a user-facing app. Verified on the live installed instance: `launchctl print gui/501/com.nosleep.app` reports `spawn type = daemon (3)`, `jetsam priority = 40`, `jetsamproperties category = daemon`, whereas the real macOS menu-bar agents (ControlCenter, Dock, NotificationCenter) report `spawn type = app (1)` and `jetsam priority = 80..100` because their plists set `ProcessType = App` / `LimitLoadToSessionType = Aqua`. launchd.plist(5) states that when ProcessType is unspecified 'the system will apply light resource limits to the job, throttling its CPU usage and I/O bandwidth.' NoSleep is an interactive menu-bar app (SwiftUI menu, 1 Hz countdown Timer, notifications) whose whole job is to keep a caffeinate child alive, and the child inherits the same clamp. An app launched via Finder/LaunchServices — or via SMAppService.mainApp — runs unthrottled; the launchd-launched copy runs in a degraded class. Only relevant if the plist path is kept (see F2).

**How it fails.** Under memory pressure, jetsam kills priority-40 (daemon-band) jobs before real apps (priority 80+); NoSleep is terminated while its 8h caffeinate child is running, which orphans caffeinate (the Mac now never sleeps with no menu-bar control) and drops the pending completion notification. Day-to-day, the login-launched copy runs with background-ish CPU/IO limits: menu open/redraw and notification delivery can lag under load compared with the same binary opened from Finder, the throttling aggravates the countdown Timer drift, and the difference is invisible and undiagnosable from the app.

**Suggested fix.**

PREFERRED (resolves F9 completely; this is the same change F2 asks for, so land it once): replace the body of Sources/NoSleep/LoginItemManager.swift (lines 19-71) with an SMAppService implementation. Verified to compile under this package's Swift 6 mode:

import Foundation
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    @Published var isEnabled: Bool
    @Published var lastError: String?

    init() {
        Self.migrateLegacyLaunchAgent()
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func toggle() {
        do {
            if isEnabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Pre-1.2 builds wrote ~/Library/LaunchAgents/com.nosleep.app.plist, which made launchd
    /// spawn us as a Utility-clamped daemon (all threads at priority 20, jetsam band 40).
    /// Delete it and carry the user's choice over to a real Login Item. Deleting the file is
    /// sufficient: launchd only re-reads LaunchAgents at the next login.
    private static func migrateLegacyLaunchAgent() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.nosleep.app.plist")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
        try? SMAppService.mainApp.register()
    }
}

Then: delete install.sh lines 21-27 (the PlistBuddy path rewrite is dead once no plist exists); update README.md lines 45, 75, 86 and 107-108 to say the app registers itself as a Login Item (System Settings > General > Login Items) and that uninstall is "turn off Start at Login in the menu, or remove NoSleep in Login Items". Caveats to note in the PR: SMAppService.mainApp works for ad-hoc-signed bundles (Login Items shows no developer name) and, like the plist, requires the bundle to stay at the same path; run from ~/Applications as install.sh already does. Optionally surface lastError in MenuBarView so a failed register() is not silent.

FALLBACK (only if the plist path is deliberately kept): in LoginItemManager.swift insert one line after line 53 ("KeepAlive": false,):
            "ProcessType": "Interactive",   // without it launchd clamps every thread to Utility QoS (pri 20)
Verified effect on this OS: spawn type daemon(3) -> interactive(4); main thread 20 -> 31; UI-QoS ceiling 20 -> 37. It does NOT change the jetsam band (40) or thread limit (32) and does not reach app level (46), so do not describe it as "app-level resource limits". Do NOT add "LimitLoadToSessionType": "Aqua" (verified no-op: the agent is only loaded in gui/<uid>). Do NOT use the private "App" value even though launchd currently honours it (app(1), band 100) -- it is undocumented. Because enable() only writes the plist on toggle, existing installs need the key patched in: add to install.sh after line 26
    /usr/libexec/PlistBuddy -c "Add :ProcessType string Interactive" "$PLIST_PATH" 2>/dev/null || true
(or have init() rewrite an existing plist lacking the key). Either way it takes effect at the next login; the currently running instance stays clamped until then.

Also correct the finding text: drop "I/O bandwidth" (I/O policy and darwinbg are unchanged); the "never sleeps" orphan outcome applies only to Indefinite mode (timed runs pass -t, CaffeinateManager.swift:115); the orphan itself is real because Process puts caffeinate in its own process group so launchd's process-group cleanup does not reap it.

---

### LaunchAgent KeepAlive:false never relaunches after a crash; SuccessfulExit:false would

- **Location:** `Sources/NoSleep/LoginItemManager.swift:53`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.72)

**What is wrong.** The LaunchAgent is written with `"KeepAlive": false` (LoginItemManager.swift:53), so launchd runs NoSleep once at login and never again. Today a crash leaves an orphaned caffeinate holding the assertion with no UI (already reported); once the already-proposed `-w <own pid>` fix lands, a crash of NoSleep instead drops protection entirely and nothing brings it back until the next login — there is no icon to click and no notification. `man launchd.plist` documents `KeepAlive = { SuccessfulExit = false }`: 'If false, the job will be restarted in the inverse condition', i.e. only after a non-zero exit or signal death. `NSApplication.terminate` exits 0, so the Quit menu item still sticks, while SIGSEGV/SIGKILL causes a relaunch. This only pays off together with F2 (a relaunched app that comes up inactive restores nothing), and it is not expressible through `SMAppService.mainApp`, so the author must weigh it against the already-recommended SMAppService migration; flagged so the crash-relaunch behaviour is decided deliberately rather than by omission.

**How it fails.** Start at Login enabled, Indefinite session running via LaunchAgent-launched NoSleep with `-w <pid>` applied. NoSleep crashes (or is force-quit from Activity Monitor). caffeinate sees its watched PID vanish and exits; the menu bar icon disappears; launchd consults KeepAlive=false and does nothing. The Mac idle-sleeps 10-20 minutes later during the user's render/download with no indication anything changed, and stays unprotected until the next login.

**Suggested fix.**

In Sources/NoSleep/LoginItemManager.swift:53 replace `"KeepAlive": false,` with `"KeepAlive": ["Crashed": true],` (PropertyListSerialization serializes the nested [String: Bool] fine). Verified behaviour: launchd relaunches NoSleep ~10 s (default ThrottleInterval) after SIGSEGV/SIGBUS/SIGTRAP-style crash signals (incl. Swift runtime traps), while Quit (exit 0), Activity Monitor Quit/Force Quit and `killall NoSleep` are respected and do not bring it back. Use `["SuccessfulExit": false]` only if the author explicitly also wants recovery from Force Quit/SIGKILL and any non-zero exit (verified: relaunches after SIGKILL, SIGSEGV, exit 1; not after exit 0). Land this together with (a) the `caffeinate -w <own pid>` change, otherwise the relaunched instance shows "Inactive" while the orphaned caffeinate still holds the assertion, and (b) the activate-on-launch/restore-last-session change (F2), otherwise the relaunch only restores an inactive icon. Two follow-ups: in `disable()` (line 67) note that removing the plist does not unload the job, so crash-relaunch stays armed until logout — either accept this or call `launchctl disable gui/<uid>/com.nosleep.app` there and `launchctl enable ...` in `enable()` (do NOT `bootout` from inside the app: when launched by launchd the running instance IS the job and would be killed); and keep/strengthen the README uninstall step to `launchctl bootout gui/$(id -u)/com.nosleep.app && rm ~/Library/LaunchAgents/com.nosleep.app.plist`, because a stale plist pointing at a deleted app leaves launchd in a "spawn scheduled / penalty box" retry loop (exit 78 EX_CONFIG) with either KeepAlive dictionary. Add one README line under Start at Login: "If NoSleep crashes, launchd relaunches it within ~10 s; Quit does not relaunch." If the project instead migrates to SMAppService.mainApp, this is not expressible; document that a crash requires relaunching NoSleep manually.

---

### UN delegate install depends on undocumented SwiftUI @StateObject launch timing

- **Location:** `Sources/NoSleep/NoSleepApp.swift:23`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.65)

**What is wrong.** UNUserNotificationCenter documents that the delegate must be assigned before the app finishes launching (applicationWillFinishLaunching/applicationDidFinishLaunching), otherwise the response that launched the app is dropped. Here the only thing that sets `center.delegate` is `CaffeinateManager.init()` → `requestAuthorization()` (NotificationManager.swift:38-39), which runs whenever SwiftUI first materializes the `@StateObject` on line 23. A probe app on this toolchain showed that happens inside SwiftUI's own `applicationWillFinishLaunching`, so it works today, but that ordering is an implementation detail of SwiftUI's MenuBarExtra scene setup, not a contract. Nothing in the code, spec (which even proposes a `.task` on the menu content, which would be too late) or the article (dev-to-article.md:181 asserts the requirement but shows no delegate line) pins it down, and there is no `NSApplicationDelegateAdaptor` to hook the documented point.

**How it fails.** A future SwiftUI/macOS release evaluates MenuBarExtra state lazily (e.g. on first status-item draw after didFinishLaunching), or a refactor moves `requestAuthorization()` to the spec's suggested `.task` on menu content. App not running, user taps 'Extend 1 hour' → app launches, delegate is nil at didFinishLaunching, the response is silently discarded, no session starts, and no error is surfaced.

**Suggested fix.**

Move UN delegate installation to the documented AppKit launch hook via NSApplicationDelegateAdaptor, and let the delegate own the model so the same NotificationManager instance is both the UN delegate and the one CaffeinateManager posts through (verified to compile in Swift 6 mode and to set the delegate at applicationWillFinishLaunching):

1) Sources/NoSleep/NotificationManager.swift -- split the method:
```swift
private var didInstall = false

/// Set the UN delegate and register categories. Must run before the app
/// finishes launching (call from applicationWillFinishLaunching).
func installDelegate() {
    guard !didInstall else { return }
    didInstall = true
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    let extend = UNNotificationAction(identifier: extendActionID, title: "Extend 1 hour", options: [])
    let category = UNNotificationCategory(identifier: categoryID, actions: [extend], intentIdentifiers: [], options: [])
    center.setNotificationCategories([category])
}

/// Permission prompt only; safe any time after installDelegate().
func requestAuthorization() {
    installDelegate()
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
}
```
2) Sources/NoSleep/CaffeinateManager.swift:85 -- delete `notifications.requestAuthorization()` from init (keeps `onExtend` wiring; makes CaffeinateManager constructible in unit tests, matching the intent at NotificationManager.swift:31-33).

3) Sources/NoSleep/NoSleepApp.swift -- replace the App:
```swift
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let caffeinateManager = CaffeinateManager()

    func applicationWillFinishLaunching(_ notification: Notification) {
        caffeinateManager.notifications.installDelegate()   // documented pre-finish-launch point
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        caffeinateManager.notifications.requestAuthorization()
    }
    func applicationWillTerminate(_ notification: Notification) {
        caffeinateManager.cleanup()   // also covers F8 (Cmd-Q / logout / SIGTERM)
    }
}

/// Observing wrapper so the status-item icon still updates now that the
/// manager is not an App-level @StateObject.
struct MenuBarLabel: View {
    @ObservedObject var manager: CaffeinateManager
    var body: some View {
        Image(systemName: manager.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
    }
}

@main
struct NoSleepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var loginManager = LoginItemManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(manager: appDelegate.caffeinateManager, loginManager: loginManager)
        } label: {
            MenuBarLabel(manager: appDelegate.caffeinateManager)
        }
    }
}
```
4) Docs: change spec line 109-110 and plan lines 503-506 to say the delegate is installed in `applicationWillFinishLaunching` (not `.task`/`.onAppear` on menu content, which only runs when the menu first opens -- too late per UNUserNotificationCenter.h:99); in dev-to-article.md:181 add the 3-line AppDelegate/adaptor snippet after the "gotcha" sentence so the article shows how the requirement is actually met.

---

### init() re-types the LaunchAgent path instead of deriving it from plistLabel

- **Location:** `Sources/NoSleep/LoginItemManager.swift:34`
- **Severity / category:** low / simplification
- **Votes:** single:ok(0.85)

**What is wrong.** `init()` (lines 33-34) hard-codes "Library/LaunchAgents/com.nosleep.app.plist" as a second literal instead of using the `plistLabel` constant that `plistURL` (lines 27-30) is built from. The two are only coincidentally identical; `plistURL` cannot be used in init because `isEnabled` is not yet initialized, but the path can be made a `static let` or computed from `plistLabel`. Today this is a latent bug: any rename of the label desynchronizes 'what init checks' from 'what enable()/disable() write and delete'. Moot if the plist path is replaced by SMAppService (F2).

**How it fails.** Label is renamed to e.g. 'com.sergiofarfan.nosleep' in plistLabel only: init() still looks for com.nosleep.app.plist -> isEnabled = false even though enable() just wrote the new plist; user toggles again -> disable() removes the new file, then enable() rewrites it, and the old com.nosleep.app.plist (from a previous version) is never cleaned up, so two agents launch the app at login.

**Suggested fix.**

In Sources/NoSleep/LoginItemManager.swift, make the label and URL static so init() can use them before `isEnabled` is set, and drop the second literal:

```swift
@MainActor
final class LoginItemManager: ObservableObject {
    private static let plistLabel = "com.nosleep.app"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(plistLabel).plist")
    }

    @Published var isEnabled: Bool

    init() {
        self.isEnabled = FileManager.default.fileExists(atPath: Self.plistURL.path)
    }
    // enable(): "Label": Self.plistLabel, write to Self.plistURL, dir = Self.plistURL.deletingLastPathComponent()
    // disable(): removeItem(at: Self.plistURL)
}
```

Verified: compiles warning-free in Swift 6 language mode (static members of a @MainActor class are MainActor-isolated, so no Sendable diagnostics) and all 5 tests pass. Optionally add a one-line comment above `plistLabel` noting that the same identifier is also hard-coded in build.sh:41 (CFBundleIdentifier), install.sh:8 and README.md:108, so a rename must update those too. Skip this change entirely if F2 (migrating to SMAppService.mainApp) is adopted, since the plist path disappears.

---

## 4. Improvements: build and packaging

### Version, bundle ID and app name are duplicated in a quoted heredoc; BUNDLE_ID variable is dead

- **Location:** `build.sh:49`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.9)

**What is wrong.** The Info.plist heredoc is quoted (`'PLIST'`), so nothing is interpolated: the version appears twice (lines 49 and 51), CFBundleIdentifier (line 41) repeats the literal that `BUNDLE_ID` (line 9) holds — `BUNDLE_ID` is never used — and `APP_NAME` is hand-copied into three keys. `LSMinimumSystemVersion` also duplicates Package.swift's `.v14`. A release bump (see commit 47ecdf8) requires editing two lines and it is easy to update one and not the other, giving a DMG whose file name (read from CFBundleShortVersionString by package-dmg.sh:20) disagrees with CFBundleVersion.

**How it fails.** Maintainer bumps CFBundleShortVersionString to 1.2.0 but forgets CFBundleVersion: package-dmg.sh names the file NoSleep-1.2.0.dmg while the bundle reports build 1.1.0; likewise changing BUNDLE_ID at line 9 has no effect on the built app, LaunchAgent label, or `defaults delete` docs.

**Suggested fix.**

build.sh: (1) Near line 9 add `VERSION="1.1.0"` and `MIN_MACOS="14.0"   # keep in sync with Package.swift platforms .macOS(.v14)`; keep BUNDLE_ID. (2) Change line 32 to an unquoted heredoc `<< PLIST` (body contains no $, backtick or backslash, verified) and replace the literals: CFBundleExecutable/CFBundleName/CFBundleDisplayName -> `${APP_NAME}`, CFBundleIdentifier -> `${BUNDLE_ID}`, CFBundleVersion and CFBundleShortVersionString -> `${VERSION}`, LSMinimumSystemVersion -> `${MIN_MACOS}`. (3) Optionally add a release sanity check rather than deriving the version from git: `if TAG=$(git describe --tags --exact-match 2>/dev/null) && [ "${TAG#v}" != "$VERSION" ]; then echo "Warning: tag $TAG != VERSION $VERSION" >&2; fi`. Do NOT use `git describe --tags --abbrev=0` as the source: HEAD is already 2 commits past v1.1.0 and it would silently stamp 1.1.0 on non-release builds; and never feed long describe output (v1.1.0-2-gf3547fe) into CFBundleVersion, which Apple requires to be period-separated integers. (4) Line 10: `ARCH_FLAGS=(--arch arm64 --arch x86_64)` and use `"${ARCH_FLAGS[@]}"` on lines 13-14. Swift side (this is where the "LaunchAgent label" part of the scenario actually lives; interpolating BUNDLE_ID in build.sh alone does not fix it): LoginItemManager.swift:23 -> `private let plistLabel = Bundle.main.bundleIdentifier ?? "com.nosleep.app"` and make init() (line 33-34) use `plistURL` instead of the second hardcoded path. install.sh:8 can likewise derive the id from the built bundle: `BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")"`. Optional cheap guard in package-dmg.sh after line 20: read CFBundleVersion too and `[ "$VERSION" = "$BUILD" ] || { echo "Version mismatch"; exit 1; }` — structurally redundant once build.sh uses one VERSION, but protects against hand-edited bundles.

---

### Info.plist lacks CFBundleInfoDictionaryVersion, NSHumanReadableCopyright, LSApplicationCategoryType, CFBundleDevelopmentRegion

- **Location:** `build.sh:32`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.72)

**What is wrong.** The hand-written Info.plist omits keys Xcode always emits and Apple's Core Foundation Keys reference lists: `CFBundleInfoDictionaryVersion` ('6.0'), `NSHumanReadableCopyright` (a GPL project whose sources carry a copyright line, yet Finder > Get Info shows nothing), `LSApplicationCategoryType` (`public.app-category.utilities`, used by Finder/Launchpad grouping) and `CFBundleDevelopmentRegion`. Nothing functionally required for UNUserNotificationCenter in an ad-hoc bundle is missing (verified a directly-exec'd ad-hoc bundle with the present keys can obtain the notification center). Do NOT add `NSSupportsSuddenTermination`: with the current design the system would SIGKILL NoSleep at logout/idle without running `cleanup()`, which is exactly the orphan path in F3.

**How it fails.** Finder > Get Info on NoSleep.app shows no copyright and no category; `lsregister -dump` / App Store-style validation tooling flags the missing CFBundleInfoDictionaryVersion; the bundle differs from what every Xcode-produced app ships, which is the baseline most macOS tooling assumes.

**Suggested fix.**

In build.sh, inside the Info.plist heredoc (between line 57 `<true/>` and line 58 `</dict>`), add:

    <key>NSHumanReadableCopyright</key>
    <string>Copyright (C) 2026 Sergio Farfan. Licensed under GPL-3.0-or-later.</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>

The first two are the ones with an observable effect (verified: Spotlight then imports kMDItemCopyright and kMDItemAppStoreCategory/Type = "Utilities"/public.app-category.utilities, which Finder Get Info surfaces as "Copyright" and "Category" and LaunchServices records as `category:`). The last two are inert baseline keys — harmless, keep them for parity with Xcode-built bundles, but do not expect any tooling in this pipeline to complain if they are absent (lsregister does not). Do NOT add NSSupportsSuddenTermination: cleanup() is only wired to the Quit button (MenuBarView.swift:93) and a sudden-termination SIGKILL at logout would also defeat any future applicationWillTerminate-based fix for orphaned caffeinate. Optionally, after rebuilding, verify with: `mdimport -t -d2 NoSleep.app | grep -A2 -E 'kMDItemCopyright|kMDItemAppStoreCategory'`. Drop the "lsregister -dump / App Store validation flags it" wording from the finding — it is not true for this ad-hoc DMG distribution.

---

### SetFile is deprecated (since Xcode 6) and silently skipped when absent; write the FinderInfo xattr directly

- **Location:** `package-dmg.sh:89`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.7)

**What is wrong.** `man SetFile` on this system says '(DEPRECATED) … deprecated with Xcode 6'. The `command -v SetFile` guard means that on a machine without the Xcode tool the volume icon is silently dropped with no message, even though README promises a custom volume icon. Verified that `SetFile -a C` writes exactly the 32-byte `com.apple.FinderInfo` with the kHasCustomIcon bit (0x0400 at byte 8), which `xattr` — always present — can write directly (confirmed with GetFileInfo showing the C attribute).

**How it fails.** Release built on a machine/CI runner where SetFile is missing or removed in a future Xcode: package-dmg.sh prints 'Done!' but the mounted DMG shows the generic disk icon instead of the cup icon, with no warning explaining why.

**Suggested fix.**

Replace package-dmg.sh lines 87-90 with a toolchain-independent write that sets only the kHasCustomIcon bit (preserving any other Finder flags, exactly like `SetFile -a C`) and reports failure instead of swallowing it:

# Volume icon (best effort — layout/background still work without it).
# kHasCustomIcon = 0x0400 in the 16-bit Finder flags at bytes 8-9 of the 32-byte
# com.apple.FinderInfo blob. Written with xattr so no Xcode/CLT tool is required
# (/usr/bin/SetFile is a deprecated xcrun shim that fails without developer tools).
if [ -f "$STAGING/.VolumeIcon.icns" ]; then
    cur="$( { xattr -px com.apple.FinderInfo "$MOUNT_DIR" 2>/dev/null || true; } | tr -d ' \n')"
    [ "${#cur}" -eq 64 ] || cur="$(printf '%064d' 0)"
    flags=$(( 0x${cur:16:4} | 0x0400 ))
    if xattr -wx com.apple.FinderInfo "${cur:0:16}$(printf '%04X' "$flags")${cur:20}" "$MOUNT_DIR"; then
        echo "    Volume icon set."
    else
        echo "    Warning: could not set the volume icon flag; the DMG will show a generic disk icon."
    fi
fi

(If brevity is preferred, the original one-liner `xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "$MOUNT_DIR" || echo "    Warning: ..."` is also byte-identical to SetFile on a freshly created DMG root, where FinderInfo is absent; the variant above is only needed to be safe if anything has already written FinderInfo to the root.) The result was verified on a real HFS+ UDRW image root and persists through `hdiutil detach` / `hdiutil convert`-style reattach.

---

### Window bounds 600x400 include the title bar, so the 600x400 background is ~28 px taller than the content area

- **Location:** `package-dmg.sh:60`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.6)

**What is wrong.** AppleScript `bounds` of a Finder window is the window frame in screen coordinates, including the ~28 pt title bar (toolbar and status bar are hidden by lines 58-59). `{200,120,800,520}` therefore gives a 600x400 frame with a ~600x372 icon-view content area, while generate-art.swift renders the background at exactly 600x400 (line 172) assuming that is the view size. Finder centres an oversized background picture, so ~14 px is clipped top and bottom: the arrow drawn at image y=190 lands at view y≈176 while the icons are centred at y=190 (lines 65-66), and the caption drawn 55 px from the bottom ends up ~41 px from the edge. Not verified empirically (would trigger a Finder Automation TCC prompt), hence lower confidence.

**How it fails.** Open the built DMG: the arrow sits ~14 px above the vertical centre of the NoSleep and Applications icons instead of pointing straight between them, and the bottom caption sits closer to the window edge than designed.

**Suggested fix.**

Minimal fix (package-dmg.sh:58-60), keep the 600x400 art unchanged:
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false        -- new: otherwise a recipient with "Show Path Bar" on loses another ~28 pt of view height
    set the bounds of container window to {200, 120, 800, 548}   -- was 520: 600x428 frame -> 600x400 content on macOS 11-15 (28 pt title bar), 600x396 on macOS 26+ (only the last 4 gradient rows are cut; Finder top-anchors the picture)
Because Finder anchors the background at the top-left and clips the bottom, prefer the image to be >= the view height (a shorter image leaves a visible plain strip at the bottom), so do NOT shrink the render to 372 px unless the design baseline is changed too: generate-art.swift:123 uses sy = h/400, so rendering 600x372 with the current code would move the arrow to h-190*sy (~176.7 px from the top) and actually misalign it with the icons at y=190.
Optional single source of truth: in package-dmg.sh define WIN_W=600 CONTENT_H=400 TITLEBAR=28 and build the bounds as {200, 120, 200+WIN_W, 120+TITLEBAR+CONTENT_H}; have make-icons.sh call `swift scripts/generate-art.swift $WIN_W $CONTENT_H` and read the sizes from CommandLine.arguments (lines 172-173) so the art and window cannot drift.
Aside (separate item): background@2x.png is never referenced by Finder; to get a Retina background use the dmgbuild technique of a multi-DPI TIFF (tiffutil -cathidpicheck background.png background@2x.png -out background.tiff) and point `background picture` at that file.

---

### Every hdiutil verb used (create/attach/detach/convert) is deprecated on macOS 26+ and prints warnings

- **Location:** `package-dmg.sh:44`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.9)

**What is wrong.** Verified on this Darwin 27 host: `hdiutil create -volname -format -size`, `hdiutil attach`, `hdiutil detach` and `hdiutil convert -format` each emit 'hdiutil: WARNING: … is deprecated. Please use diskutil image …' on stderr. The script only silences stdout (`>/dev/null`), so every packaging run on the author's machine prints four deprecation warnings, and the pipeline depends on a CLI Apple has scheduled for removal.

**How it fails.** Running ./package-dmg.sh on macOS 26/27 shows four WARNING lines interleaved with the script's own progress output; when a future macOS removes the deprecated paths the release script breaks with no fallback.

**Suggested fix.**

Preferred: switch package-dmg.sh to the non-deprecated `diskutil image` verbs, which exist on every host meeting the package's macOS 14 floor (diskutil(8) HISTORY: attach since 13.0, create since 14.0). Note the finding's `create from --format UDRW` is invalid (UDRW unsupported; `create from` is APFS-only), so use a blank writable image and copy the staging tree in:

  # line 28 (cleanup) and line 94:
  diskutil eject "$MOUNT_DIR" >/dev/null 2>&1 || true     # cleanup
  diskutil eject "$MOUNT_DIR" >/dev/null                  # line 94
  # lines 44-45:
  diskutil image create blank --format RAW --fs APFS --size "${SIZE_MB}m" \
      --volumeName "$VOL_NAME" "$DMG_TMP" >/dev/null
  # line 48 (attach mounts read-write at /Volumes/$VOL_NAME; then populate it):
  diskutil image attach "$DMG_TMP" >/dev/null
  cp -R "$STAGING/." "$MOUNT_DIR/"
  # line 97:
  diskutil image create from "$DMG_TMP" "$DMG_FINAL" --format UDZO >/dev/null

Caveats to document in the script: the volume becomes APFS rather than HFS+ (fine, the app already requires macOS 14; SetFile -a C and Finder .DS_Store layout work on APFS - verified dotfiles and the Applications symlink survive); `-imagekey zlib-level=9` has no diskutil equivalent (default zlib is fine); diskutil sizes are power-of-10 so `20m` yields ~19.99 MB instead of 20 MiB, which the existing +20 MB slack covers; there is no -noautoopen, harmless because the AppleScript opens and closes the window anyway. Optionally gate with `if diskutil image >/dev/null 2>&1; then ... else <existing hdiutil path> fi` (verified rc=0 here) for pre-14 hosts, though that is largely moot given the platform floor.

Minimal alternative if you want to keep hdiutil for now: do NOT use `-quiet` or `2>/dev/null` (both hide real errors - verified `-quiet` swallows "attach failed - No such file or directory"). Instead add a comment citing the hdiutil(1) DEPRECATION NOTICE and route stderr through a filter that drops only the deprecation line, e.g. a wrapper
  hd() { local e; e="$(mktemp)"; local rc=0; hdiutil "$@" >/dev/null 2>"$e" || rc=$?; grep -v "is deprecated. Please use 'diskutil" "$e" >&2 || true; rm -f "$e"; return $rc; }
and call `hd create ...`, `hd attach ...`, `hd detach ...`, `hd convert ...` at lines 44, 48, 94, 97.

---

### Shipped DMG contains the build machine's .fseventsd log directory; stage .fseventsd/no_log

- **Location:** `package-dmg.sh:36`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.92)

**What is wrong.** While the UDRW image is mounted, fseventsd creates `/.fseventsd/` on the volume and writes its log (including a fseventsd-uuid for the build Mac) on unmount, so the compressed release image carries it (verified: final UDZO image lists `.fseventsd` with 5 entries). It is hidden but is build-machine noise in a release artifact and is why create-dmg removes it before unmount. Staging an `.fseventsd/no_log` marker is the documented way to tell fseventsd not to log on that volume; verified that with it staged the final image's `.fseventsd` contains only the empty `no_log` file and no logs.

**How it fails.** Every ./package-dmg.sh run → NoSleep-<version>.dmg root contains .fseventsd/<uuid> and log files from the packaging machine → shipped to users in every release.

**Suggested fix.**

In package-dmg.sh, two one-line additions:

(a) After line 36 (`mkdir -p "$STAGING/.background"`), stage Apple's per-volume fseventsd opt-out so nothing is ever logged on the image:

    # Tell fseventsd not to log filesystem events on this volume (keeps .fseventsd logs out of the release image)
    mkdir -p "$STAGING/.fseventsd" && touch "$STAGING/.fseventsd/no_log"

(b) Immediately before line 94 (`hdiutil detach "$MOUNT_DIR"`), remove the marker directory so the shipped root is completely clean (nothing is buffered for fseventsd to write back at unmount thanks to (a)):

    rm -rf "$MOUNT_DIR/.fseventsd" 2>/dev/null || true

Verified in a temp copy: with both changes the final UDZO root contains only .background, .DS_Store, .VolumeIcon.icns, Applications, NoSleep.app. If you prefer a single line, (a) alone is sufficient and leaves only an empty hidden `.fseventsd/no_log`. Drop the suggested `rm -rf "$MOUNT_DIR/.Trashes"`: no .Trashes was present in the shipped v1.1.0 image or in any test image, so it is dead code. No effect on the Finder layout / background / volume icon.

---

### `sleep 2` after attach is a fixed guess for Finder's disk registration, not for the mount

- **Location:** `package-dmg.sh:49`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.6)

**What is wrong.** `hdiutil attach` is synchronous: the mount point exists the instant it returns (verified: `[ -d /Volumes/... ]` is true immediately after attach), so the sleep is not waiting for the mount and a `-d` poll would be a no-op. What it actually papers over is the Finder-side race in which `tell disk "NoSleep"` (line 55) fails with -1728 "Can't get disk" because Finder has not yet processed the DiskArbitration appearance callback — the same reason create-dmg carries `sleep 2 # pause to workaround occasional "Can't get disk" (-1728) issues`. A fixed 2 s is the slow path on a fast machine and still not guaranteed on a loaded one; when too short, the script prints the misleading 'Automation denied or timed out' warning and ships an unstyled DMG.

**How it fails.** Loaded machine or Finder busy (many windows, Spotlight churn) → Finder registers the disk >2 s after attach → osascript fails with -1728 → warning branch blames Automation/TCC → unstyled release DMG despite Automation being granted.

**Suggested fix.**

In package-dmg.sh:

1. Replace lines 48-49 so the shell learns the exact volume that was attached and no longer guesses a delay (pairs with the already-reported -plist finding):

    echo "==> Mounting…"
    ATTACH_PLIST="$(hdiutil attach "$DMG_TMP" -readwrite -noverify -noautoopen -plist)"
    MOUNT_DIR="$(printf '%s' "$ATTACH_PLIST" | plutil -extract system-entities json -o - - \
        | python3 -c 'import json,sys; print(next(e["mount-point"] for e in json.load(sys.stdin) if "mount-point" in e))')"
    # No sleep here: hdiutil only returns after the volume is mounted (-mount required is the default).
    # What can lag is Finder's own DiskArbitration-driven registration of the disk; the AppleScript
    # below waits for that explicitly instead of a fixed 2 s.

   (Note MOUNT_DIR is now assigned after cleanup() is defined; cleanup() reads it at exit time, so leave the trap as is but initialise MOUNT_DIR="" before the trap so `set -u` is satisfied.)

2. In apply_layout (lines 54-55), wait for Finder inside the script, which keeps the wait under the existing 45 s watchdog (a bash-side osascript poll before the watchdog would reintroduce the TCC-prompt hang the background/watcher design exists to prevent), and address the exact volume by mount point rather than by name:

    tell application "Finder"
        repeat 40 times
            if exists disk "${VOL_NAME}" then exit repeat
            delay 0.25
        end repeat
        if not (exists disk "${VOL_NAME}") then error "Finder never registered disk ${VOL_NAME}" number -1728
        tell (item (POSIX file "${MOUNT_DIR}" as alias))
            open
            ... (unchanged body) ...
        end tell
    end tell

   Verified: `item (POSIX file "<mount-point>" as alias)` resolves to Finder class `disk`, so `container window`/`icon view options` work unchanged; `delay` works inside the Finder tell block; the guard produces a clear "-1728 Finder never registered disk" instead of a bare "Can't get disk".

3. Make the failure summary (line 82) stop blaming Automation for every failure, since osascript's stderr already shows the true cause just above it:

    echo "    Warning: Finder layout not applied (see osascript error above: Automation denied,"
    echo "    timed out, or Finder never registered the volume)."

Expected effect: DMG builds complete ~2 s faster on a normal machine (Finder was ready within ~0.2 s in every measured run), the wait becomes bounded and condition-based (up to 10 s) instead of a magic number, and a genuine Finder registration problem surfaces with the correct message.

---

### Only a legacy .icns is bundled, so macOS 26+ rescales, re-masks and glass-tints the icon

- **Location:** `build.sh:24`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.85)

**What is wrong.** build.sh copies just AppIcon.icns and the Info.plist has CFBundleIconFile but no CFBundleIconName/Assets.car (lines 24-29, 46-47). Measured on this macOS 27 host: IconServices applies the legacy treatment to the shipped icon: the 902 px artwork is scaled down to the 824 px grid (cup width goes from 324 px to 297 px at 512 px, matching the predicted 824/902 ratio) and re-masked to the system squircle, a specular rim is added (top-edge pixel goes from (221,157,93) to (255,255,233), bottom edge from (57,33,18) to (147,114,94)) and the white glyph is dimmed to (239,236,233). No double edge or corner-radius gap occurs, so that hypothesis is refuted, but the rendered icon is a system-synthesised approximation and the user-selectable Dark/Clear/Tinted icon appearances on 26+ can only be auto-derived from the flat bitmap. Xcode 26.6 with actool and Icon Composer (/Applications/Xcode.app/Contents/Applications/Icon Composer.app) are installed here, so the toolchain exists.

**How it fails.** On macOS 26+ the icon shown in Finder, the Background Items Added alert, Login Items and completion notifications is not the artwork the script renders: it is 9% smaller, has a glass rim and dimmed glyph the designer never saw, and under the Clear/Tinted appearance modes it is a system-generated monochrome guess with no per-layer control. Any future artwork tweak in generate-art.swift is re-processed unpredictably by the OS.

**Suggested fix.**

1) Check in a layered icon document at assets/AppIcon.icon/ (icon.json + Assets/cup.png). Author it in Icon Composer (background: the caramel->espresso linear gradient; one foreground layer: cup.and.saucer.fill, scale tuned to match the current 0.5 glyph size; glass/translucency on). A minimal hand-written icon.json compiles as-is with actool 26.6: {"fill":{"linear-gradient":["extended-srgb:0.90,0.68,0.44,1","extended-srgb:0.29,0.17,0.09,1"]},"groups":[{"layers":[{"image-name":"cup.png","name":"cup"}],"shadow":{"kind":"neutral","opacity":0.5},"translucency":{"enabled":true,"value":0.5}}],"supported-platforms":{"circles":["watchOS"],"squares":"shared"}}. Have scripts/generate-art.swift also emit the transparent 1024 px white glyph to assets/AppIcon.icon/Assets/cup.png so the "no external art" workflow is preserved.

2) In build.sh replace lines 24-29 with a guarded actool step, falling back to the current .icns copy (do NOT use `command -v actool` — /usr/bin/actool is a base-OS xcrun shim that always exists):
   ICON_NAME_KEY=""
   if [ -d assets/AppIcon.icon ] && xcrun --find actool >/dev/null 2>&1 && \
      xcrun actool assets/AppIcon.icon --compile "${APP_BUNDLE}/Contents/Resources" \
        --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
        --output-partial-info-plist "${APP_BUNDLE}/Contents/icon-partial.plist" \
        --output-format human-readable-text >/dev/null 2>&1 && \
      [ -f "${APP_BUNDLE}/Contents/Resources/Assets.car" ]; then
       ICON_NAME_KEY='<key>CFBundleIconName</key><string>AppIcon</string>'
       rm -f "${APP_BUNDLE}/Contents/icon-partial.plist"
   elif [ -f assets/AppIcon.icns ]; then
       cp assets/AppIcon.icns "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
   else
       echo "Warning: no icon — run ./make-icons.sh"
   fi
   Then switch the plist heredoc from 'PLIST' to PLIST (unquoted) so it can interpolate ${ICON_NAME_KEY} next to the existing CFBundleIconFile key (keep CFBundleIconFile=AppIcon; actool also emits a loose AppIcon.icns). `--include-all-app-icons` is unnecessary for a single icon; drop it.

3) Leave package-dmg.sh using assets/AppIcon.icns for .VolumeIcon.icns (the default loose .icns from actool only has 16/32/128/256 px), or pass --standalone-icon-behavior all if you want the actool .icns to be complete. Note the trade-off in README: Assets.car adds ~1.6 MB of incompressible data to the DMG, and the layered icon requires Xcode 26+ on the build machine (CLT-only builds keep the legacy icon via the fallback).

---

### Cup glyph collapses to an 8x4 px white smudge at 16 px; master is not small-size robust

- **Location:** `scripts/generate-art.swift:93`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.8)

**What is wrong.** The single 1024 px master uses a .regular-weight SF Symbol at pointSize 0.5*s (generate-art.swift:93) and white on a light caramel top (contrast ~1.9:1); every smaller size is a plain resample (sips today, IconServices on 26+ if the small reps are dropped per F4). Measured in the shipped icon_16x16.png: the near-white glyph bounding box is 8x4 px and the cup and saucer merge into one blob; at 32 px it is 18x14 px and just legible. The 16 px tile reads as 'light blob on brown', not a coffee cup, whereas native 16 px icons (Calculator, Terminal) keep recognisable shapes because Apple simplifies small sizes. Interplay with F4: hand-tuned 16/32 px reps must NOT be added back into the .icns for 26+ (they trigger the gray plate); small-size tuning belongs either in the master itself or in the .icon's per-layer artwork.

**How it fails.** In Finder list/column view, the Open panel sidebar, or a non-Retina Login Items list, the NoSleep icon is an indistinct white smear on a brown square; users scanning a folder of apps cannot identify it by shape, only by colour.

**Suggested fix.**

Fix the master only; no per-size artwork, no changes to make-icons.sh or the icns rep set (keeps this orthogonal to F4/F13).

1. scripts/generate-art.swift:93 — change
   `let config = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .regular)`
   to
   `let config = NSImage.SymbolConfiguration(pointSize: s * 0.55, weight: .heavy)`
   (or `weight: .black`; keep the scale in 0.55...0.58 — at 0.62 the glyph reaches x=69 against a squircle rect starting at x=61 and crowds the corner radius). Measured through the existing 1024->sips pipeline this takes the 16 px glyph from 8x5 px / 23 white px to 10x8 px / 48 px (heavy 0.55) or 12x8 px / 50-56 px (heavy/black 0.58), and the saucer becomes visibly wider than the cup so the tile reads as cup-on-saucer; the 32 px rep grows from 20x14 to 22x18-24x18 px.

2. Optional palette tweak, scripts/generate-art.swift:30 — darken iconTopColor to about (0.80, 0.55, 0.30) to lift white-on-top contrast from 1.98:1 to 2.82:1; this changes the look, so it is the author's call. Do NOT add a drop shadow behind the glyph: a shadow sized for 1024 px collapses below 0.5 px at 16 px and produced no measurable change (48 vs 50 white px).

3. Skip the suggested drawAppIcon(size: 16/32, ...) variants: a native heavy draw at 16 px (12x9 px, 56 px) is no better than the downsampled heavy master, so hand-tuned small reps add complexity (and interact with F4) for no gain.

4. Regenerate with ./make-icons.sh, then verify: `iconutil -c iconset assets/AppIcon.icns -o /tmp/chk.iconset` and inspect /tmp/chk.iconset/icon_16x16.png at 100% (expect a white glyph box of at least 10x8 px with saucer wider than cup). Re-run ./build.sh so NoSleep.app/Contents/Resources/AppIcon.icns picks up the new art.

---

### App icon squircle uses a 6% margin (902 px) instead of Apple's 824 px grid, so it renders ~9% oversized next to system icons

- **Location:** `scripts/generate-art.swift:82`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.9)

**What is wrong.** `let margin = s * 0.06` yields a rounded rect spanning pixels 61..962, i.e. 902x902 of the 1024 canvas (verified by scanning the opaque bounding box of the rendered PNG). Apple's macOS production template (and every system app icon since Big Sur) draws the shape at 824x824 centred (100 px margin, corner radius ≈185.4 px); the script already matches the radius ratio at line 84 but not the size. On macOS 14/15 — the app's supported range — the NoSleep icon appears roughly 9.5% larger than every neighbouring icon in the Dock, Finder, Launchpad and the DMG window. On macOS 26+ the system re-masks legacy icons so the oversize is mostly cropped, but the corner radius/gradient extent still differ from the design.

**How it fails.** Install on macOS 14 or 15 and drag NoSleep to the Dock next to Safari or System Settings: the caramel squircle is visibly bigger and its corners extend beyond the standard icon grid; in the styled DMG the 128 px app icon dwarfs the Applications folder icon.

**Suggested fix.**

In scripts/generate-art.swift:

1. Line 82: replace `let margin = s * 0.06` with `let margin = s * (100.0 / 1024.0) // Apple macOS icon grid: 824x824 tile centred on a 1024 canvas`. Verified to render the tile at exactly x=100..923 (824x824).

2. Line 84 (optional, sub-pixel): `let radius = rect.width * 0.225 // 185.4 / 824, Apple production template`. The current 0.2237 gives 184.3 px, so this is cosmetic.

3. Optional, to match the system-drawn shadow that every neighbouring icon on macOS 14/15 carries (measured system icons: ~20 px spread, ~8-12 px downward offset at 1024): before the `squircle.addClip()` block, fill the path once with an NSShadow so the shadow lands outside the clip:
   NSGraphicsContext.saveGraphicsState()
   let shadow = NSShadow()
   shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
   shadow.shadowBlurRadius = s * 0.02
   shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
   shadow.set()
   iconBottomColor.setFill()
   NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
   NSGraphicsContext.restoreGraphicsState()
   then keep the existing clip + gradient draw.

4. Optional proportion note: the glyph is sized from the canvas (`pointSize: s * 0.5`, line 93), not the tile, so after the fix it grows from 57% to 62% of the tile width. If the original proportion is wanted, use `pointSize: rect.width * 0.57`.

5. Re-run ./make-icons.sh (regenerates assets/AppIcon.png and assets/AppIcon.icns; all iconset sizes are downsampled from the 1024 master) and ./build.sh, then commit the regenerated assets. package-dmg.sh layout and the DMG background are unaffected. Note the failure scenario should be worded as 'larger than neighbouring app icons in Dock/Finder/Launchpad on macOS 14/15' rather than 'dwarfs the Applications folder icon' (the folder icon is 948 px wide); on macOS 26+ the system re-masks legacy icons so the change is invisible there.

---

### GPLv3 binary distribution (DMG/app bundle) ships without the license text

- **Location:** `package-dmg.sh:33`
- **Severity / category:** low / docs
- **Votes:** single:ok(0.85)

**What is wrong.** Every source file and the README declare GPLv3 and a LICENSE file exists at the repo root, but GPLv3 sections 4 and 6 require that object-code distributions be accompanied by a copy of the license. The DMG staging (package-dmg.sh:33-34) copies only NoSleep.app and an Applications symlink; build.sh writes nothing but AppIcon.icns into Contents/Resources. A user who installs from the Releases DMG receives no license text or source offer anywhere on disk.

**How it fails.** A downstream redistributor (Homebrew cask, corporate software catalogue) mirrors NoSleep-1.1.0.dmg; the artifact they redistribute contains no GPL text or pointer to source, so both they and the project are out of compliance with the project's own license.

**Suggested fix.**

Three small edits; the ordering constraint in build.sh is the only subtlety.

1. build.sh — insert after line 29 (icon block) and BEFORE line 63 (`codesign --force --sign -`), because Contents/Resources is sealed into _CodeSignature/CodeResources and adding the file after signing would make `codesign --verify` fail with "a sealed resource is missing or invalid":
   cp LICENSE "${APP_BUNDLE}/Contents/Resources/LICENSE.txt"

2. build.sh Info.plist heredoc (lines 37-58) — add a copyright string that also serves as the §6d "clear directions to Corresponding Source"; it is visible to end users without an About window via Finder > Get Info:
   <key>NSHumanReadableCopyright</key>
   <string>Copyright © 2026 Sergio Farfan. Free software under the GNU GPL v3 or later; source: https://github.com/sergio-farfan/nosleep</string>

3. package-dmg.sh — after line 34 stage the license at the DMG root, and give it an explicit position in the AppleScript so it does not land at a random spot over the background art (lines 65-66 currently position only the two icons; window bounds at line 60 are 600x400):
   cp LICENSE "$STAGING/LICENSE.txt"
   ...
   set position of item "LICENSE.txt" of container window to {300, 330}
   Alternatively, if the styled window must stay two-icon-only, omit step 3 and rely on steps 1-2 (the license then travels inside the installed .app, which is what matters for mirrors), but do not use hdiutil's SLA/-license feature: presenting the GPL as a click-through agreement misrepresents it (the FSF explicitly advises against this).

Optional: add a one-line note under README.md "## License" that the DMG/app bundle includes LICENSE.txt in Contents/Resources.

---

### Bundle ID com.nosleep.app is not a controlled reverse-DNS namespace; name collides with existing NoSleep app

- **Location:** `build.sh:41`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.5)

**What is wrong.** The identifier implies ownership of nosleep.com and is duplicated as the LaunchAgent label (LoginItemManager.swift:23), the defaults domain (README:111) and the plist path (install.sh:8). 'NoSleep' is also the name of a long-standing open-source macOS sleep utility (integralpro/nosleep, Homebrew cask `nosleep`), so Spotlight/LaunchServices, support searches and Background Items lists will show two unrelated 'NoSleep' apps. Bundle IDs are effectively permanent: changing later resets UserDefaults, notification authorization, TCC records and the LaunchAgent label for every existing user, so this is far cheaper to fix now than after wider distribution. (Distinct from the already-reported heredoc duplication / dead BUNDLE_ID variable — this is about the value itself.)

**How it fails.** A user who already has the other NoSleep installed (or installs it later) sees two 'NoSleep' entries in Login Items/Notifications settings with no way to tell them apart; a later rename of the bundle ID to a controlled namespace silently forgets every user's saved duration and re-prompts for notification permission.

**Suggested fix.**

Reword the finding: drop the "collides with existing NoSleep app" / product-rename angle (that app is deprecated, its cask removed, and it used the com.protech.* namespace). Keep: adopt a controlled identifier and define it once, and do it now because the ID is already baked into users' prefs, notification grants and LaunchAgent.

1. Pick `io.github.sergio-farfan.nosleep` (owned via the GitHub account; the F-Droid/Homebrew convention for GitHub-hosted apps) or `com.<your-domain>.nosleep` if you own a domain.
2. build.sh: use the existing `BUNDLE_ID` variable in the Info.plist (change `<< 'PLIST'` to an unquoted `<< PLIST` and write `<string>${BUNDLE_ID}</string>` at line 41). Optionally also stamp it into a generated Swift constant, or simply read it at runtime:
   - LoginItemManager.swift: replace both literals (lines 23 and 34) with one `private let plistLabel = Bundle.main.bundleIdentifier ?? "io.github.sergio-farfan.nosleep"` and have `init()` use `plistURL` instead of re-spelling the path.
   - install.sh:8: `PLIST_PATH="$HOME/Library/LaunchAgents/${BUNDLE_ID}.plist"` sourced from the same value (e.g. read it back with `/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist"`).
   - README.md:108/111 and dev-to-article.md:140: update to the new ID.
3. One-time migration shim, since v1.1.0 is already installed in the wild:
   - CaffeinateManager.init: if `UserDefaults.standard.object(forKey: "selectedDuration") == nil`, read `UserDefaults(suiteName: "com.nosleep.app")?.integer(forKey: "selectedDuration")`, copy it, then `UserDefaults.standard.removePersistentDomain(forName: "com.nosleep.app")`.
   - LoginItemManager.init: if `~/Library/LaunchAgents/com.nosleep.app.plist` exists and the new plist does not, delete the legacy file and re-write it under the new label (otherwise the stale agent keeps launching at login while the toggle shows off, and re-enabling would spawn a second instance).
   - README Uninstall: list both the legacy and new domain/plist for one release.
4. Longer term, replace the hand-written LaunchAgent with `SMAppService.mainApp.register()` (macOS 13+; app targets 14), which removes the label/plist path from the code entirely.

---

## 5. Tests and CI

### Process launching is hard-wired to /usr/bin/caffeinate; the start/stop/restart/termination state machine has zero tests

- **Location:** `Sources/NoSleep/CaffeinateManager.swift:110`
- **Severity / category:** medium / test-coverage
- **Votes:** reproduce:ok(0.9), skeptic:ok(0.8), impact:ok(0.82)

**What is wrong.** `start()` constructs `Process` inline, so even once F1 makes the manager constructible, any test of `start()` would spawn a real caffeinate. The only tested piece is the pure `shouldNotifyOnCompletion`, while the code that actually decides behaviour — the `runToken` bump, the stale-token guard duplicated at line 188, the `stoppedByUser` lifecycle, `activeDuration` capture, the exactly-once `postCompletion`, argument construction (`-t` omitted for Indefinite) — is unverified. The spec's concurrency note calls the restart race 'important', yet the guard protecting it is only exercised indirectly through a static function that `handleTermination` re-checks anyway. A test would also pin the latent inconsistency in F31 (state written before `proc.run()`).

**How it fails.** A future refactor reorders `stop()` and `runToken += 1` in `start()`, or forgets `stoppedByUser = false` at line 108. Both compile, all 5 tests stay green, and in the app a restart via `changeDuration` either fires a spurious 'session has ended' banner for the new session or suppresses the legitimate one — exactly the regressions the runToken design exists to prevent.

**Suggested fix.**

Land together with F1 (notification seam) and ideally F31; every piece below was compiled and run under Swift 6.3.3 in a temp copy (15/15 green with F31, zero warnings).

--- Sources/NoSleep/CaffeinateManager.swift ---
Insert before line 48 (`@MainActor final class CaffeinateManager`):

```swift
/// Seam between the state machine and the real `caffeinate` process so
/// start/stop/restart/termination can be unit-tested without spawning.
@MainActor
protocol CaffeinateLaunching {
    /// `onTermination` must be invoked exactly once, on the main actor, when the process exits for any reason.
    func launch(arguments: [String],
                onTermination: @escaping @MainActor () -> Void) throws -> any CaffeinateHandle
}

@MainActor
protocol CaffeinateHandle: AnyObject {
    var isRunning: Bool { get }
    func terminate()
}

extension Process: CaffeinateHandle {}   // Process already has isRunning/terminate()

/// Production launcher: Foundation `Process` around /usr/bin/caffeinate.
struct ProcessCaffeinateLauncher: CaffeinateLaunching {
    func launch(arguments: [String],
                onTermination: @escaping @MainActor () -> Void) throws -> any CaffeinateHandle {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        proc.arguments = arguments
        proc.terminationHandler = { _ in Task { @MainActor in onTermination() } }   // hop lives here now
        try proc.run()
        return proc
    }
}
```

Line 74: `private var process: Process?` → `private var process: (any CaffeinateHandle)?`
Line 79: replace `let notifications = NotificationManager()` with
```swift
    private let launcher: any CaffeinateLaunching
    let notifications: any CompletionNotifying          // F1 seam, see NotificationManager below
```
Lines 81-86: 
```swift
    init(launcher: any CaffeinateLaunching = ProcessCaffeinateLauncher(),
         notifications: any CompletionNotifying = NotificationManager()) {
        self.launcher = launcher
        self.notifications = notifications
        let saved = UserDefaults.standard.integer(forKey: "selectedDuration")
        self.selectedDuration = SleepDuration(rawValue: saved) ?? .fourHours
        notifications.onExtend = { [weak self] in self?.extendOneHour() }
        notifications.requestAuthorization()
    }
```
Lines 110-136 of start(): delete the inline `Process` construction/terminationHandler/do-try-run and use (this ordering also fixes F31; if F31 is deferred keep the old assignment order and drop the launch-failure test):
```swift
        let duration = selectedDuration
        var args = ["-d", "-i"]
        if duration != .indefinite { args += ["-t", "\(duration.rawValue)"] }

        let proc: any CaffeinateHandle
        do {
            proc = try launcher.launch(arguments: args) { [weak self] in
                self?.handleTermination(token: token)
            }
        } catch {
            return
        }

        process = proc
        activeDuration = duration
        remainingSeconds = duration == .indefinite ? 0 : duration.rawValue
        isActive = true
```
`stop()`/`handleTermination` need no changes (`proc.isRunning`/`proc.terminate()` resolve through the protocol). `NoSleepApp.swift:23` `CaffeinateManager()` keeps working via the defaults.

--- Sources/NoSleep/NotificationManager.swift (the minimal F1 seam this depends on) ---
Above line 22 add and conform at line 23:
```swift
@MainActor
protocol CompletionNotifying: AnyObject {
    var onExtend: (() -> Void)? { get set }
    func requestAuthorization()
    func postCompletion(duration: SleepDuration)
}
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, CompletionNotifying { ... }
```
(Required: `UNUserNotificationCenter.current()` at lines 38/63 throws `bundleProxyForCurrentProcess is nil` under `swift test`, so the manager is not constructible without it.)

--- Tests/NoSleepTests/CaffeinateManagerStateTests.swift (new) ---
Fakes (all `@MainActor`, conform directly — no isolated-conformance syntax needed because the protocols are `@MainActor`):
```swift
@MainActor final class FakeHandle: CaffeinateHandle {
    let arguments: [String]; private let onTermination: @MainActor () -> Void
    private(set) var isRunning = true; private(set) var terminateCount = 0
    init(arguments: [String], onTermination: @escaping @MainActor () -> Void) { ... }
    func terminate() { terminateCount += 1; isRunning = false }
    func fireTermination() { isRunning = false; onTermination() }   // synchronous: assertions are immediate
}
@MainActor final class FakeLauncher: CaffeinateLaunching {
    struct LaunchFailed: Error {}
    private(set) var launches: [FakeHandle] = []; var shouldFail = false
    func launch(arguments: [String], onTermination: @escaping @MainActor () -> Void) throws -> any CaffeinateHandle {
        if shouldFail { throw LaunchFailed() }
        let h = FakeHandle(arguments: arguments, onTermination: onTermination); launches.append(h); return h
    }
}
@MainActor final class FakeNotifier: CompletionNotifying {
    var onExtend: (() -> Void)?; private(set) var completions: [SleepDuration] = []; private(set) var authorizationRequests = 0
    func requestAuthorization() { authorizationRequests += 1 }
    func postCompletion(duration: SleepDuration) { completions.append(duration) }
}
```
Test class: `@MainActor final class CaffeinateManagerStateTests: XCTestCase` with `launcher/notifier/manager` fixtures. Use the ASYNC lifecycle overrides — the sync `setUp()`/`tearDown()` overrides inherit XCTest's nonisolated declaration and produce 12 Swift 6 isolation warnings (and `MainActor.assumeIsolated` inside them is a hard error):
```swift
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            launcher = FakeLauncher(); notifier = FakeNotifier()
            manager = CaffeinateManager(launcher: launcher, notifications: notifier)
        }
    }
    override func tearDown() async throws {
        await MainActor.run { manager.stop(); manager = nil; launcher = nil; notifier = nil }  // stop() invalidates the repeating Timer left on the main run loop
        try await super.tearDown()
    }
```
Tests (all verified passing; mutation-tested against removing the line-188 guard and the line-108 reset):
- testStartTimedLaunchesWithTimeoutArgs: changeDuration(.oneHour) → launches[0].arguments == ["-d","-i","-t","3600"], isActive, remainingSeconds == 3600, formattedRemaining == "1h 0m".
- testStartIndefiniteOmitsTimeout: args == ["-d","-i"], remainingSeconds == 0, formattedRemaining == "∞"; fireTermination → inactive, completions == [].
- testStopTerminatesHandleAndSuppressesNotification: changeDuration(.oneHour); stop() → terminateCount == 1, inactive, remaining 0; launches[0].fireTermination() (late async delivery) → completions == [], still inactive.
- testRestartIgnoresStaleTerminationOfPreviousRun: changeDuration(.oneHour); changeDuration(.twoHours) → 2 launches, launches[0].terminateCount == 1, launches[1].arguments has "-t","7200"; launches[0].fireTermination() → isActive, remaining 7200, completions []; launches[1].fireTermination() → inactive, completions == [.twoHours].
- testNaturalExpiryNotifiesExactlyOnceAndResetsState: changeDuration(.fifteenMin); fire → completions == [.fifteenMin], inactive, remaining 0, formattedRemaining == ""; fire again → still exactly one completion.
- testToggleStartsThenStops: selectedDuration = .oneHour; toggle() → active, 1 launch; toggle() → inactive, still 1 launch, terminateCount == 1.
- testExtendOneHourFromNotificationLaunchesFreshHour: changeDuration(.fifteenMin); fire; notifier.onExtend?() → selectedDuration == .oneHour, 2 launches, launches[1].arguments == ["-d","-i","-t","3600"], active, remaining 3600.
- testInitRequestsAuthorizationOnce: authorizationRequests == 1.
- testLaunchFailureLeavesInactiveAndZeroRemaining: shouldFail = true; changeDuration(.oneHour) → !isActive, remainingSeconds == 0, formattedRemaining == "". (Fails on today's ordering with "3600 != 0"; passes with the start() body above / F31.)
- testProcessLauncherRunsCaffeinateAndReportsTermination (covers the one remaining production line): `let done = expectation(...)`; `let h = try ProcessCaffeinateLauncher().launch(arguments: ["-d","-i","-t","1"]) { MainActor.assertIsolated(); done.fulfill() }`; XCTAssertTrue(h.isRunning); wait(for: [done], timeout: 5); XCTAssertFalse(h.isRunning). ~1s wall time; spawns a real caffeinate, so keep it as a single smoke test.

Differences from the original suggestion, deliberately: protocols are `@MainActor` rather than `Sendable` (manager is `@MainActor`, and this lets stateful fakes conform directly); callback is `@MainActor () -> Void` with the unused `Bool` dropped, so the actor hop moves into `ProcessCaffeinateLauncher` and `fireTermination()` is synchronous (no awaits/expectations in state tests); `extension Process: CaffeinateHandle {}` replaces a wrapper class; the launch-failure test is called out as F31-dependent rather than shipped red. Optional follow-up not included: `tick()` is `private` and untested — making it internal would allow a countdown test via `@testable import`.

---

### formattedRemaining has four formatting branches and no tests; extract a pure static formatter

- **Location:** `Sources/NoSleep/CaffeinateManager.swift:88`
- **Severity / category:** low / test-coverage
- **Votes:** reproduce:ok(0.85), skeptic:ok(0.82), impact:ok(0.7)

**What is wrong.** `formattedRemaining` is the user-visible countdown string with branches for inactive (''), indefinite ('∞'), hours ('Xh Ym', seconds silently dropped), minutes ('Xm Ys') and seconds-only. None is tested and none can be today because it is an instance property depending on `isActive`, `selectedDuration` and `remainingSeconds`, and the instance cannot be constructed (F1). The spec's verification checklist (design.md:136-147: auto-activate on pick, restart with new duration, Stop deactivates, Extend selects 1 hour, Indefinite shows ∞) is deferred entirely to manual GUI checks by the plan (line 7). `SleepDuration.label` also feeds the notification body and `allCases` order drives the menu (Indefinite last), neither asserted.

**How it fails.** Someone 'fixes' the hours branch to `"\(h)h \(m)m \(s)s"` or changes the modulo at line 92 to `remainingSeconds / 60`; the build passes, all tests stay green, and the menu shows '1h 60m' for 7199 s. Reordering `SleepDuration.allCases` so Indefinite is no longer last also goes unnoticed.

**Suggested fix.**

1) Sources/NoSleep/CaffeinateManager.swift — replace lines 88-101 with:

    var formattedRemaining: String {
        guard isActive else { return "" }
        if selectedDuration == .indefinite { return "∞" }
        return Self.formatRemaining(seconds: remainingSeconds)
    }

    /// Pure countdown formatter: "Xh Ym" at or above one hour (seconds are
    /// intentionally dropped), "Xm Ys" below one hour, "Xs" under a minute.
    nonisolated static func formatRemaining(seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        let s = seconds % 60
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

(Keep `selectedDuration` in the guard; do not switch to `activeDuration` — equivalent while isActive, and activeDuration is not @Published.)

2) Tests/NoSleepTests/CaffeinateManagerTests.swift — insert before the closing brace at line 47 (XCTest, matching the existing file; no Swift Testing):

    func testFormatRemainingTable() {
        let cases: [(Int, String)] = [
            (0, "0s"), (1, "1s"), (59, "59s"),
            (60, "1m 0s"), (61, "1m 1s"), (599, "9m 59s"), (3599, "59m 59s"),
            (3600, "1h 0m"), (3661, "1h 1m"), (5400, "1h 30m"),
            (35999, "9h 59m"), (36000, "10h 0m"),
        ]
        for (seconds, expected) in cases {
            XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: seconds), expected,
                           "seconds=\(seconds)")
        }
    }

    func testIndefiniteIsLastMenuEntry() {
        XCTAssertEqual(SleepDuration.allCases.last, .indefinite)
    }

Verified: compiles under Swift 6 strict concurrency, 8 tests pass, and the table catches the modulo mutation with 5 failures. Defer the instance-level assertions (inactive → "", active indefinite → "∞", extendOneHour() → .oneHour) to the F1 fix that makes CaffeinateManager constructible without UNUserNotificationCenter (e.g. inject NotificationManager or move requestAuthorization() out of init); they cannot be added until then.

---

### LoginItemManager hardcodes ~/Library/LaunchAgents and Bundle.main; any test would write a real LaunchAgent pointing at xctest

- **Location:** `Sources/NoSleep/LoginItemManager.swift:33`
- **Severity / category:** low / test-coverage
- **Votes:** single:ok(0.9)

**What is wrong.** `init` and `plistURL` read `FileManager.default.homeDirectoryForCurrentUser` directly and `enable()` reads `Bundle.main.executablePath`, so the class has no test seam. Any test calling `toggle()` would create `~/Library/LaunchAgents/com.nosleep.app.plist` on the developer's (or CI runner's) machine with `ProgramArguments` pointing at the xctest binary — a login item that launches Xcode's test runner at next login. The plist path is also built twice from two independent literals (line 23 `plistLabel` vs the inline string at line 34), so the init check and the write path can silently diverge.

**How it fails.** A `testToggleEnables()` is added and run locally: `isEnabled` becomes true and `~/Library/LaunchAgents/com.nosleep.app.plist` now exists pointing at `/Applications/Xcode.app/Contents/Developer/usr/bin/xctest`; launchctl loads it at next login. If the label at line 23 is renamed but line 34 is not, `isEnabled` reads false on launch while a stale plist keeps auto-starting the app.

**Suggested fix.**

In Sources/NoSleep/LoginItemManager.swift, inject the two environment dependencies and derive the plist URL from a single label constant (verified to compile and pass under Swift 6 strict concurrency):

```swift
@MainActor
final class LoginItemManager: ObservableObject {
    static let plistLabel = "com.nosleep.app"
    @Published var isEnabled: Bool
    private let launchAgentsDirectory: URL
    private let executablePath: String?

    var plistURL: URL { launchAgentsDirectory.appendingPathComponent("\(Self.plistLabel).plist") }

    init(
        launchAgentsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
        executablePath: String? = Bundle.main.executablePath
    ) {
        self.launchAgentsDirectory = launchAgentsDirectory
        self.executablePath = executablePath
        // Must compute locally: reading the computed `plistURL` here is a
        // definite-initialization error before `isEnabled` is assigned.
        let url = launchAgentsDirectory.appendingPathComponent("\(Self.plistLabel).plist")
        self.isEnabled = FileManager.default.fileExists(atPath: url.path)
    }
    // enable(): use `executablePath` instead of Bundle.main.executablePath, `Self.plistLabel` for Label,
    // createDirectory(at: launchAgentsDirectory, ...). disable() unchanged.
}
```
Call site (NoSleepApp.swift:24) is unchanged because both parameters default. Add Tests/NoSleepTests/LoginItemManagerTests.swift as a `@MainActor final class LoginItemManagerTests: XCTestCase` that creates `FileManager.default.temporaryDirectory/NoSleepTests-<UUID>` in setUp and removes it in tearDown, with a fake exec path, covering: testInitReflectsExistingPlist (pre-create the file → isEnabled true), testInitFalseWhenNoPlist, testEnableWritesPlistWithLabelProgramArgumentsAndRunAtLoad (toggle, decode via PropertyListSerialization, assert Label == "com.nosleep.app", ProgramArguments == [fakeExec], RunAtLoad == true, KeepAlive == false), testDisableRemovesPlistAndClearsFlag (toggle twice → file gone, isEnabled false), testEnableWithNilExecutablePathIsNoOp (executablePath: nil → toggle leaves isEnabled false and writes nothing). Never test with the default initializer: HOME overrides do not redirect homeDirectoryForCurrentUser, so any default-init toggle test mutates the real ~/Library/LaunchAgents. Superseded if the app moves to SMAppService.mainApp (macOS 13+; does not require sandboxing, contrary to dev-to-article.md:133).

---

### Notification content and action routing are untested but cheaply extractable

- **Location:** `Sources/NoSleep/NotificationManager.swift:53`
- **Severity / category:** low / test-coverage
- **Votes:** single:ok(0.82)

**What is wrong.** `postCompletion` builds the `UNMutableNotificationContent` and immediately hands it to `UNUserNotificationCenter.current()`, and `didReceive` compares `response.actionIdentifier` inline, so neither the body/category wiring nor the EXTEND_1H -> `onExtend` routing can be asserted. Constructing `UNMutableNotificationContent` does not require a bundle (verified in the xctest host: title/body/categoryIdentifier/sound set and read back fine), so the builder is testable if separated from `add(_:)`; `UNNotificationResponse` cannot be constructed in tests, so routing must take the identifier string. The identifiers are `private let` instance constants, which also prevents tests from referencing them.

**How it fails.** Someone renames the action identifier at line 25 but not the category's action list, or changes the `categoryIdentifier` assignment; the banner appears without the 'Extend 1 hour' button (or the tap does nothing) and nothing in `swift test` changes.

**Suggested fix.**

In Sources/NoSleep/NotificationManager.swift:

1. Lines 24-25: replace the private instance constants with `nonisolated static let categoryID = "SESSION_COMPLETE"` and `nonisolated static let extendActionID = "EXTEND_1H"`. The `nonisolated` is required: a plain `static let` on a @MainActor class is main-actor isolated under Swift 6 and the nonisolated builder below will not compile without it (verified). Update lines 41 and 44 to `Self.extendActionID` / `Self.categoryID`.

2. Extract the builder and the router, and have the existing entry points delegate to them:

    /// Pure builder; never touches UNUserNotificationCenter, so it is safe in unit tests.
    nonisolated static func makeCompletionContent(for duration: SleepDuration) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "NoSleep"
        content.body = "Your \(duration.label) session has ended."
        content.categoryIdentifier = categoryID
        content.sound = .default
        return content
    }

    /// Routes a notification action identifier to the matching callback.
    func handleAction(identifier: String) {
        if identifier == Self.extendActionID { onExtend?() }
    }

    func postCompletion(duration: SleepDuration) {
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: Self.makeCompletionContent(for: duration),
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

   and in didReceive (line 82) replace the inline comparison with `self?.handleAction(identifier: actionID)`.

3. Add Tests/NoSleepTests/NotificationManagerTests.swift (`import XCTest`, `import UserNotifications`, `@testable import NoSleep`). Test methods that construct NotificationManager must be marked `@MainActor` (the class is @MainActor; XCTest in Swift 6 will not let a nonisolated test touch it):
   - testCompletionContentBodyMentionsDurationLabel: `let c = NotificationManager.makeCompletionContent(for: .twoHours)`; assert `c.title == "NoSleep"`, `c.body.contains(SleepDuration.twoHours.label)`, `c.categoryIdentifier == NotificationManager.categoryID`, `c.sound != nil`.
   - @MainActor testExtendActionInvokesOnExtend: set `onExtend` to increment a counter, call `handleAction(identifier: NotificationManager.extendActionID)`, assert 1.
   - @MainActor testDefaultTapDoesNotInvokeOnExtend: same with `UNNotificationDefaultActionIdentifier`, assert 0.
   - @MainActor testDismissDoesNotInvokeOnExtend: same with `UNNotificationDismissActionIdentifier`, assert 0.

   Do NOT call `requestAuthorization()` or `postCompletion` from tests: UNUserNotificationCenter.current() aborts with 'bundleProxyForCurrentProcess is nil' in the SPM xctest host (verified). Verified result with this exact change set: `swift test` -> 9 tests, 0 failures; each of the three mutations (drop categoryIdentifier, route default tap to extend, drop duration label from body) is caught by exactly one new test while the pre-existing 5 stay green.

---

### Remaining-time arithmetic is untestable; no test covers a clock jump (sleep/stall)

- **Location:** `Tests/NoSleepTests/CaffeinateManagerTests.swift:22`
- **Severity / category:** low / test-coverage
- **Votes:** single:ok(0.9)

**What is wrong.** All five tests exercise shouldNotifyOnCompletion. The remaining-time behaviour — the part that goes wrong across sleep and while the menu is open — lives implicitly in Timer callbacks (`tick()` at CaffeinateManager.swift:177-184) with no injectable notion of 'now', so the regression described in F3 cannot be expressed as a unit test today and will not be protected once fixed. A tiny pure value type makes it trivial: `struct SessionDeadline { let end: Date; func remaining(at now: Date) -> Int { max(0, Int(end.timeIntervalSince(now).rounded(.up))) }; func isExpired(at now: Date) -> Bool }`, constructed in start() from `Date()` and the duration. Distinct from the already-noted formatter and process-state-machine test gaps.

**How it fails.** A future refactor reintroduces a decrement-per-tick counter (or switches the deadline to `ProcessInfo.systemUptime`/`DispatchTime`, which pause during sleep on Intel). `swift test` stays green because nothing asserts what remaining time is reported after 'now' jumps forward by an hour, and the wake-desync bug ships again.

**Suggested fix.**

1) Add Sources/NoSleep/SessionDeadline.swift (verified to compile and pass under Swift 6):
```swift
struct SessionDeadline: Sendable, Equatable {
    let end: Date
    init(start: Date, duration: SleepDuration) { end = start.addingTimeInterval(TimeInterval(duration.rawValue)) }
    func remaining(at now: Date) -> Int { max(0, Int(end.timeIntervalSince(now).rounded(.up))) }
    func isExpired(at now: Date) -> Bool { now >= end }
}
```
2) CaffeinateManager.swift: add `private var deadline: SessionDeadline?`. In `start()` (line 114-119) set `deadline = SessionDeadline(start: Date(), duration: selectedDuration)` for timed sessions (nil for .indefinite) and `remainingSeconds = deadline?.remaining(at: Date()) ?? 0`. Replace `private func tick()` (177-184) with an internal `func refreshRemaining(now: Date = Date())` that does `guard isActive, let deadline else { return }; remainingSeconds = deadline.remaining(at: now); if deadline.isExpired(at: now) { timer?.invalidate(); timer = nil }`. Clear `deadline` in stop()/handleTermination(). Have the Timer closure, the menu label, and (from F3) an `NSWorkspace.didWakeNotification` observer all call `refreshRemaining()`; schedule the Timer with `RunLoop.main.add(timer, forMode: .common)` so it also fires while the menu is open.
3) Make the manager constructible under `swift test`: move `notifications.requestAuthorization()` out of `CaffeinateManager.init()` (line 85) into app launch (e.g. `.onAppear` on the MenuBarExtra content or a `configure()` called from NoSleepApp), which is what NotificationManager.swift:31-33 already promises. Then `refreshRemaining(now:)` can be driven directly in a @MainActor test without spawning caffeinate or waiting on a Timer.
4) Add Tests/NoSleepTests/SessionDeadlineTests.swift with table tests using a fixed `t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)`: remaining(at: t0) == 7200 for .twoHours and !isExpired; remaining(at: t0 + 3600) == 3600 ("slept an hour", Timer-free); for .fifteenMin at t0 + 4900: isExpired == true and remaining == 0 ("deadline passed while asleep"); rounding: remaining(at: t0 + 0.4) == 900 and remaining(at: t0 + 899.5) == 1 so the label never shows 0 s early. Optionally one manager-level test: construct CaffeinateManager, set `deadline`/`isActive` via an internal test hook, call `refreshRemaining(now: t0 + 3600)` and assert `remainingSeconds == 3600`, proving the UI path uses the helper.

---

### Swift Testing is available (tools 6.0) and would collapse the table-style tests into parameterized cases

- **Location:** `Tests/NoSleepTests/CaffeinateManagerTests.swift:19`
- **Severity / category:** low / improvement
- **Votes:** single:ok(0.5)

**What is wrong.** With tools-version 6.0 and the Swift 6.3 toolchain, `import Testing` compiles and runs side by side with XCTest under plain `swift test` (verified in a scratch copy: a `@Suite` with `@Test(arguments: [(Int, String)])` ran as '1 test with 5 test cases' alongside the XCTest suite; no Package.swift change needed). The existing five `shouldNotifyOnCompletion` tests are one 4-column truth table, and the formatter (F12) and persistence (F2) cases are also tables. `@Test(arguments:)` reports each row as its own case with the failing inputs in the message, and a `@MainActor @Suite` gives static main-actor isolation for exercising the `@MainActor` manager without annotating every method. Optional; the two can coexist indefinitely.

**How it fails.** Not a defect. Concrete benefit: a failing row in a 12-row XCTest `for` loop reports only 'XCTAssertEqual failed' at the loop line, whereas the parameterized Swift Testing case names the exact `(seconds, expected)` pair, and new rows are one tuple rather than a new method.

**Suggested fix.**

Optional, low priority. Do NOT rewrite the five existing named XCTest methods for their own sake; they already identify the failing case by name. Adopt Swift Testing only when adding new table-shaped tests (e.g. if F12 extracts a static `formatRemaining(seconds:)`), keeping the XCTest file as-is since `swift test` runs both with no Package.swift change (verified). If the notify table is migrated, keep the per-row intent via a label column so the tuple rows do not lose the information the method names currently carry. Verified-working shape (Tests/NoSleepTests/NotifyDecisionTests.swift):

import Testing
@testable import NoSleep

@Suite struct NotifyDecisionTests {
    static let rows: [(label: String, terminated: Int, current: Int, stoppedByUser: Bool, duration: SleepDuration?, expected: Bool)] = [
        ("natural timed expiry",      1, 1, false, .twoHours,   true),
        ("stopped by user",           1, 1, true,  .twoHours,   false),
        ("stale token after restart", 1, 2, false, .twoHours,   false),
        ("indefinite session",        1, 1, false, .indefinite, false),
        ("nil duration",              1, 1, false, nil,         false),
    ]
    @Test(arguments: rows)
    func decision(label: String, terminated: Int, current: Int, stoppedByUser: Bool, duration: SleepDuration?, expected: Bool) {
        #expect(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: terminated, currentToken: current,
            stoppedByUser: stoppedByUser, duration: duration) == expected, "\(label)")
    }
}

Drop the part of the original suggestion about using a `@MainActor @Suite` to exercise the manager itself: `CaffeinateManager()` cannot be constructed under `swift test` with either framework because `init()` (CaffeinateManager.swift:85) calls `requestAuthorization()`, which hits `UNUserNotificationCenter.current()` and aborts the test process (`bundleProxyForCurrentProcess is nil`, signal 6). That would first require moving the `notifications.requestAuthorization()` call out of `CaffeinateManager.init` to app launch (e.g. invoked from NoSleepApp), which is what NotificationManager.swift:31-33 already says the design intends; treat that as a separate change. Also replace the nonexistent `CaffeinateManager.formatRemaining(seconds:)` in the suggestion with whatever static formatter F12 actually introduces; today only the state-dependent instance property `formattedRemaining` (lines 88-101) exists and is untestable for the same instantiation reason.

---

### No CI: nothing runs swift build / swift test / build.sh on push or PR

- **Location:** `Package.swift:15`
- **Severity / category:** low / improvement
- **Votes:** reproduce:ok(0.85), skeptic:ok(0.8), impact:ok(0.8)

**What is wrong.** The repository has no `.github/workflows` directory (verified: `ls .github` -> No such file). The project ships DMGs from `build.sh` (universal `--arch arm64 --arch x86_64` release build plus ad-hoc `codesign`), yet neither the unit tests nor that release build is gated anywhere; PR #2 touched Package.swift, added the test target and changed the concurrency model with only local verification. `swift test` alone does not exercise the universal release build, so a change that only breaks `-c release` or the x86_64 slice (an `#if arch` mistake, or a Swift 6 strict-concurrency error surfacing only in optimised builds) would ship undetected.

**How it fails.** A contributor opens a PR that compiles on their arm64 debug build but trips a Swift 6 data-race diagnostic in release, or changes `formattedRemaining` and breaks a future table test. The PR is merged on visual review, `./build.sh` fails at release time, or the DMG ships with the regression.

**Suggested fix.**

Add a new file `.github/workflows/ci.yml` (no other files change; Package.swift:15 needs no edit — the finding is anchored there only because the test target it declares is what CI would run):

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build-and-test:
    strategy:
      fail-fast: false
      matrix:
        # macos-15: default Xcode 16.4 (Swift 6.1) — closest runner to the
        #   README's documented "Swift 6.0+" minimum.
        # macos-26: default Xcode 26.x — the toolchain the DMG is actually built with.
        runner: [macos-15, macos-26]
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v4
      - name: Toolchain
        run: |
          xcodebuild -version
          swift --version
      - name: Unit tests (debug build of app + test target)
        run: swift test
      - name: Release universal build + ad-hoc sign (same path as the DMG)
        run: ./build.sh
      - name: Verify bundle
        run: |
          lipo -archs NoSleep.app/Contents/MacOS/NoSleep | grep -q 'x86_64 arm64'
          codesign --verify --strict --verbose=2 NoSleep.app
```

Notes versus the original suggestion: do NOT add `sudo xcode-select -s /Applications/Xcode_16.4.app` (redundant on macos-15, fails on macos-26); do NOT add a separate `swift build` step (`swift test` already builds the executable target); do NOT cache `.build` (zero-dependency package, ~10 s build, stale-cache risk after runner Xcode bumps); do NOT use `macos-latest` (it now means macos-26 and will move again). If only one runner is wanted, keep `macos-26` (matches the shipping toolchain) and drop the matrix. Optionally add `![CI](https://github.com/sergio-farfan/nosleep/actions/workflows/ci.yml/badge.svg)` under the title in README.md:1. Do not upload NoSleep.app via actions/upload-artifact without tarring it first (upload-artifact does not preserve executable bits).

---

## 6. Documentation

### README Features/Run/How-it-works not updated for v1.1.0 (8 hr preset, auto-activate, completion notification + Extend, clickable status, permission prompt)

- **Location:** `README.md:43`
- **Severity / category:** medium / docs
- **Votes:** reproduce:ok(0.95), skeptic:ok(0.9), impact:ok(0.88)

**What is wrong.** README still describes the v1.0 interaction model and predates the 'workday option' commit. Specifics: (a) line 43 lists '15 min, 30 min, 1 hr, 2 hr, 4 hr, 10 hr, or Indefinite' but `SleepDuration` (CaffeinateManager.swift:22-31) has eight cases including `.eightHours` ('8 hours'); dev-to-article.md:16 lists it correctly, so the two public docs disagree and the menu shows eight rows vs seven documented. (b) `changeDuration` (lines 163-166) always calls `start()`, so picking any duration immediately spawns caffeinate — README line 74 says only 'Duration — pick how long to keep your Mac awake'. (c) Natural expiry posts a notification with an 'Extend 1 hour' action (NotificationManager.swift:41-64) — README:145 says only 'the app detects this and updates its state' and Features has no notification bullet. (d) The status line is now a clickable toggle Button (MenuBarView.swift:30-39). (e) `requestAuthorization()` runs at launch, so first launch shows a system 'NoSleep would like to send you notifications' dialog — README:26 says only 'a cup icon appears'. dev-to-article.md:15-18 documents all of this; README is the outlier and is the file users read from the repo/DMG.

**How it fails.** User following README line 74 selects '4 hours' just to set a preference and is surprised caffeinate is already running; a user looking for a workday preset sees no 8 hr option and picks 10 hr or looks elsewhere; a user denies the unexplained first-launch permission dialog and later never receives the completion notification the app is built around, with no doc telling them how to re-enable it.

**Suggested fix.**

Docs-only change to README.md (no Swift changes, no build impact). Exact edits:

1. Line 26 (Installation, after "a cup icon (☕) appears in your menu bar."), append a paragraph:
   "On first launch macOS also asks whether NoSleep may send you notifications. Allow it to get the session-ended alert with its **Extend 1 hour** button; you can change this later in **System Settings → Notifications → NoSleep**."

2. Features block, lines 42-46, replace with:
   - **One-click toggle** — start/stop caffeinate from the menu bar
   - **Auto-activate** — selecting a duration starts immediately; re-selecting while active restarts with the new duration
   - **Duration presets** — 15 min, 30 min, 1 hr, 2 hr, 4 hr, 8 hr, 10 hr, or Indefinite
   - **Live countdown** — green dot and remaining time in the menu while active (e.g. `2h 34m`)
   - **Completion notification** — when a timed session ends, a notification offers a one-tap **Extend 1 hour**
   - **Start at Login** — optional LaunchAgent for auto-start
   - **Prevents display + idle sleep** — uses `caffeinate -d -i`

3. Run section, lines 73-78, replace the bullet list and trailing sentence with:
   - **Status line** — shows `Inactive` or `Active — 2h 34m left` with a green dot; clicking it toggles start/stop
   - **Start/Stop** — toggle caffeinate on or off
   - **Duration** — pick a preset; NoSleep starts (or restarts) immediately with that duration
   - **Start at Login** — enable to launch NoSleep automatically on boot
   - **Quit** — stop caffeinate and exit the app

   The icon changes to a filled cup when active. When a timed session ends, a notification appears with an **Extend 1 hour** button that starts a fresh 1-hour session.

4. Project Structure, lines 121-124: add after the CaffeinateManager.swift line
   `│       ├── NotificationManager.swift # Session-ended notification + Extend action`
   and change the CaffeinateManager comment to `# caffeinate process + countdown + expiry detection`; add after the Sources block
   `├── Tests/`
   `│   └── NoSleepTests/`
   `│       └── CaffeinateManagerTests.swift # Unit tests for the notify-on-completion rule`

5. How It Works, line 145, replace with:
   "When you quit NoSleep or click Stop, the caffeinate process is terminated and no notification is posted. If caffeinate's `-t` timer expires naturally, the app detects the child exit, returns to Inactive, and posts a **session ended** notification (via `UserNotifications`) with an **Extend 1 hour** action. Tapping it starts a fresh 1-hour session and moves the duration selection to 1 hour. Indefinite sessions never post a notification."

Optional (not required): dev-to-article.md is already accurate on features but also omits the first-launch permission prompt; a one-line note after line 181 would keep the two docs aligned. Verification: `git diff --stat` should show README.md only; render Markdown to confirm the tree block still aligns.

---

### README promises 'prevents your Mac from sleeping'; -d -i only stops idle sleep and time keeps elapsing while asleep

- **Location:** `README.md:46`
- **Severity / category:** medium / docs
- **Votes:** reproduce:ok(0.9), skeptic:ok(0.75), impact:ok(0.75)

**What is wrong.** README.md:3 says NoSleep 'prevents your Mac from sleeping', :46 'Prevents display + idle sleep — uses caffeinate -d -i', :140-145 describe the flags, and :145 says the session ends when 'caffeinate's timer expires naturally'; dev-to-article.md:20 repeats the claim. `-d -i` create PreventUserIdleDisplaySleep / PreventUserIdleSystemSleep assertions (see `man caffeinate`), which only suppress *idle* sleep. Closing a MacBook lid, Apple menu > Sleep, pressing the power key, `pmset sleepnow`, a scheduled sleep or a low-battery sleep all still put the Mac to sleep with the session active; no power assertion can prevent forced sleep (`-s`, which only applies on AC power, is the closest flag and is not offered). The docs also say nothing about what happens to a session that spans a sleep: the wall-clock deadline keeps running (powerd's timeout), so a '4 hours' session with an hour of lid-closed sleep yields three hours of protection, and the completion notification arrives on wake. Users pick this tool specifically for long unattended jobs (downloads, builds, presentations); the current wording leads them to close the lid and expect the job to keep running.

**How it fails.** User reads 'prevents your Mac from sleeping', starts a 4-hour session to finish a large upload, closes the lid to carry the laptop to another room. The Mac sleeps immediately, the upload stalls, and on reopening the countdown has silently lost the sleep time (or, on Intel, shows Active after protection ended). Nothing in the README told them lid-close is not covered or that time keeps elapsing while asleep; user reports NoSleep 'did not work'.

**Suggested fix.**

Docs-only change; no code, no new menu option.

1. README.md:3 — replace
   "A lightweight macOS menu bar utility that prevents your Mac from sleeping."
   with
   "A lightweight macOS menu bar utility that keeps your Mac from going to sleep due to inactivity (idle sleep)."

2. README.md:46 — replace
   "- **Prevents display + idle sleep** — uses `caffeinate -d -i`"
   with
   "- **Prevents idle display + idle system sleep** — uses `caffeinate -d -i` (see [Limitations](#limitations))"

3. README.md:141 — replace "- `-d` — prevent the display from sleeping" with
   "- `-d` — prevent the display from turning off due to inactivity"
   (line 142 "-i — prevent the system from idle sleeping" is already correct).

4. README.md:145 — replace
   "If caffeinate's timer expires naturally, the app detects this and updates its state."
   with
   "A timed session is a fixed wall-clock deadline: macOS releases the assertion when the deadline passes, even if the Mac was asleep for part of that time. When caffeinate exits, the app detects this, updates its state and posts the completion notification."

5. Insert a new section directly after "## How It Works" (before "## License", i.e. after current line 145):

   ## Limitations

   - **Only idle sleep is prevented.** Closing a MacBook's lid, choosing  > Sleep, pressing the power button, scheduled sleep and low-battery sleep still put the Mac to sleep while NoSleep is active. This is macOS policy for the `-d -i` assertions (Apple documents that they "may still sleep for lid close, Apple menu, low battery, or other sleep reasons"), not something NoSleep can override. To keep a closed MacBook running use clamshell mode (external display + power + keyboard/mouse).
   - **Time spent asleep still counts.** A 4-hour session started at 09:00 ends at 13:00 regardless of whether the Mac slept in between; the remaining-time display may be off until it catches up, and the completion notification appears on wake.
   - **On battery, `-d` keeps the screen on for the whole session.** Pick a short preset or lower brightness if you are not plugged in.

6. dev-to-article.md:20 — same rewording as README:46 ("Prevents idle display + idle system sleep — uses `caffeinate -d -i`").
   dev-to-article.md:104 — change "`-d` prevents the display from sleeping, `-i` prevents idle sleep. Together they cover the common use cases." to "`-d` prevents idle display sleep, `-i` prevents idle system sleep. They cover the common 'walked away from the keyboard' case; they do not stop lid-close, Apple-menu or low-battery sleep, and a timed session ends at its wall-clock deadline even if the Mac slept in between."

Do NOT add a `-s` toggle or recommend `caffeinate -s` for lid-close: IOPMLib.h marks the PreventSystemSleep assertion type deprecated/unsupported, its lid-close behaviour is undocumented, and keeping a closed laptop awake in a bag is a thermal hazard. If the deadline-based countdown (F3) lands, drop the clause "the remaining-time display may be off until it catches up" from bullet 2.

---

### 'One-tap Extend 1 hour' is hidden behind hover > Options with the default Banner style

- **Location:** `dev-to-article.md:18`
- **Severity / category:** medium / docs
- **Votes:** single:ok(0.85)

**What is wrong.** On macOS a new app's notifications default to the Banner style, which auto-dismisses after a few seconds and shows registered actions only when the user hovers and opens the 'Options' pop-up. The 'Extend 1 hour' action is therefore neither one-tap nor visible unless the user switches NoSleep to the 'Alerts' style in System Settings > Notifications > NoSleep. Neither README nor the article (dev-to-article.md:18 'a notification offers a one-tap Extend 1 hour') mentions this, so the headline v1.1.0 feature is effectively invisible for most users. Independent of the already-noted missing `.list` presentation option, which only affects retention in Notification Center, and of the already-noted README feature-list staleness.

**How it fails.** Timed session ends while the user glances away; banner shows 'Your 2 hours session has ended.' with no visible button and disappears after ~5 s. User never discovers the Extend action and re-opens the menu manually every time.

**Suggested fix.**

Do both a code fix and a doc fix.

1. build.sh (Info.plist heredoc, after the LSUIElement pair around line 57): opt the app into the persistent style by default so the completion notification stays on screen until acted on:
    <key>NSUserNotificationAlertStyle</key>
    <string>alert</string>
This is the same documented Info.plist key Apple's own App Store.app / Keychain Circle Notification.app use. Caveat: macOS captures the default style when the bundle ID first registers with Notification Center, so users who already ran v1.1.0 keep 'Banners' until they change it manually -- hence step 2.

2. README.md: add a short 'Notifications' subsection under Run (after line 78), e.g.:
"When a timed session ends, NoSleep posts a notification with an **Extend 1 hour** action. macOS shows notification buttons only when you hover the notification; if NoSleep's style is set to Banners it also disappears after a few seconds. To keep it on screen until you act, set **System Settings > Notifications > NoSleep > Alert style** to **Alerts** (new installs of 1.1.x default to this). With Banners, hover the banner and click **Extend 1 hour** (it may sit under **Options**)."

3. dev-to-article.md:7 and :18: soften 'one-tap' to e.g. "a notification with an **Extend 1 hour** action (hover the notification, or use the Alerts style, to see it)".

Optionally also add .list to the willPresent options in NotificationManager.swift:72 so the item is retained in Notification Center when the app is frontmost (already tracked as a separate finding).

---

### Uninstall section only removes ~/Applications copy; the recommended DMG install lives in /Applications and the LaunchAgent is never unloaded

- **Location:** `README.md:105`
- **Severity / category:** low / docs
- **Votes:** reproduce:ok(0.95), skeptic:ok(0.92), impact:ok(0.9)

**What is wrong.** 'Option 1 — Download the DMG (recommended)' (lines 13-26), the Gatekeeper command on line 21 (`/Applications/NoSleep.app`) and package-dmg.sh:34 (symlink to /Applications) all install to /Applications, while install.sh:7 installs to ~/Applications. The Uninstall block only runs `rm -rf ~/Applications/NoSleep.app`, so DMG users following it leave the app installed. It also deletes the LaunchAgent plist without `launchctl bootout`, so the loaded job persists for the session. The other two lines are correct: the plist path matches LoginItemManager.swift:23-29 and `defaults delete com.nosleep.app` is the right domain (CFBundleIdentifier from build.sh:41; confirmed ~/Library/Preferences/com.nosleep.app.plist exists on this machine).

**How it fails.** User installed via DMG into /Applications, follows README Uninstall verbatim -> `rm -rf ~/Applications/NoSleep.app` is a silent no-op, /Applications/NoSleep.app remains, and if Start at Login was on the still-loaded agent has already launched it this session.

**Suggested fix.**

README.md only (no Swift changes). Replace lines 101-112 with:

## Uninstall

Quit NoSleep from its menu bar icon first (**Quit NoSleep**) so caffeinate is stopped and no preferences are written back, then:

```bash
# Remove the app (the DMG installs to /Applications, install.sh to ~/Applications)
rm -rf /Applications/NoSleep.app ~/Applications/NoSleep.app

# Remove the Start-at-Login agent (if enabled): unregister it from launchd for the
# current session, then delete the plist so it is not loaded at next login
launchctl bootout gui/$(id -u)/com.nosleep.app 2>/dev/null
rm -f ~/Library/LaunchAgents/com.nosleep.app.plist

# Remove saved preferences
defaults delete com.nosleep.app 2>/dev/null
```

Notes for the maintainer:
- Use the service-target form `gui/$(id -u)/com.nosleep.app` (not the plist-path form) so the bootout works regardless of whether the plist still exists; the "Boot-out failed: 3: No such process" message when Start at Login was never enabled is expected and silenced by 2>/dev/null.
- `rm -rf /Applications/NoSleep.app` works without sudo for admin users; non-admin users (who needed admin credentials to install there) get a visible "Permission denied" rather than a silent no-op, which is acceptable; optionally add "(prefix with sudo if you are not an administrator)".
- Do not change install.sh's default destination: ~/Applications needs no admin rights and is documented at README.md:35, 80-86 and 134. Optional, minimal: in install.sh:7 use `INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"`, `DEST="$INSTALL_DIR/${APP_NAME}.app"`, `mkdir -p "$INSTALL_DIR"`, and change the PlistBuddy Set path at line 25 to `$DEST/Contents/MacOS/${APP_NAME}`.
- If F6 (SMAppService) is adopted, replace the two LaunchAgent lines with "turn off Start at Login in the NoSleep menu (or System Settings > General > Login Items) before deleting the app", since SMAppService registration references the bundle and deleting the bundle first leaves a dangling login item.

---

### Project Structure tree is missing NotificationManager.swift, Tests/, docs/, and other tracked files

- **Location:** `README.md:116`
- **Severity / category:** low / docs
- **Votes:** single:ok(0.97)

**What is wrong.** The tree (lines 116-136) predates v1.1.0. The repo actually contains `Sources/NoSleep/NotificationManager.swift` (all UserNotifications logic), `Tests/NoSleepTests/CaffeinateManagerTests.swift` (the XCTest target declared in Package.swift:15-19), `docs/superpowers/specs/…` and `docs/superpowers/plans/…`, `dev-to-article.md`, `LICENSE` (linked from line 153) and `assets/screenshot1.png` (used on line 8). The Package.swift annotation also says nothing about the test target.

**How it fails.** A contributor looking for where notifications are implemented or where to add tests sees no such files in the documented layout and assumes there is no test target.

**Suggested fix.**

Replace README.md lines 116-136 with an accurate tree reflecting the v1.1.0 layout:

```
nosleep/
├── Package.swift                  # SPM config (macOS 14+, SwiftUI, XCTest target)
├── Sources/
│   └── NoSleep/
│       ├── NoSleepApp.swift       # App entry point, MenuBarExtra
│       ├── MenuBarView.swift      # Dropdown menu UI
│       ├── CaffeinateManager.swift # caffeinate process + countdown + expiry tokens
│       ├── NotificationManager.swift # UNUserNotificationCenter: completion banner + "Extend 1 hour" action
│       └── LoginItemManager.swift  # LaunchAgent plist management
├── Tests/
│   └── NoSleepTests/
│       └── CaffeinateManagerTests.swift # XCTest — run with `swift test`
├── scripts/
│   └── generate-art.swift         # AppKit renderer for icon + DMG background
├── assets/
│   ├── AppIcon.icns               # App icon (generated)
│   ├── AppIcon.png                # 1024px icon master (generated)
│   ├── dmg-background*.png        # DMG window background (generated)
│   └── screenshot1.png            # README screenshot
├── docs/superpowers/
│   ├── specs/                     # Approved design specs
│   └── plans/                     # Implementation plans
├── build.sh                       # Build universal binary + bundle + code sign
├── make-icons.sh                  # Regenerate icon/background art
├── package-dmg.sh                 # Build styled NoSleep-<version>.dmg
├── install.sh                     # Install to ~/Applications
├── dev-to-article.md              # Source for the dev.to write-up
├── LICENSE                        # GPL-3.0
└── README.md
```

Also add a one-line "Run tests: `swift test`" under the existing "## Build" section (README.md:54), since nothing in the README currently tells contributors a test suite exists. Optionally, in "## Features" (line 40) and "## How It Works" (line 138), add a bullet for the v1.1.0 behavior: on natural timer expiry NoSleep posts a completion notification with an "Extend 1 hour" action — the README currently has zero mention of notifications, which is the same staleness root cause (7dbf7e8 did not update README).

---

### Plan, spec, article and code each give a different location for requestAuthorization(); plan/spec status never updated after shipping

- **Location:** `docs/superpowers/plans/2026-07-01-menu-activation-and-notifications.md:506`
- **Severity / category:** low / docs
- **Votes:** single:ok(0.85)

**What is wrong.** Four sources disagree on where notification setup is triggered: the plan (Task 4 Step 2, lines 503-507) says `.onAppear { manager.notifications.requestAuthorization() }` on the menu VStack, i.e. lazily on first menu open, and its Task 3 init (lines 313-318) has no call; the spec (design.md:106-110) says NoSleepApp.swift triggers it once at launch via `.task`; the shipped code calls it from `CaffeinateManager.init()` (line 85) and MenuBarView has no onAppear; dev-to-article.md:181 explicitly says the lazy on-menu-open approach the plan prescribes 'can drop the action response' because the delegate must be set before launch finishes. The plan also still shows all steps unchecked and the spec's Status is 'Approved (pending spec review)' although the work shipped in 7dbf7e8 / v1.1.0. Anyone re-running the plan (it is addressed to agentic workers) would re-introduce the lazy registration the article calls a bug.

**How it fails.** An agent or contributor follows the plan literally, adds `.onAppear { requestAuthorization() }`, and the completion notification's Extend action is dropped when the app was launched but the menu was never opened before the session expired.

**Suggested fix.**

Docs-only change; the shipped code placement is correct and should be kept (verified: @StateObject init runs before applicationWillFinishLaunching).

1. docs/superpowers/specs/2026-07-01-menu-activation-and-notifications-design.md
   - Line 5: `**Status:** Implemented — v1.1.0 (PR #2, 7dbf7e8)`.
   - Replace the `### NoSleepApp.swift (changes)` section (lines 106-110) with: `### NoSleepApp.swift — unchanged` and move the registration statement to the CaffeinateManager section: 'CaffeinateManager.init() calls notifications.requestAuthorization(). Because CaffeinateManager is a @StateObject of the App, its init runs before applicationWillFinishLaunching, which satisfies Apple's requirement that UNUserNotificationCenter.delegate be set before the app finishes launching (otherwise a notification action that launches the app is dropped).'
   - Append `## Implementation notes / deviations` listing: (a) registration moved from lazy .onAppear to CaffeinateManager.init in 5e4c2b65 for the reason above; (b) NoSleepApp.swift untouched.

2. docs/superpowers/plans/2026-07-01-menu-activation-and-notifications.md
   - Add under the header: `**Status:** Completed 2026-07-01 (merged as 7dbf7e8 / v1.1.0). Do not re-execute.` and flip all 31 `- [ ]` to `- [x]`.
   - Task 3 Step 1 init snippet (lines 313-318): add `notifications.requestAuthorization()` after the onExtend line, with a comment `// must run before the app finishes launching (sets UNUserNotificationCenter.delegate)`.
   - Task 4: delete `manager.notifications.requestAuthorization()` from the Consumes line (461); replace lines 503-507 with a note: '~~Attach .onAppear { manager.notifications.requestAuthorization() }~~ **Superseded (5e4c2b65):** lazy registration on first menu open violates Apple's requirement that the notification-center delegate be set before launch finishes and can drop the "Extend 1 hour" response when the app is launched by the notification. Registration lives in CaffeinateManager.init(); do NOT add .onAppear.' Rename the step to 'Add the statusDot helper'.
   - Task 2 Step 3 temp probe (lines 246-269) may keep .onAppear since it is a throwaway test, but add '(temporary probe only — see Task 4 note)'.

3. Optional, in code (coordinate with F1 if it relocates the call): add a one-line comment above CaffeinateManager.swift:85 — `// Runs before the app finishes launching (StateObject init precedes applicationWillFinishLaunching); UNUserNotificationCenter.delegate must be set by then or launch-time action responses are dropped.` — so the next reader does not "simplify" it back into the view.

---

### Article claims SMAppService requires a sandboxed app; it does not, and that wrong claim justifies the fragile plist design

- **Location:** `dev-to-article.md:133`
- **Severity / category:** low / docs
- **Votes:** single:ok(0.93)

**What is wrong.** The article states 'Rather than using `SMAppService` (which requires a sandboxed app), NoSleep writes a LaunchAgent plist directly' and closes with 'This approach works without sandboxing'. `SMAppService.mainApp` (macOS 13+) has no App Sandbox requirement; it is the standard replacement for `SMLoginItemSetEnabled`/LSSharedFileList for any bundled app, including ad-hoc-signed ones, and is what puts the app in System Settings > Login Items > 'Open at Login'. The sandbox association comes from the legacy `SMLoginItemSetEnabled` helper pattern. README line 45 ('optional LaunchAgent for auto-start') inherits the same framing. The genuine trade-off the article should state is that the hand-written plist hard-codes `Bundle.main.executablePath` at enable time (which is why install.sh needs a PlistBuddy patch) whereas SMAppService tracks the bundle (see F6).

**How it fails.** A reader adopts the article's recommendation for their own non-sandboxed menu-bar app, ships a LaunchAgent with a hard-coded executable path, and hits the DMG/translocation/move breakage described in F6 — steered away from the correct API for a wrong reason.

**Suggested fix.**

Rewrite dev-to-article.md lines 131-151 (section "Login Item: LaunchAgent Plist") to remove the false sandbox claim and state the real trade-off. Two acceptable versions:

(A) Preferred — once F6 (switch to SMAppService) lands, retitle the section "Login Item: SMAppService" and replace the plist listing with the real code, e.g.:

```swift
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled = SMAppService.mainApp.status == .enabled

    func toggle() {
        do {
            if isEnabled { try SMAppService.mainApp.unregister() }
            else         { try SMAppService.mainApp.register() }
        } catch { /* log; .requiresApproval → SMAppService.openSystemSettingsLoginItems() */ }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
```
with prose: "`SMAppService.mainApp` (macOS 13+) is Apple's replacement for both `SMLoginItemSetEnabled` and hand-installed `~/Library/LaunchAgents` plists. Its only requirement is that the app be a code-signed bundle — an ad-hoc signature is enough; notarization is only needed for LaunchDaemons, and App Sandbox is irrelevant. The system tracks the bundle, so the item survives moving the app, and it shows up under System Settings > General > Login Items with the app's name."

(B) If the plist approach is kept, replace :133 and :151 with honest text: "NoSleep writes a LaunchAgent plist directly rather than using `SMAppService.mainApp` (macOS 13+, works for any code-signed bundle, sandboxed or not). Writing the plist keeps the mechanism transparent and gives full control over launchd keys, but it hard-codes the executable path at enable time — moving the app (or running it from a mounted DMG, where the path is translocated) breaks auto-start until you toggle Start at Login off and on; that is why install.sh patches `ProgramArguments` with PlistBuddy. Note that since macOS 13, Background Task Management still picks the plist up: it appears in System Settings > General > Login Items under 'Allow in the Background' as an unnamed legacy agent and triggers the 'Background Items Added' notification."

In both cases also update README.md: :45 "Start at Login — optional LaunchAgent for auto-start" → "Start at Login — registers the app as a Login Item (System Settings > General > Login Items)" (for A) or keep but append the move-requires-re-enable caveat (for B); :86 drop "and updates the LaunchAgent path if Start at Login is enabled" once install.sh no longer needs the PlistBuddy step; :107-108 Uninstall → for A: "Turn off Start at Login (or remove NoSleep under System Settings > General > Login Items) before deleting the app"; :124 comment "LaunchAgent plist management" → "Login item (SMAppService)". Also fix the article's front-matter bullet at dev-to-article.md:19 ("optional LaunchAgent so it auto-starts on boot") to match.

---

### Article suggests right-click → Open as a Gatekeeper bypass; that no longer works on macOS 15+

- **Location:** `dev-to-article.md:228`
- **Severity / category:** low / docs
- **Votes:** single:ok(0.95)

**What is wrong.** Line 228 says 'On first launch, run the xattr command above (or right-click → Open) once.' Since macOS 15 Sequoia, Control/right-click → Open no longer overrides Gatekeeper for software that is not notarized; the user must go to System Settings → Privacy & Security → Open Anyway. README (lines 17-24) correctly describes the System Settings route, so the two docs disagree. The app supports macOS 14+, so most current readers are on 15 or later.

**How it fails.** Reader on macOS 15/26 right-clicks NoSleep.app → Open, gets the same 'cannot be opened' dialog, and concludes the app is broken.

**Suggested fix.**

In dev-to-article.md:228 replace "On first launch, run the `xattr` command above (or right-click → Open) once." with: "On first launch, either run the `xattr` command above once, or try to open the app, then go to **System Settings → Privacy & Security** and click **Open Anyway**. (Right-click → Open only bypasses Gatekeeper on macOS 14 Sonoma; Sequoia and later removed that override for non-notarized apps.)" Optionally also append the Settings alternative after the code block at lines 218-222 so the "Download-and-run distribution" section matches README.md:17-24 verbatim. No code changes needed.

---

### README omits the 'Background Items Added' alert and System Settings location for Start at Login; says 'on boot'

- **Location:** `README.md:45`
- **Severity / category:** low / docs
- **Votes:** reproduce:ok(0.9), skeptic:ok(0.8), impact:ok(0.72)

**What is wrong.** README.md:45 ('optional LaunchAgent for auto-start') and :75 ('launch NoSleep automatically on boot'), plus dev-to-article.md:19, describe Start at Login without any of the macOS 13+ Background Task Management consequences the user will actually see: (1) enabling it triggers a system 'Background Items Added' notification (NoSleep is ad-hoc signed, so there is no verified developer name attached to the item); (2) the item appears in System Settings > General > Login Items & Extensions under 'Allow in the Background', not under 'Open at Login' where users look for a 'Start at Login' feature; (3) switching it off there is authoritative and the in-app checkmark will not reflect it (see F2). 'On boot' is also wrong: a gui-domain LaunchAgent runs at that user's login only, never at boot and never for other accounts on the Mac.

**How it fails.** A user enables Start at Login, immediately gets an unexpected macOS security-style alert about background items with no developer name, searches the README for an explanation and finds none; some users will click into System Settings and turn it off, after which the README's description of the feature ('launch automatically on boot') is simply false for them, with no troubleshooting guidance.

**Suggested fix.**

Docs-only change, three files, no code impact.

1. README.md line 45 (Features bullet, keep it short):
   `- **Start at Login** — optional per-user LaunchAgent that launches NoSleep when you log in`

2. README.md line 75 (Run section, where the menu item is described) replace with:
   `- **Start at Login** — launch NoSleep automatically when you log in (per user account, not at boot).`
   `  The first time you enable it macOS shows a **"Background Items Added"** notification — expected,`
   `  and because NoSleep is ad-hoc signed no developer name is attached. Manage or revoke it under`
   `  **System Settings → General → Login Items** (macOS 15+: **Login Items & Extensions**) →`
   `  **Allow in the Background**. If NoSleep stops launching at login, check it is still switched on there.`

3. README.md line 107 (Uninstall comment) optionally: `# Remove the LaunchAgent (if enabled) — this also removes it from Login Items`

4. dev-to-article.md line 19:
   `- **Start at Login** — optional LaunchAgent so it auto-starts when you log in`

Follow-up coupling: if F2 is adopted (switch to SMAppService.mainApp, which does not require sandboxing — also correct dev-to-article.md:133 then), change the README.md:75 text to say the item appears under **Open at Login** and drop the "Allow in the Background" reference; verify on-device whether the "Background Items Added" alert still fires for mainApp registration before keeping that sentence.

---

### README says Command Line Tools suffice, but swift test needs full Xcode (CLT has no XCTest)

- **Location:** `README.md:30`
- **Severity / category:** low / docs
- **Votes:** reproduce:ok(0.96), skeptic:ok(0.7), impact:ok(0.8)

**What is wrong.** README (lines 30 and 51) and the plan (docs/superpowers/plans/...:19, 'Verify with: swift test') present the Xcode Command Line Tools as the only toolchain requirement. The CLT does not ship XCTest.framework, so the test target cannot even be built with CLT alone. Verified on this machine in a temp copy: `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build --build-tests` fails with `CaffeinateManagerTests.swift:19:8 unable to resolve module dependency: 'XCTest'`, while the app product itself builds fine. Confirmed in the dedup pass: /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ contains Testing.framework (Swift Testing) and the _Testing_* overlays but no XCTest.framework, so the suite would run on a CLT-only machine if it were written with Swift Testing. This is a toolchain-compatibility defect, distinct from the already-noted stylistic case for parameterized Swift Testing cases.

**How it fails.** A contributor follows README 'Requirements' (installs CLT via xcode-select --install, no Xcode.app), runs ./build.sh successfully, then runs `swift test` as the plan instructs -> build error 'unable to resolve module dependency: XCTest'; no tests run. A CI runner or Homebrew-style build box without Xcode.app hits the same wall.

**Suggested fix.**

Prefer fix (a): migrate the suite to Swift Testing so `swift test` works on the toolchain README actually requires (CLT), and stop relying on XCTest which the CLT does not ship. Verified 5/5 pass under both CLT-only and Xcode.

1. Tests/NoSleepTests/CaffeinateManagerTests.swift — keep the existing GPL header (lines 1-17, required by the plan's Global Constraints), then replace lines 19-47 with:

```swift
import Testing
@testable import NoSleep

struct CaffeinateManagerTests {
    @Test func notifiesOnNaturalTimedExpiry() {
        #expect(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: false, duration: .twoHours))
    }

    @Test func noNotifyWhenStoppedByUser() {
        #expect(!CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: true, duration: .twoHours))
    }

    @Test func noNotifyOnStaleTokenFromRestart() {
        #expect(!CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 2, stoppedByUser: false, duration: .twoHours))
    }

    @Test func noNotifyForIndefinite() {
        #expect(!CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: false, duration: .indefinite))
    }

    @Test func noNotifyForNilDuration() {
        #expect(!CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: false, duration: nil))
    }
}
```
No `@MainActor` or `await` is needed: `shouldNotifyOnCompletion` is `nonisolated static` (Sources/NoSleep/CaffeinateManager.swift:62). No Package.swift change is needed — SwiftPM 6.0's `swift test` discovers Swift Testing tests by default, and Testing.framework is part of every Swift 6 toolchain (CLT and Xcode), so the plan's "no new external dependencies" rule is respected.

2. README.md — after the Build section's numbered list (line 63) add a short "## Test" section (or a line under "## Build"):
```
## Test

```bash
swift test
```
Runs the unit tests (Swift Testing). Works with the Command Line Tools alone; full Xcode is not required.
```
README currently does not mention the test suite at all, so this also fixes a documentation gap.

3. Optional, to keep docs consistent with the code: docs/superpowers/plans/2026-07-01-menu-activation-and-notifications.md:9 "XCTest" -> "Swift Testing" and :25 "add an XCTest `testTarget`" -> "add a `testTarget` (Swift Testing)". If the plan is treated as a frozen historical record, leave it and rely on the README note instead.

Do NOT take fix (b) (documenting "tests require Xcode.app"): it locks in a multi-GB dependency for a 5-test suite when the zero-cost migration above removes the problem entirely.

---

### Documented from-source flow leaves two LS-registered copies; cold Extend/open picks one arbitrarily

- **Location:** `README.md:34`
- **Severity / category:** low / docs
- **Votes:** single:ok(0.75)

**What is wrong.** README lines 33-35 tell the user to `open NoSleep.app` from the repo root (registering that dev-build path with LaunchServices under com.nosleep.app) and then run `./install.sh`, which copies to `~/Applications` without unregistering or removing the repo copy; the DMG path adds `/Applications`. Any launch that goes through LaunchServices by bundle ID — a cold-start 'Extend 1 hour' response, Spotlight, `open -b` — resolves to whichever copy LS prefers, not necessarily the one the LaunchAgent (README:86) points at or the one that posted the notification. `build.sh` then `rm -rf`s and recreates the repo copy on every build, so the registered dev path can also be momentarily missing. On this machine only `~/Applications/NoSleep.app` is currently resolvable, so the hazard materialises only after following the README's two-copy instructions. Distinct from the already-noted single-instance-guard and uninstall-section findings.

**How it fails.** Developer follows README: `./build.sh`, `open NoSleep.app`, `./install.sh`, later enables Start at Login (LaunchAgent → ~/Applications). Weeks later a session ends, the user quits, then taps Extend: LaunchServices launches the stale repo-root build (older code, different behaviour) rather than the installed copy; at next login the LaunchAgent starts the ~/Applications copy as well.

**Suggested fix.**

Goal: leave exactly one com.nosleep.app bundle on disk after installing, since LS auto-registers any .app under $HOME within seconds of build.sh creating it (removing `open NoSleep.app` from the README alone does nothing).

1. install.sh (after line 19 `cp -R "$APP_BUNDLE" "$DEST"`): unregister and remove the source so the repo build cannot compete:
   ```bash
   LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
   "$LSREGISTER" -u "$APP_BUNDLE" >/dev/null 2>&1 || true
   rm -rf "$APP_BUNDLE"      # keep a single copy; re-run ./build.sh before ./package-dmg.sh
   "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
   ```
   (or simply `mv "$APP_BUNDLE" "$DEST"` in place of `cp -R`). Also `pkill -x NoSleep || true` before copying is optional but avoids a running repo instance registering itself again on quit.
2. README.md:32-36 — reorder Option 2 to `./build.sh && ./install.sh && open ~/Applications/NoSleep.app` and add one sentence: "Keep only one copy of NoSleep.app. macOS launches the app by bundle ID for notification actions and Spotlight, and with two copies it picks the one with the higher version (otherwise unpredictably); install.sh therefore moves the build out of the repo." Same edit in the Run/Install sections (README:65-86) and dev-to-article.md:234-243.
3. README.md:104-105 Uninstall — cover both install locations: `rm -rf ~/Applications/NoSleep.app /Applications/NoSleep.app` (and, for developers, `rm -rf <repo>/NoSleep.app`).
4. Optional hardening in code: in LoginItemManager.enable() (LoginItemManager.swift:47) or at launch, warn/log when `NSWorkspace.shared.urlsForApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)` returns more than one URL, so a duplicate install is visible instead of silent.

---

### 'How It Works' never says macOS lists the sleep blocker as 'caffeinate', not NoSleep

- **Location:** `README.md:140`
- **Severity / category:** low / docs
- **Votes:** single:ok(0.85)

**What is wrong.** README.md:138-145 explains the flags but not what the user will see while NoSleep is active. Because NoSleep spawns /usr/bin/caffeinate with no -w argument, powerd owns the assertion under the child pid: on this host the Battery menu ('Preventing your Mac from sleeping automatically'), Activity Monitor → Energy → Preventing Sleep and `pmset -g assertions` all show 'caffeinate' with the reason 'THE CAFFEINATE TOOL IS PREVENTING SLEEP.' / 'caffeinate command-line tool' and no mention of NoSleep; the NoSleep row in Activity Monitor says 'Preventing Sleep: No'. The running NoSleep's child (pid 65684) was byte-for-byte indistinguishable in pmset from an unrelated `caffeinate -i -t 300` (pid 75348) spawned by another tool. There is no documented way to tell NoSleep's caffeinate from any other. The code-side remedies (add `-w <own pid>` so powerd records 'Created for PID: N', or hold an in-process named IOPMAssertion) are already on the confirmed list; until one lands, the README is the only place this can be explained, and it should be updated to match whichever fix is chosen.

**How it fails.** User installs the DMG, sees 'caffeinate' under 'Preventing your Mac from sleeping automatically' in the Battery menu, searches the README for 'caffeinate is preventing sleep' or 'Battery menu', finds nothing, and either assumes malware/another app or force-quits caffeinate in Activity Monitor (which then triggers a misleading 'Your session has ended' banner).

**Suggested fix.**

In README.md, insert after line 143 (end of the flag list) and before the existing "When you quit NoSleep or click Stop..." paragraph at line 145, a short "What macOS shows" note. Text for the CURRENT code (no -w):

"**What you will see while NoSleep is active.** macOS attributes the sleep assertion to the `caffeinate` process, not to NoSleep. The Battery menu (*Preventing your Mac from sleeping automatically*), Activity Monitor → Energy → *Preventing Sleep*, and `pmset -g assertions` all list `caffeinate` with the reason \"caffeinate command-line tool\" — that is NoSleep working; the NoSleep row itself shows *Preventing Sleep: No*. To confirm the `caffeinate` you see belongs to NoSleep: `pgrep -P \"$(pgrep -x NoSleep)\" -lx caffeinate`. Always stop it from the NoSleep menu (Stop or Quit) rather than force-quitting `caffeinate` in Activity Monitor — NoSleep treats an external kill of a timed session as a completed session and shows the \"Your … session has ended.\" banner."

Then keep the README in step with whichever code fix lands: (a) if `-w <NoSleep pid>` is added to args at CaffeinateManager.swift:113, change the paragraph to say `pmset -g assertions` shows `caffeinate asserting on behalf of Process ID <NoSleep pid>` / `Created for PID: <NoSleep pid>` (verified: -t still ends the run on time with -w, but pmset no longer prints a "Timeout will fire" line because caffeinate enforces the timeout itself); (b) if an in-process named IOPMAssertion replaces the child process, rewrite the section to say the assertion is named "NoSleep …" and appears as NoSleep in the Battery menu, Activity Monitor and pmset, and drop the pgrep tip. Also update the "Prevents display + idle sleep" bullet at README.md:46 or the "Run" section at 71-78 with a one-line pointer to this note so users looking at the Battery menu find it.

---

### Manual verification uses bare `pgrep caffeinate`, which cannot isolate NoSleep's process

- **Location:** `docs/superpowers/plans/2026-07-01-menu-activation-and-notifications.md:546`
- **Severity / category:** low / docs
- **Votes:** single:ok(0.9)

**What is wrong.** The plan's acceptance steps (lines 19, 536, 546, 556, 566) and the spec (line 146) use `pgrep caffeinate` as the pass/fail oracle: 'prints a PID' after Start/Extend and 'prints nothing' after Stop. caffeinate is a shared system tool; during this review two unrelated instances were alive on the host (pid 65684 from the installed NoSleep, pid 75348 `caffeinate -i -t 300` from a different tool). The Stop check therefore fails spuriously whenever anything else uses caffeinate, and the Start check passes vacuously even if NoSleep's `proc.run()` threw (CaffeinateManager.swift:130 swallows the error).

**How it fails.** Tester has Homebrew/CI/another NoSleep copy running caffeinate. Step 'Click Stop → `pgrep caffeinate` prints nothing' fails although NoSleep stopped correctly; conversely, if NoSleep failed to spawn, 'Start → prints a PID' still passes because of the foreign process, so the regression ships.

**Suggested fix.**

In the plan (lines 19, 536, 546, 556, 566) and spec line 146, replace bare `pgrep caffeinate` with a parent-scoped, argument-showing check that targets the copy actually under test. Add to Step 1 (plan ~line 529):

```bash
./build.sh && open NoSleep.app
sleep 1; NS=$(pgrep -nx NoSleep)        # newest NoSleep = the copy just launched (the installed ~/Applications copy may still be running)
chk() { pgrep -lfP "$NS" caffeinate; }  # only THIS NoSleep's caffeinate child, with its arguments
```

Then rewrite the expectations:
- Step 2 (line 536): `chk` prints `<pid> /usr/bin/caffeinate -d -i -t 7200`.
- Step 4 (line 546): `chk` prints nothing (exit 1).
- Step 5 (line 556): `chk` prints `<pid> /usr/bin/caffeinate -d -i -t 3600`.
- Step 6 (line 566): `chk` prints `<pid> /usr/bin/caffeinate -d -i` (no `-t`) — this makes the existing "(no -t)" clause actually verifiable; bare `pgrep` never prints arguments.
- Line 19 and spec line 146: "`pgrep -lfP <NoSleep pid> caffeinate` reflects start/stop".

Optional stronger oracle (checks powerd actually holds the assertion): `pmset -g assertions | grep "pid $(pgrep -P "$NS" -x caffeinate)(caffeinate)"` should list `PreventUserIdleSystemSleep` and `PreventUserIdleDisplaySleep` while active and nothing after Stop.

Do NOT use the originally suggested `pgrep -P "$(pgrep -x NoSleep)"` one-liner as-is: it exits 2 with a usage error when 0 or >1 NoSleep instances exist (newline-separated list). If a single-line form is wanted, comma-join: `pgrep -lfP "$(pgrep -x NoSleep | paste -sd, -)" caffeinate`. Also drop the `pmset ... "Created for PID: $(pgrep -x NoSleep)"` idea: pmset reports the assertion under caffeinate's pid (`pid N(caffeinate):`), never NoSleep's, and `-w` does not change that.

---

### Docs never say whether the idle screen saver / auto-lock are held off (they are)

- **Location:** `README.md:46`
- **Severity / category:** low / docs
- **Votes:** single:ok(0.9)

**What is wrong.** The hypothesis that `caffeinate -d` does not hold off the screen saver / 'Require password after screen saver begins' lock was tested on this host and is FALSE, so no code bug is reported. Evidence: (1) loginwindow's ScreenSaverDaemon explicitly consults the system-wide PreventUserIdleDisplaySleep assertion before launching the screen saver (literal strings 'PreventUserIdleDisplaySleep' and 'PMNoDisplaySleepEnabled so do not launch screen saver' in /System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow). (2) Unified log, 2026-09-10: while NoSleep.app (pid 1456) had '/usr/bin/caffeinate -d -i' (pid 65684) running from 17:50:31, loginwindow logged every 300 s through 18:30:33 '_checkUserIdleDuringReset: actualUserIdle = 274.8 … 2374.8, targetUserIdle = 300.0' followed by 'PMNoDisplaySleepEnabled so do not launch screen saver' (79 such decisions in 24 h) with idleTime=300 and lock delay 'immediate' configured. (3) The one real screen-saver launch that day (11:55:28) happened when no PreventUserIdleDisplaySleep assertion existed. (4) The console lock during the run was a manual kAELockScreenEvent at 17:50:52, not idle. Side note: IOPMAssertionDeclareUserActivity / `caffeinate -u` do NOT reset HIDIdleTime, so a 'heartbeat' would not have been the right mechanism anyway. What remains actionable is documentation: the presentation use case (dev-to-article.md:1) and feature bullets (README.md:46, :141, dev-to-article.md:104) only say 'Prevents display + idle sleep' and never answer the question every presenter asks — 'will my screen saver / screen lock still kick in?' — nor state what still locks (manual lock, hot corner, lid close).

**How it fails.** A user with a corporate 5-minute screen-saver + immediate-lock policy reads README.md:3/46 before a presentation, cannot tell whether NoSleep covers the screen saver / auto-lock, and either disables the screen saver in System Settings unnecessarily or distrusts the tool and runs a mouse jiggler as well — even though NoSleep already holds both off.

**Suggested fix.**

Documentation only; no code change. Apply the same sentence in four places so README and article agree:

1. README.md:46 — replace the Features bullet with:
   - **Prevents display + idle sleep** — uses `caffeinate -d -i`. While a session is active macOS also skips the idle screen saver, so the "Require password after screen saver begins or display is turned off" lock will not trigger from inactivity. Closing the lid, hot corners, and Lock Screen (Ctrl-Cmd-Q) still lock as usual.

2. README.md:141 — extend the `-d` line in How It Works:
   - `-d` — prevent the display from sleeping. This also holds off the idle screen saver (loginwindow checks for a PreventUserIdleDisplaySleep assertion before launching it), which means the inactivity screen lock is deferred for as long as the session runs. Once the session ends or the timer expires, the screen saver and lock can start within moments if you have been idle.

3. dev-to-article.md:20 — same Features-bullet sentence as (1).

4. dev-to-article.md:104 — replace "Together they cover the common use cases." with: "A side effect worth knowing for the presentation case: with a display-sleep assertion held, macOS also skips the idle screen saver, so your auto-lock won't kick in mid-talk. Manual lock, hot corners and lid close still work. Prefer a timed preset over Indefinite if your machine is subject to a corporate auto-lock policy — an unattended Mac with NoSleep active stays unlocked."

Optionally add the same caution as a short "Note" under README.md ## Run (after line 78), since it is a security-relevant behaviour users may not expect.

---

## Refuted findings (kept for the record)

These were raised by finders but did not survive verification.

- **`_ = NSApplication.shared` is unnecessary and adds a WindowServer dependency to the icon pipeline** (`scripts/generate-art.swift:27`)
  - single: Only the trivial part of F28 holds: `_ = NSApplication.shared` at scripts/generate-art.swift:27 is not needed for output (all three PNGs are byte-identical with lines 26-27 deleted; md5 886f8dc1…, 2e7a3354…, ab423697… in both runs). Everything load-bearing in the finding is false on the supported pl…
- **@testable import of the executableTarget works today; a NoSleepCore library target would remove the dependency on SwiftPM's entry-point rewriting** (`Package.swift:11`)
  - single: The finding's description of the mechanism is accurate, but its failure scenario cannot be substantiated on the target platform and two of its supporting claims are wrong or only half-true.

1. Failure scenario not reproducible. On the exact toolchain in use (Swift 6.3.3 / Xcode 26.6, macOS 27) ever…
- **Session end is tracked on three different clocks and child exit is treated as authoritative; system sleep desyncs UI and protection** (`Sources/NoSleep/CaffeinateManager.swift:116`)
  - reproduce: The code facts are as described (CaffeinateManager.swift:113-119 seeds remainingSeconds and passes -t; :139-144 a repeating 1 s Timer decrements it in tick() :177-184; :186-209 treats the child's terminationHandler as end of session; no NSWorkspace.didWakeNotification observer anywhere). But the fin…
- **LaunchAgent omits AssociatedBundleIdentifiers, so the login item is not attributed to the app in System Settings** (`Sources/NoSleep/LoginItemManager.swift:49`)
  - single: The premise is accurate (the plist built at LoginItemManager.swift:49-54 has no AssociatedBundleIdentifiers, and launchd.plist(5) says a legacy plist installed by an app "should include this key"), but the claimed failure scenario does not occur for NoSleep, and the evidence shows the key would not …
- **'Open Anyway' path does not exist for an ad-hoc-signed quarantined app** (`README.md:23`)
  - single: The finding asserts that a quarantined, ad-hoc-signed NoSleep.app triggers Gatekeeper's "is damaged and can't be opened. You should move it to the Trash." dialog, which has no Open Anyway path, so README.md:23-24's "Privacy & Security -> Open Anyway" bullet is a dead end. I reproduced the exact dist…
- **Timeout path kills osascript after `open` but never closes the Finder window before detaching** (`package-dmg.sh:77`)
  - reproduce: F11's causal chain is: watcher kills osascript between `open` (line 56) and `close` (line 69) → Finder window left open → `hdiutil detach` (line 94) hits EBUSY → stray Finder window on a still-mounted volume. Two links in that chain are contradicted by evidence. (1) The watcher never kills osascript…
- **No wait for .DS_Store to be persisted between AppleScript `close` and detach; 'Layout applied.' can be a false positive** (`package-dmg.sh:92`)
  - single: The finding's premise — that Finder still has an unflushed .DS_Store when osascript returns, so an immediate `sync; hdiutil detach` can produce an image with a missing/partial layout — does not hold for this script, for two independent reasons that I reproduced experimentally on this machine (macOS …

