// CaffeinateManager.swift
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
import Observation
import os
import SwiftUI

enum SleepDuration: Int, CaseIterable, Identifiable, Sendable {
    case fifteenMin = 900
    case thirtyMin  = 1800
    case oneHour    = 3600
    case twoHours   = 7200
    case fourHours  = 14400
    case eightHours = 28800
    case tenHours   = 36000
    case indefinite = 0

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .fifteenMin: "15 minutes"
        case .thirtyMin:  "30 minutes"
        case .oneHour:    "1 hour"
        case .twoHours:   "2 hours"
        case .fourHours:  "4 hours"
        case .eightHours: "8 hours"
        case .tenHours:   "10 hours"
        case .indefinite: "Indefinite"
        }
    }
}

// MARK: - Process seam

/// A running `caffeinate` child. Abstracted so the start/stop/restart/termination
/// state machine can be unit-tested without spawning a real process.
@MainActor
protocol CaffeinateHandle: AnyObject {
    var isRunning: Bool { get }
    func terminate()
}

extension Process: CaffeinateHandle {}

/// Launches `caffeinate`. `onTermination(clean)` must be invoked exactly once, on
/// the main actor, when the process exits for any reason. `clean` is true only
/// for a normal exit with status 0 (the `-t` timer fired); it is false when the
/// process was terminated by a signal — by `stop()` or by something external.
@MainActor
protocol CaffeinateLaunching {
    func launch(arguments: [String],
                onTermination: @escaping @MainActor (_ clean: Bool) -> Void) throws -> any CaffeinateHandle
}

/// Production launcher: Foundation `Process` around /usr/bin/caffeinate.
struct ProcessCaffeinateLauncher: CaffeinateLaunching {
    /// Overridable so the terminationReason/terminationStatus → `clean` mapping
    /// can be exercised with fast, deterministic stand-ins in tests.
    var executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")

    func launch(arguments: [String],
                onTermination: @escaping @MainActor (_ clean: Bool) -> Void) throws -> any CaffeinateHandle {
        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = arguments
        proc.terminationHandler = { p in
            // Runs on a background thread; read the reason here and hop once.
            let clean = p.terminationReason == .exit && p.terminationStatus == 0
            Task { @MainActor in onTermination(clean) }
        }
        try proc.run()
        return proc
    }
}

// MARK: - Persistence seam

/// The one key/value pair the manager persists. Abstracted so tests can inject
/// an in-memory store: every `UserDefaults` suite, even a throwaway one, is
/// materialised by cfprefsd as ~/Library/Preferences/<suite>.plist, and
/// `removePersistentDomain(forName:)` does not unlink the file.
@MainActor
protocol DurationStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: DurationStore {}

// MARK: - Manager

@MainActor
@Observable
final class CaffeinateManager {
    nonisolated private static let log = Logger(subsystem: "com.nosleep.app", category: "session")

    // `nonisolated` so the pure helpers and XCTest can reference it.
    nonisolated static let durationKey = "selectedDuration"

    var isActive = false
    /// Whole seconds left in a timed session; recomputed from `deadlineUptime`
    /// on every tick so missed timer fires (menu open, main-thread stall,
    /// system sleep) resynchronise instead of accumulating drift.
    private(set) var remainingSeconds: Int = 0
    var selectedDuration: SleepDuration {
        didSet {
            defaults.set(selectedDuration.rawValue, forKey: Self.durationKey)
        }
    }

    // MARK: Pure decisions (unit-tested)

    /// Should a process termination fire a "session complete" notification?
    /// True only when the terminated run is still the current one (not a
    /// restart), the user didn't press Stop, the child exited normally (not
    /// killed by a signal, e.g. `killall caffeinate`), and the session was a
    /// timed (non-indefinite) duration.
    nonisolated static func shouldNotifyOnCompletion(
        terminatedToken: Int,
        currentToken: Int,
        stoppedByUser: Bool,
        terminationWasClean: Bool,
        duration: SleepDuration?
    ) -> Bool {
        guard terminatedToken == currentToken else { return false }
        guard !stoppedByUser else { return false }
        guard terminationWasClean else { return false }
        guard let duration, duration != .indefinite else { return false }
        return true
    }

    /// The duration to restore from a stored raw value. `nil` means the key was
    /// never written (fresh install) → 4 hours.
    ///
    /// Do NOT feed this `UserDefaults.integer(forKey:)`: that returns 0 for a
    /// missing key and 0 is `.indefinite`, which silently made Indefinite the
    /// first-run default.
    nonisolated static func restoredDuration(from stored: Int?) -> SleepDuration {
        guard let stored, let saved = SleepDuration(rawValue: stored) else { return .fourHours }
        return saved
    }

    /// Arguments for `/usr/bin/caffeinate`.
    ///
    /// `-w <own pid>` makes caffeinate release its assertions and exit as soon as
    /// NoSleep's process disappears for ANY reason (crash, Force Quit, kill,
    /// AppleScript quit, logout), so the child can never be orphaned. `-t` still
    /// applies; whichever of `-t` / `-w` fires first ends the session.
    nonisolated static func caffeinateArguments(for duration: SleepDuration, ownPID: Int32) -> [String] {
        var args = ["-d", "-i", "-w", "\(ownPID)"]
        if duration != .indefinite {
            args += ["-t", "\(duration.rawValue)"]
        }
        return args
    }

