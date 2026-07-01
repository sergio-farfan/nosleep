Have you ever been mid-presentation, watching a long build compile, or waiting for a large file to download — only for your Mac to decide it's nap time? macOS ships a built-in tool for exactly this: `caffeinate`. But running it from the terminal every time is clunky.

So I built **NoSleep** — a tiny macOS menu bar utility that wraps `caffeinate` in a one-click toggle. No Dock icon. No main window. Just a cup icon in your menu bar.

![NoSleep menu bar dropdown](https://raw.githubusercontent.com/sergio-farfan/nosleep/dd59c6e/assets/screenshot1.png)

> **Update — v1.1.0:** NoSleep now ships as a downloadable, drag-to-install `.dmg` (universal), activates the moment you pick a duration, shows a green active indicator with a readable countdown, and pops a notification with a one-tap **Extend 1 hour** when a timed session ends. The new bits — and the async race the notification introduced — are covered in the [v1.1.0 section](#v110-auto-activate-completion-alerts-and-a-real-download) below.

---

## Features

- **Download & run** — grab the `.dmg` from Releases and drag NoSleep to Applications (universal: Apple Silicon + Intel)
- **One-click toggle** — start/stop caffeinate from the menu bar
- **Auto-activate** — pick a duration and it starts immediately, no extra click
- **Duration presets** — 15 min, 30 min, 1 hr, 2 hr, 4 hr, 8 hr, 10 hr, or Indefinite
- **Live countdown** — a green active dot and remaining time while active (e.g. `2h 34m`)
- **Completion notification** — when a timed session ends, a notification offers a one-tap **Extend 1 hour**
- **Start at Login** — optional LaunchAgent so it auto-starts on boot
- **Prevents display + idle sleep** — uses `caffeinate -d -i`

---

## The Stack

- **Swift 6.0** with strict concurrency
- **SwiftUI** + `MenuBarExtra` (macOS 13+)
- **UserNotifications** — for the session-complete alert and its Extend action
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

Rather than using `SMAppService` (which requires a sandboxed app), NoSleep writes a `LaunchAgent` plist directly to `~/Library/LaunchAgents/`:

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

## Build & Install

**Easiest:** download `NoSleep-<version>.dmg` from the [latest release](https://github.com/sergio-farfan/nosleep/releases), open it, and drag **NoSleep** onto Applications. On first launch, run the `xattr` command above (or right-click → Open) once.

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

Requirements to build: Swift 6.0+, Xcode Command Line Tools, macOS 14+.

---

## Source Code

NoSleep is open source under the GPLv3.

**GitHub:** [github.com/sergio-farfan/nosleep](https://github.com/sergio-farfan/nosleep)

Contributions, issues, and stars are all welcome. If you run into any macOS quirks with `caffeinate`, `MenuBarExtra`, or notifications from an ad-hoc-signed app, feel free to open an issue.

---

*Built with Swift 6 and SwiftUI on macOS Sonoma.*
