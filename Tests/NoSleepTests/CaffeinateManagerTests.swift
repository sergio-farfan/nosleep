// CaffeinateManagerTests.swift
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

import XCTest
@testable import NoSleep

// MARK: - Test doubles

@MainActor
final class FakeHandle: CaffeinateHandle {
    private(set) var isRunning = true
    private(set) var terminateCount = 0
    func terminate() {
        terminateCount += 1
        isRunning = false
    }
}

@MainActor
final class FakeLauncher: CaffeinateLaunching {
    struct Launch {
        let arguments: [String]
        let handle: FakeHandle
        let onTermination: @MainActor (Bool) -> Void
    }
    private(set) var launches: [Launch] = []
    var failNextLaunch = false

    var last: Launch? { launches.last }

    func launch(arguments: [String],
                onTermination: @escaping @MainActor (Bool) -> Void) throws -> any CaffeinateHandle {
        if failNextLaunch {
            failNextLaunch = false
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }
        let handle = FakeHandle()
        launches.append(Launch(arguments: arguments, handle: handle, onTermination: onTermination))
        return handle
    }
}

@MainActor
final class SpyNotifications: NotificationPosting {
    var onExtend: (() -> Void)?
    private(set) var requestCount = 0
    private(set) var posted: [SleepDuration] = []
    private(set) var clearCount = 0

    func requestAuthorization() { requestCount += 1 }
    func postCompletion(duration: SleepDuration) { posted.append(duration) }
    func clearDelivered() { clearCount += 1 }
}

/// Never touches cfprefsd: a `UserDefaults` suite, even a throwaway one, is
/// written to ~/Library/Preferences/<suite>.plist and never unlinked.
@MainActor
final class InMemoryStore: DurationStore {
    var values: [String: Any] = [:]
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

// MARK: - Pure decisions

final class CaffeinateManagerPureTests: XCTestCase {

    // shouldNotifyOnCompletion

    func testNotifiesOnNaturalTimedExpiry() {
        XCTAssertTrue(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: false,
            terminationWasClean: true, duration: .twoHours))
    }

    func testNoNotifyWhenStoppedByUser() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: true,
            terminationWasClean: true, duration: .twoHours))
    }

    func testNoNotifyOnStaleTokenFromRestart() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 2, stoppedByUser: false,
            terminationWasClean: true, duration: .twoHours))
    }

    func testNoNotifyWhenKilledBySignal() {
        // e.g. `killall caffeinate` — the session did not complete.
        XCTAssertFalse(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: false,
            terminationWasClean: false, duration: .twoHours))
    }

    func testNoNotifyForIndefinite() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: false,
            terminationWasClean: true, duration: .indefinite))
    }

    func testNoNotifyForNilDuration() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: false,
            terminationWasClean: true, duration: nil))
    }

    // restoredDuration — first-launch default

    func testFreshInstallDefaultsToFourHours() {
        XCTAssertEqual(CaffeinateManager.restoredDuration(from: nil), .fourHours)
    }

    func testStoredZeroIsIndefiniteNotTheDefault() {
        // 0 is a legitimate stored value (Indefinite) and must round-trip.
        XCTAssertEqual(CaffeinateManager.restoredDuration(from: 0), .indefinite)
    }

    func testStoredPresetsRoundTrip() {
        for d in SleepDuration.allCases {
            XCTAssertEqual(CaffeinateManager.restoredDuration(from: d.rawValue), d)
        }
    }

    func testCorruptStoredValueFallsBackToFourHours() {
        XCTAssertEqual(CaffeinateManager.restoredDuration(from: 12345), .fourHours)
    }

    // caffeinateArguments

    func testArgumentsAlwaysTieChildToOwnPID() {
        for d in SleepDuration.allCases {
            let args = CaffeinateManager.caffeinateArguments(for: d, ownPID: 4242)
            XCTAssertEqual(Array(args.prefix(4)), ["-d", "-i", "-w", "4242"], "\(d)")
        }
    }

    func testTimedArgumentsIncludeTimeout() {
        let args = CaffeinateManager.caffeinateArguments(for: .fifteenMin, ownPID: 1)
        XCTAssertEqual(args, ["-d", "-i", "-w", "1", "-t", "900"])
    }

    func testIndefiniteArgumentsOmitTimeout() {
        let args = CaffeinateManager.caffeinateArguments(for: .indefinite, ownPID: 1)
        XCTAssertFalse(args.contains("-t"))
    }

    // remainingSeconds(deadline:now:)

    func testRemainingSecondsRoundsUpAndClamps() {
        XCTAssertEqual(CaffeinateManager.remainingSeconds(deadline: 100, now: 90), 10)
        XCTAssertEqual(CaffeinateManager.remainingSeconds(deadline: 100, now: 99.2), 1)
        XCTAssertEqual(CaffeinateManager.remainingSeconds(deadline: 100, now: 100), 0)
        XCTAssertEqual(CaffeinateManager.remainingSeconds(deadline: 100, now: 130), 0)
    }

    // format(seconds:)

    func testFormatBranches() {
        XCTAssertEqual(CaffeinateManager.format(seconds: 0), "0s")
        XCTAssertEqual(CaffeinateManager.format(seconds: 45), "45s")
        XCTAssertEqual(CaffeinateManager.format(seconds: 60), "1m 0s")
        XCTAssertEqual(CaffeinateManager.format(seconds: 90), "1m 30s")
        XCTAssertEqual(CaffeinateManager.format(seconds: 3600), "1h 0m")
        XCTAssertEqual(CaffeinateManager.format(seconds: 3661), "1h 1m")
        XCTAssertEqual(CaffeinateManager.format(seconds: 28799), "7h 59m")
    }
}