    /// Whole seconds left until `deadline`, clamped at 0 and rounded up so the
    /// display never reads 0 while caffeinate is still running.
    nonisolated static func remainingSeconds(deadline: TimeInterval, now: TimeInterval) -> Int {
        max(0, Int((deadline - now).rounded(.up)))
    }

    /// "7h 59m", "12m 5s", "9s".
    nonisolated static func format(seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 {
            return "\(h)h \(m)m"
        }
        let s = seconds % 60
        if m > 0 {
            return "\(m)m \(s)s"
        }
        return "\(s)s"
    }

    // MARK: State

    @ObservationIgnored private let launcher: any CaffeinateLaunching
    @ObservationIgnored private let defaults: any DurationStore
    let notifications: any NotificationPosting

    @ObservationIgnored private var process: (any CaffeinateHandle)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var stoppedByUser = false
    @ObservationIgnored private var runToken = 0
    @ObservationIgnored private var activeDuration: SleepDuration?
    /// Uptime-clock deadline of the current timed session. Same clock family as
    /// caffeinate's dispatch-time-based `-t`, so both pause during system sleep.
    @ObservationIgnored private var deadlineUptime: TimeInterval = 0
    /// Monotonic clock source; injectable so tests can simulate stalls exactly.
    @ObservationIgnored var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    init(launcher: any CaffeinateLaunching = ProcessCaffeinateLauncher(),
         notifications: any NotificationPosting = NotificationManager(),
         defaults: any DurationStore = UserDefaults.standard) {
        self.launcher = launcher
        self.notifications = notifications
        self.defaults = defaults
        self.selectedDuration = Self.restoredDuration(
            from: defaults.object(forKey: Self.durationKey) as? Int)
        self.notifications.onExtend = { [weak self] in self?.extendOneHour() }
        self.notifications.requestAuthorization()
    }

    var formattedRemaining: String {
        guard isActive else { return "" }
        if activeDuration == .indefinite { return "∞" }
        return Self.format(seconds: remainingSeconds)
    }

    // MARK: Session control

    func start() {
        stop()

        runToken += 1
        let token = runToken
        stoppedByUser = false

        let duration = selectedDuration
        let args = Self.caffeinateArguments(for: duration,
                                            ownPID: ProcessInfo.processInfo.processIdentifier)
        activeDuration = duration

        let handle: any CaffeinateHandle
        do {
            handle = try launcher.launch(arguments: args) { [weak self] clean in
                self?.handleTermination(token: token, clean: clean)
            }
        } catch {
            // stop() above already reset isActive/remainingSeconds, so no partial
            // state survives a failed launch; just leave a trace for diagnosis.
            Self.log.error("failed to launch caffeinate: \(error.localizedDescription, privacy: .public)")
            activeDuration = nil
            return
        }

        process = handle
        isActive = true

        if duration != .indefinite {
            remainingSeconds = duration.rawValue
            deadlineUptime = uptime() + Double(duration.rawValue)
            // .common so the countdown keeps ticking while the NSMenu is open
            // (menu tracking runs the main run loop in NSEventTrackingRunLoopMode,
            // where .default-mode timers never fire).
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            remainingSeconds = 0
        }
    }

    func stop() {
        stoppedByUser = true
        // Any earlier "session ended" notification is now moot; drop it so its
        // "Extend 1 hour" action can't later replace a newer session. Covers
        // restart (start() calls stop() first), user Stop, and cleanup() on Quit.
        notifications.clearDelivered()
        timer?.invalidate()
        timer = nil
        deadlineUptime = 0
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        isActive = false
        remainingSeconds = 0
    }

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func changeDuration(_ duration: SleepDuration) {
        selectedDuration = duration
        start()
    }

    func extendOneHour() {
        // Honour the action only for the session it announced: if a newer
        // session is already running, a stale notification must not replace it.
        guard !isActive else { return }
        selectedDuration = .oneHour
        start()
    }

    func cleanup() {
        stop()
    }

    // MARK: Internals

    func tick() {
        guard isActive, timer != nil else { return }
        remainingSeconds = Self.remainingSeconds(deadline: deadlineUptime, now: uptime())
        if remainingSeconds <= 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    private func handleTermination(token: Int, clean: Bool) {
        // Ignore stale terminations from a session that was already replaced.
        guard token == runToken else { return }

        let completed = activeDuration
        let notifiable = Self.shouldNotifyOnCompletion(
            terminatedToken: token,
            currentToken: runToken,
            stoppedByUser: stoppedByUser,
            terminationWasClean: clean,
            duration: completed
        )

        timer?.invalidate()
        timer = nil
        deadlineUptime = 0
        process = nil
        isActive = false
        remainingSeconds = 0
        stoppedByUser = false
        activeDuration = nil

        if notifiable, let completed {
            notifications.postCompletion(duration: completed)
        }
    }
}
