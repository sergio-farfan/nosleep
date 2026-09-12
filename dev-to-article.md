Have you ever been mid-presentation, watching a long build compile, or waiting for a large file to download — only for your Mac to decide it's nap time? macOS ships a built-in tool for exactly this: `caffeinate`. But running it from the terminal every time is clunky.

So I built **NoSleep** — a tiny macOS menu bar utility that wraps `caffeinate` in a one-click toggle. No Dock icon. No main window. Just a cup icon in your menu bar.

![NoSleep menu bar dropdown](https://raw.githubusercontent.com/sergio-farfan/nosleep/61b7b5a3e0c6d021656bc61f7ecd30a5a904690b/assets/screenshot1.png)

> **Update — v1.2.0:** a full code review of the whole repository (about 500 lines of app Swift plus the build and packaging scripts) turned up far more than I expected — a dozen confirmed bugs in the app alone, among them a first-launch default that silently meant *Indefinite*, a countdown that froze while you were looking at it, and a `caffeinate` child that outlived the app after a crash. The eight headline bugs are fixed below, Start at Login is rebuilt on `SMAppService`, the packaging scripts are fixed too, the menu got native checkmarks, an in-menu record of the last session, **Activate on Launch** and **About**, and the test suite went from 5 to 87. Details in the [v1.2.0 section](#v120-eight-bugs-a-login-item-rewrite-and-87-tests) below. Download: [NoSleep-1.2.0.dmg](https://github.com/sergio-farfan/nosleep/releases/download/v1.2.0/NoSleep-1.2.0.dmg) (universal, macOS 14+). The 1.2.0 DMG was rebuilt on 2026-09-12 to include the menu additions; both builds report 1.2.0, so if your menu has no **About NoSleep** item, download it again.
>
> **Update — v1.1.0:** NoSleep now ships as a downloadable, drag-to-install `.dmg` (universal), activates the moment you pick a duration, shows a green active indicator with a readable countdown, and pops a notification with an **Extend 1 hour** action when a timed session ends (hover the notification to reveal the button; the *Alerts* style keeps it on screen until you do). The new bits — and the async race the notification introduced — are covered in the [v1.1.0 section](#v110-autoactivate-completion-alerts-and-a-real-download) below.

---

## Features

- **Download & run** — grab the `.dmg` from Releases and drag NoSleep to Applications (universal: Apple Silicon + Intel)
- **One-click toggle** — start/stop caffeinate from the menu bar
- **Auto-activate** — pick a duration and it starts immediately, no extra click
- **Duration presets** — 15 min, 30 min, 1 hr, 2 hr, 4 hr, 8 hr, 10 hr, or Indefinite
- **Live countdown** — a green active dot and remaining time while active (e.g. `2h 34m`); after a timed session ends, the menu says when
- **Completion notification** — when a timed session ends, a notification offers **Extend 1 hour** (hover the notification to reveal the button; the *Alerts* style keeps it on screen until you do)
- **Start at Login** — registers a login item so it auto-starts when you log in (a LaunchAgent plist in ≤ 1.1.0, `SMAppService` since 1.2.0)
- **Activate on Launch** — optional: start the saved duration the moment NoSleep launches, so login-time protection needs no click
- **Single instance** — launching a second copy exits immediately, and a lock-aware build quits a still-running pre-lock copy (1.1.0, or the 1.2.0 DMG published before 2026-09-12) and its caffeinate, so an upgrade cannot leave two icons
- **Prevents display + idle sleep** — uses `caffeinate -d -i`

---

## The Stack

- **Swift 6.0** with strict concurrency
- **SwiftUI** + `MenuBarExtra` (macOS 13+)
- **UserNotifications** — for the session-complete alert and its Extend action
- **Observation** (`@Observable`) — replaced `ObservableObject` in 1.2.0
- **ServiceManagement** (`SMAppService`) — Start at Login since 1.2.0
- **Swift Package Manager** — no Xcode project file required; ships a **universal binary**
- Minimum target: **macOS 14 (Sonoma)**

---

## App Entry Point: MenuBarExtra

The entire app lives in the menu bar, which SwiftUI makes surprisingly clean with `MenuBarExtra`:

```swift
@main
struct NoSleepApp: App {
    @StateObject private var caffeinateManager = CaffeinateManager()
    @StateObject private var loginManager = LoginItemManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(manager: caffeinateManager, loginManager: loginManager)
        } label: {
            Image(systemName: caffeinateManager.isActive
                  ? "cup.and.saucer.fill"
                  : "cup.and.saucer")
        }
    }
}
```

That's the whole entry point. `MenuBarExtra` handles all the menu bar plumbing — no `NSStatusItem`, no AppKit boilerplate. The icon toggles between a filled and outlined cup based on whether caffeinate is running.

Setting `LSUIElement: true` in `Info.plist` hides the Dock icon and removes the main window entirely.

---

## Core Logic: CaffeinateManager

The heart of the app is `CaffeinateManager` — an `@MainActor` `ObservableObject` that manages the `caffeinate` child process and a countdown timer.

### Spawning the Process

```swift
func start() {
    stop()

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")

    var args = ["-d", "-i"]
    if selectedDuration != .indefinite {
        args += ["-t", "\(selectedDuration.rawValue)"]
        remainingSeconds = selectedDuration.rawValue
    }
    proc.arguments = args

    proc.terminationHandler = { [weak self] _ in
        Task { @MainActor [weak self] in
            self?.handleTermination()
        }
    }

    try? proc.run()
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

A few things worth noting:

**`-d -i` flags** — `-d` prevents the display from sleeping, `-i` prevents idle sleep. Together they cover the common use cases.

**`-t <seconds>`** — when a duration is selected, caffeinate self-terminates after that many seconds. The app also runs a `Timer` in parallel to track remaining time for the UI.

**`terminationHandler`** — if caffeinate exits on its own (duration expired, or the system killed it), this handler fires and cleans up app state. The `Task { @MainActor in ... }` pattern bridges from the background callback thread into the main actor, which Swift 6 strict concurrency requires. (In v1.1.0 this handler grew a *run-token* guard — more on why below.)

### Duration Options

Durations are a typed enum with raw values in seconds:

```swift
enum SleepDuration: Int, CaseIterable, Identifiable, Sendable {
    case fifteenMin = 900
    case thirtyMin  = 1800
    case oneHour    = 3600
    case twoHours   = 7200
    case fourHours  = 14400
    case eightHours = 28800
    case tenHours   = 36000
    case indefinite = 0
}
```

The selected duration is persisted in `UserDefaults` so the preference survives app restarts.

---

## Login Item: LaunchAgent Plist

> **Correction (v1.2.0):** this section describes NoSleep ≤ 1.1.0. `SMAppService` does **not** require a sandboxed app — that was my mistake — and the plist approach below broke silently whenever the bundle moved (the path is baked in at enable time) and reported "enabled" purely from the file's existence. Since 1.2.0 NoSleep uses `SMAppService.mainApp`, reads the real Background Task Management status, and carries an existing plist's setting over when launched from an installed copy — see [Start at Login, done properly](#start-at-login-done-properly) below.

NoSleep 1.1.0 wrote a `LaunchAgent` plist directly to `~/Library/LaunchAgents/`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.nosleep.app</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/you/Applications/NoSleep.app/Contents/MacOS/NoSleep</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

This approach works without sandboxing and gives full control over the plist.

---

## v1.1.0: Auto-Activate, Completion Alerts, and a Real Download

### Pick a duration → it just starts

Originally you picked a duration and then clicked Start. Now selecting any preset activates immediately:

```swift
func changeDuration(_ duration: SleepDuration) {
    selectedDuration = duration
    start()   // auto-activate on selection (re-selecting restarts the timer)
}
```

### A completion notification you can act on

When a timed session ends, NoSleep posts a notification with an **Extend 1 hour** action, using `UserNotifications`:

```swift
let extend = UNNotificationAction(identifier: "EXTEND_1H",
                                  title: "Extend 1 hour", options: [])
let category = UNNotificationCategory(identifier: "SESSION_COMPLETE",
                                      actions: [extend],
                                      intentIdentifiers: [], options: [])
UNUserNotificationCenter.current().setNotificationCategories([category])
```

Tapping **Extend 1 hour** starts a fresh one-hour session. One gotcha: the delegate has to be registered **at launch** — Apple requires it *before the app finishes launching*, so doing it lazily when the menu first opens can drop the action response.

### The stale-termination trap

Here's the interesting bug the notification surfaced. `caffeinate` runs as a child process; when it exits, its `terminationHandler` fires on a background thread. But that handler fires for *three* different reasons: the timer expired (→ notify), the user hit Stop (→ don't notify), or a **restart** replaced the process (→ don't notify, and don't clobber the new session's state).

The restart case is a classic async race: `start()` calls `stop()` (terminating the old process), then launches a new one — but the old process's termination callback arrives *later*, after the new session is already live. A naive "was this a user stop?" flag misfires.

The fix is a monotonic **run token**. Each `start()` bumps a counter, and the termination handler captures the value it was launched with:

```swift
func start() {
    stop()
    runToken += 1
    let token = runToken
    // ...spawn caffeinate...
    proc.terminationHandler = { [weak self] _ in
        Task { @MainActor [weak self] in self?.handleTermination(token: token) }
    }
}

private func handleTermination(token: Int) {
    guard token == runToken else { return }   // stale (restarted) — ignore it
    // ...decide natural-expiry vs user-stop, then maybe post the notification
}
```

Because the main actor runs `start()` synchronously through the token bump, any stale handler that arrives afterward sees a token that no longer matches — and bails out before touching the new session or firing a notification. The whole "should this fire?" decision is a small pure function, which made it easy to unit-test in isolation.

### Download-and-run distribution

The biggest change for users: NoSleep now ships a real `.dmg`. The entire pipeline uses only tooling that's already on every Mac — no third-party dependencies:

- **App icon** — a small AppKit script renders the `cup.and.saucer.fill` SF Symbol onto a gradient squircle, then `sips` + `iconutil` turn it into `AppIcon.icns`.
- **Universal binary** — `swift build -c release --arch arm64 --arch x86_64`.
- **Styled DMG** — `hdiutil` plus a little AppleScript lay out the window: the app on the left, an arrow to an Applications drop-target, a background image, and a volume icon.

Because it's ad-hoc signed (not notarized), the first launch needs a one-time Gatekeeper nudge:

```bash
xattr -dr com.apple.quarantine /Applications/NoSleep.app
```

---

## v1.2.0: Eight Bugs, a Login Item Rewrite, and 87 Tests

Before this release I ran an automated, multi-agent code review over the whole repository: ten lens-specific reviewers, every bug and medium-severity finding checked by three adversarial verifiers (reproduce / skeptic / impact) and lower-severity items by one, then two further verification passes over the fixes themselves. It found more than I expected in about 500 lines of app Swift plus the scripts around it. The snippets earlier in this article show the 1.1.0 code; here is what changed and why.

### The default that was secretly "Indefinite"

```swift
let saved = UserDefaults.standard.integer(forKey: "selectedDuration")
self.selectedDuration = SleepDuration(rawValue: saved) ?? .fourHours
```

Looks fine. But `integer(forKey:)` returns `0` for a missing key, and `0` is the raw value of `.indefinite`. So the fallback never ran, and every fresh install started with **Indefinite** selected — the one preset with no timer and no completion notification. The fix reads the raw object and decides in a pure, unit-tested function:

```swift
nonisolated static func restoredDuration(from stored: Int?) -> SleepDuration {
    guard let stored, let saved = SleepDuration(rawValue: stored) else { return .fourHours }
    return saved
}
// in init:  restoredDuration(from: defaults.object(forKey: key) as? Int)
```

### The child that outlived its parent

`caffeinate` is a child process. If NoSleep crashed, was force-quit, or got `kill`ed, macOS did **not** kill the child — it was reparented to launchd and kept the Mac awake with no UI attached (forever, for Indefinite). `caffeinate` has a flag for exactly this, and it composes with `-t`:

```swift
var args = ["-d", "-i", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
```

`-w <pid>` releases the assertion and exits as soon as that process is gone.

### The countdown that froze while you looked at it

`Timer.scheduledTimer` registers in the run loop's `.default` mode. While an `NSMenu` is open, the main run loop runs in `NSEventTrackingRunLoopMode` — where `.default`-mode timers never fire. So the "live countdown" stood still exactly while the menu was open. Worse, each tick *decremented* a counter, so every second spent looking at the menu went uncounted, and for the rest of the session the display showed more time than actually remained — caffeinate's `-t` timer expired while the menu still showed minutes left.

Two changes: add the timer in `.common` mode, and derive the value from a deadline instead of counting down:

```swift
let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
    MainActor.assumeIsolated { self?.tick() }
}
RunLoop.main.add(t, forMode: .common)

func tick() {
    remainingSeconds = max(0, Int((deadlineUptime - uptime()).rounded(.up)))
    // …
}
```

The deadline is on `ProcessInfo.systemUptime`, the same clock family `caffeinate -t` uses, so both pause together during system sleep. There is a test for this that puts the main run loop into a tracking-style common mode and checks the countdown still moves; reverting to `.default` fails it.

### Two percent CPU for nothing

That 1 Hz tick wrote an `@Published` property on the app-root `@StateObject`. Every write fired `objectWillChange`, which invalidated the whole `MenuBarExtra` scene, which re-set the status bar button's image, laid it out, committed to WindowServer and re-snapshotted the item for both appearances — about 20 ms of main-thread work per second — the review measured roughly 2 % CPU with the menu *closed*, for a glyph that had not changed.

Migrating to the Observation framework fixed it with almost no code:

```swift
@MainActor @Observable
final class CaffeinateManager {
    var isActive = false
    private(set) var remainingSeconds = 0
    // …
}

// NoSleepApp:  @State private var caffeinateManager = CaffeinateManager()
```

`@Observable` tracks *which properties* each view read. The menu-bar label only reads `isActive`, so `remainingSeconds` ticking away no longer touches it. In the same measurement the same tick under `@Observable` cost about 0.1 %.

### The crash outside an .app bundle

`UNUserNotificationCenter.current()` raises `bundleProxyForCurrentProcess is nil` and aborts the process unless you are running from a real `.app`. `CaffeinateManager.init()` called it — so `swift run` died instantly, and no unit test could construct the manager. Only the pure notify-decision function had tests; the state machine the whole app depends on had none.

The fix: guard on `Bundle.main.bundleURL.pathExtension == "app"`, and give the manager three injectable seams — a launcher (`CaffeinateLaunching`), a notification poster (`NotificationPosting`) and a store (`DurationStore`). With fakes for all three, the whole start / stop / restart / termination machine runs under `swift test` without spawning a process or touching `UserDefaults`.

### The stale Extend button

Delivered notifications sit in Notification Center indefinitely. A "Your 2 hours session has ended" banner from the morning still had a live **Extend 1 hour** button at 4 pm — and tapping it replaced whatever session was running with a one-hour one. Now every `stop()` (which every restart goes through) clears delivered notifications, and `extendOneHour()` ignores the action while a session is active.

### "Session has ended" — no, it was killed

The termination handler treated every exit the same, so `killall caffeinate` produced a cheerful completion notification. The launcher now reads the exit reason and only a clean exit counts as expiry:

```swift
proc.terminationHandler = { p in
    let clean = p.terminationReason == .exit && p.terminationStatus == 0
    Task { @MainActor in onTermination(clean) }
}
```

There is also a test that runs the real launcher against `/usr/bin/true`, `/usr/bin/false` and a `terminate()`d `sleep`, so the mapping itself is covered — not just the code that consumes it.

### Start at Login, done properly

The LaunchAgent approach I described above was wrong twice. `SMAppService` never required a sandbox. And baking `Bundle.main.executablePath` into a plist meant the login item broke silently the moment the app moved — say, from the mounted DMG to Applications — while the toggle stayed checked because the file still existed.

1.2.0 uses `SMAppService.mainApp`. The toggle reflects the real Background Task Management status, refreshed every time the menu opens; if the item needs your approval a caption says so, and clicking the toggle takes you to System Settings › Login Items instead of trying to re-register. An existing 1.1.0 plist is migrated when the app is launched from an installed copy. If the old agent was still on, the plist is only deleted once the new registration is actually `.enabled` — while it awaits your approval the plist stays and a later launch finishes the job. If you had already switched the old agent off under Login Items, the plist is removed without registering anything, so "off" carries over. Either way nobody loses the setting on upgrade. The migration decision is a pure function with its own tests, because the first version of it had a bug the review's second pass caught: it treated "registered, awaiting approval" as "the user turned it off".

### Packaging, too

The DMG script assumed its image would mount at `/Volumes/NoSleep`; with a NoSleep DMG already open it mounted at `/Volumes/NoSleep 1` and the script ejected the wrong disk. It now refuses to run while a NoSleep volume is already mounted, reads the device node back from `hdiutil attach` so it can only ever detach its own image, retries `detach` while Finder still holds the volume, and ships a multi-resolution TIFF background so Retina displays get the sharp version. The app icon no longer includes 16 and 32 px representations, which current macOS (verified on 27) draws shrunk on a grey plate.

### The improvements that rode along

The same review listed a second tier of things that were not bugs but were worth doing. A second pass of the same automated process landed them on 2026-09-12, two days after the first 1.2.0 build, and I rebuilt the 1.2.0 DMG rather than cut a new version — so if you downloaded it before then, download it again. Everything below came from the review except the About box, which I added on my own:

- **Native checkmarks.** The duration presets are real menu toggles, so the selected one gets the system checkmark (and VoiceOver reads it), instead of SF Symbol dots that recent macOS stopped drawing in menus.
- **The menu remembers.** When a timed session runs out, the status line shows an orange dot and "Kept awake for 2 hours — ended 14:32" until you start something new, so a missed notification no longer leaves you guessing. The wording gains the date once it is no longer today's.
- **Activate on Launch.** An opt-in toggle that starts the saved duration as soon as the app launches — the missing half of Start at Login.
- **About NoSleep.** Icon, name, tagline and the installed version, one click away.
- **Extend keeps your preference.** "Extend 1 hour" runs a one-hour session without overwriting the duration you had picked; the checkmark follows the running session and snaps back afterwards.
- **One instance.** A kernel file lock (`O_EXLOCK`) arbitrates between copies started by `open`, a login item and launchd within the same millisecond — my first attempt used `NSRunningApplication`, and the review's probes caught it racing: two copies started together left zero or two instances, because a directly exec'd copy is not registered with LaunchServices until `NSApplication` initialises and two LaunchServices-launched copies can each see the other and both exit. A lock-aware build also quits a still-running pre-lock build, so upgrading by dragging the DMG over the old app cannot leave two icons.
- **Notifications.** The banner reads "Session ended / Kept your Mac awake for 2 hours. It can sleep again.", stays in Notification Center, and new installs get the persistent *Alerts* style, so the notification stays on screen until you act (hover it to reveal the Extend button). If you have denied notifications, the menu offers to open the right System Settings pane.
- **Packaging.** The DMG finally ships its volume icon — Finder was deleting the file during the layout step, so it is now applied afterwards — plus Apple's 824-point icon grid, the GPL text inside the bundle, and proper `Info.plist` metadata.
- **CI.** Every push to `main` now builds, runs the tests, produces the signed universal bundle, packages and verifies the DMG, and lints the shell scripts on a GitHub-hosted Mac.

### Tests: 5 → 87

Every Swift fix above except the Observation migration has a test that fails if the fix is reverted (the packaging changes are shell scripts and assets, outside the test target): the pure decisions, the state machine through fakes, the real launcher's exit mapping, the run-loop-mode test, a deadline-resync test with an injected clock (two ticks inside one second must not double-decrement; one tick after a 65 s stall must jump to the right value), the login-item migration against a scripted fake and a temp plist, the instance lock (exclusivity, stale contents, no leak into the child), the launch hook, the ended-session cue, and the notification text and action routing.

The lesson I am taking from this release: the bugs were not in the clever part (the run-token race from 1.1.0 held up fine). They were in the boring parts — a default value, a run-loop mode, a child process nobody waits for — and none of them were reachable by tests until the class could be constructed outside an `.app`.

**Download:** [NoSleep-1.2.0.dmg](https://github.com/sergio-farfan/nosleep/releases/download/v1.2.0/NoSleep-1.2.0.dmg) — universal (Apple Silicon + Intel), macOS 14+. Open it, drag **NoSleep** onto Applications, and do the one-time Gatekeeper step in [Build & Install](#build-install) below. Upgrading from 1.1.0 or from the earlier 1.2.0 build just means replacing the app; your Start at Login setting is carried over, and the new copy quits the old one for you.

---

## Build & Install

**Easiest:** download `NoSleep-<version>.dmg` from the [latest release](https://github.com/sergio-farfan/nosleep/releases), open it, and drag **NoSleep** onto Applications. On first launch, run the `xattr` command above once (or open it, then **System Settings → Privacy & Security → Open Anyway**).

**From source** — the project uses Swift Package Manager, no `.xcodeproj` needed:

```bash
# Build (universal binary, bundles, ad-hoc code signs)
./build.sh

# Run
open NoSleep.app

# Package a distributable .dmg
./package-dmg.sh

# Install to ~/Applications (optional)
./install.sh
```

Requirements to build: Swift 6.0+, Xcode Command Line Tools (full Xcode for `swift test`), macOS 14+.

---

## Source Code

NoSleep is open source under the GPLv3.

**GitHub:** [github.com/sergio-farfan/nosleep](https://github.com/sergio-farfan/nosleep)

Contributions, issues, and stars are all welcome. If you run into any macOS quirks with `caffeinate`, `MenuBarExtra`, or notifications from an ad-hoc-signed app, feel free to open an issue.

---

*Built with Swift 6 and SwiftUI on macOS Sonoma.*