// MARK: - State machine (no real caffeinate spawned, no cfprefsd traffic)

@MainActor
final class CaffeinateManagerStateTests: XCTestCase {
    private var store: InMemoryStore!
    private var launcher: FakeLauncher!
    private var spy: SpyNotifications!

    // Async overrides may take the class's @MainActor isolation; the synchronous
    // XCTestCase.setUp/tearDown are nonisolated and would warn on every access.
    override func setUp() async throws {
        try await super.setUp()
        store = InMemoryStore()
        launcher = FakeLauncher()
        spy = SpyNotifications()
    }

    private func makeManager() -> CaffeinateManager {
        CaffeinateManager(launcher: launcher, notifications: spy, defaults: store)
    }

    func testInitWiresExtendActionAndRequestsAuthorizationOnce() {
        let m = makeManager()
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(spy.requestCount, 1)
        XCTAssertNotNil(spy.onExtend, "Extend action must be wired to the manager")
    }

    /// The real NotificationManager must be inert outside an .app bundle. The
    /// xctest host is exactly such an environment (no .app extension), which is
    /// where `UNUserNotificationCenter.current()` trapped before. Nothing here
    /// calls start(), so no caffeinate child is spawned.
    func testRealNotificationManagerIsNoOpOutsideAppBundle() {
        guard !NotificationManager.isSupported else {
            XCTFail("expected a non-.app test host, got \(Bundle.main.bundleURL.path)")
            return
        }
        let real = NotificationManager()
        real.requestAuthorization()          // would trap without the guard
        real.postCompletion(duration: .oneHour)
        real.clearDelivered()
        // And the production default init path (real NotificationManager) is safe.
        let m = CaffeinateManager(launcher: launcher, defaults: store)
        XCTAssertFalse(m.isActive)
    }

    func testFreshStoreSelectsFourHours() {
        XCTAssertEqual(makeManager().selectedDuration, .fourHours)
    }

    func testSelectedDurationPersistsAndRestores() {
        let m = makeManager()
        m.selectedDuration = .indefinite
        XCTAssertEqual(store.values[CaffeinateManager.durationKey] as? Int, 0)
        XCTAssertEqual(makeManager().selectedDuration, .indefinite)
    }

    func testStartLaunchesTimedSessionWithExpectedArguments() {
        let m = makeManager()
        m.selectedDuration = .fifteenMin
        m.start()
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.remainingSeconds, 900)
        XCTAssertEqual(m.formattedRemaining, "15m 0s")
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(launcher.last?.arguments, ["-d", "-i", "-w", "\(pid)", "-t", "900"])
    }

    func testStartIndefiniteShowsInfinity() {
        let m = makeManager()
        m.selectedDuration = .indefinite
        m.start()
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.formattedRemaining, "∞")
        XCTAssertFalse(launcher.last!.arguments.contains("-t"))
    }

    func testStopTerminatesChildAndClearsStaleNotifications() {
        let m = makeManager()
        m.start()
        let handle = launcher.last!.handle
        let clearsBefore = spy.clearCount
        m.stop()
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(m.remainingSeconds, 0)
        XCTAssertEqual(m.formattedRemaining, "")
        XCTAssertEqual(handle.terminateCount, 1)
        XCTAssertEqual(spy.clearCount, clearsBefore + 1)
    }

    func testUserStopDoesNotNotifyWhenChildExits() {
        let m = makeManager()
        m.start()
        let launch = launcher.last!
        m.stop()
        // The SIGTERM'd child reports back asynchronously.
        launch.onTermination(false)
        XCTAssertTrue(spy.posted.isEmpty)
        XCTAssertFalse(m.isActive)
    }

    func testNaturalExpiryNotifiesWithTheCompletedDuration() {
        let m = makeManager()
        m.selectedDuration = .twoHours
        m.start()
        launcher.last!.onTermination(true)
        XCTAssertEqual(spy.posted, [.twoHours])
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(m.remainingSeconds, 0)
    }

    func testExternalKillDoesNotNotify() {
        let m = makeManager()
        m.selectedDuration = .twoHours
        m.start()
        launcher.last!.onTermination(false)   // killall caffeinate
        XCTAssertTrue(spy.posted.isEmpty)
        XCTAssertFalse(m.isActive)
    }

    func testIndefiniteExpiryNeverNotifies() {
        let m = makeManager()
        m.selectedDuration = .indefinite
        m.start()
        launcher.last!.onTermination(true)
        XCTAssertTrue(spy.posted.isEmpty)
    }

    func testRestartIgnoresStaleTerminationOfReplacedSession() {
        let m = makeManager()
        m.selectedDuration = .oneHour
        m.start()
        let first = launcher.last!
        let clearsBefore = spy.clearCount
        m.changeDuration(.twoHours)
        XCTAssertEqual(launcher.launches.count, 2)
        XCTAssertEqual(first.handle.terminateCount, 1, "old child must be terminated on restart")
        XCTAssertEqual(spy.clearCount, clearsBefore + 1, "restart must drop any stale Extend banner")
        XCTAssertTrue(m.isActive)

        // Old child's handler arrives late, claiming a clean exit: must be ignored.
        first.onTermination(true)
        XCTAssertTrue(m.isActive, "stale termination must not tear down the new session")
        XCTAssertTrue(spy.posted.isEmpty, "stale termination must not notify")

        // The new session then expires naturally.
        launcher.last!.onTermination(true)
        XCTAssertEqual(spy.posted, [.twoHours])
        XCTAssertFalse(m.isActive)
    }

    func testStaleExtendIsIgnoredWhileASessionIsRunning() {
        let m = makeManager()
        m.selectedDuration = .eightHours
        m.start()
        spy.onExtend?()           // user taps an old "Extend 1 hour" banner
        XCTAssertEqual(launcher.launches.count, 1, "must not restart")
        XCTAssertEqual(m.selectedDuration, .eightHours)
        XCTAssertTrue(m.isActive)
    }

    func testExtendAfterExpiryStartsAFreshHour() {
        let m = makeManager()
        m.selectedDuration = .fifteenMin
        m.start()
        launcher.last!.onTermination(true)
        XCTAssertFalse(m.isActive)
        spy.onExtend?()
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.selectedDuration, .oneHour)
        XCTAssertEqual(launcher.last?.arguments.suffix(2), ["-t", "3600"])
    }

    func testFailedLaunchLeavesNoPartialState() {
        let m = makeManager()
        m.selectedDuration = .oneHour
        launcher.failNextLaunch = true
        m.start()
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(m.remainingSeconds, 0)
        XCTAssertEqual(m.formattedRemaining, "")
        XCTAssertTrue(launcher.launches.isEmpty)
        // A later start must work normally.
        m.start()
        XCTAssertTrue(m.isActive)
    }

    func testToggleStartsAndStops() {
        let m = makeManager()
        m.toggle()
        XCTAssertTrue(m.isActive)
        m.toggle()
        XCTAssertFalse(m.isActive)
    }

    /// The countdown is derived from a deadline, not decremented per fire, so
    /// coalesced or missed timer fires (menu open, main-thread stall, system
    /// sleep) resynchronise instead of accumulating drift.
    func testTickResyncsFromDeadlineAfterMissedFires() {
        let m = makeManager()
        var now: TimeInterval = 1_000
        m.uptime = { now }
        m.selectedDuration = .fifteenMin
        m.start()

        now += 0.4; m.tick(); m.tick()
        XCTAssertEqual(m.remainingSeconds, 900, "two ticks inside one second must not double-decrement")

        now += 65; m.tick()
        XCTAssertEqual(m.remainingSeconds, 835, "one tick after a 65 s stall must resync, not decrement by 1")

        now += 900; m.tick()
        XCTAssertEqual(m.remainingSeconds, 0)
        XCTAssertEqual(m.formattedRemaining, "0s")
        XCTAssertTrue(m.isActive, "stays active until caffeinate itself exits")
        m.tick()   // no-op once the timer is gone
        XCTAssertEqual(m.remainingSeconds, 0)
        m.stop()
    }

    /// Stand-in for NSEventTrackingRunLoopMode (menu open), which NSApplication
    /// registers as a common mode in the real app. A `.default`-mode timer does
    /// not fire here; a `.common` one does. Guards `start()`'s
    /// `RunLoop.main.add(t, forMode: .common)` against a revert to
    /// `Timer.scheduledTimer` / `.default`, which every other test tolerates.
    func testCountdownTicksWhileRunLoopIsInAnotherCommonMode() {
        let mode = RunLoop.Mode("NoSleepTests.menuTracking")
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: mode.rawValue as CFString))

        let m = makeManager()
        m.selectedDuration = .fifteenMin
        m.start()
        defer { m.stop() }   // never leave a repeating timer on RunLoop.main

        let giveUp = Date(timeIntervalSinceNow: 3)
        while Date() < giveUp, m.remainingSeconds == 900 {
            _ = RunLoop.main.run(mode: mode, before: Date(timeIntervalSinceNow: 0.1))
        }
        XCTAssertLessThan(m.remainingSeconds, 900, "countdown froze while the run loop was in a tracking-style mode")
    }
}
