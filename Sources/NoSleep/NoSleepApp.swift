// NoSleepApp.swift
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

import os
import SwiftUI

@main
struct NoSleepApp: App {
    nonisolated private static let log = Logger(subsystem: "com.nosleep.app", category: "app")

    /// Held (never closed) for the process lifetime. The kernel drops the lock
    /// on exit or crash, so there is no stale-lock case to handle.
    nonisolated static let instanceLockURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NoSleep/instance.lock")

    @State private var caffeinateManager: CaffeinateManager
    @State private var loginManager: LoginItemManager

    init() {
        // Single instance. launchd (the ≤ 1.1.0 LaunchAgent), Background Task
        // Management and `open` can each start a copy within milliseconds of one
        // another, and each copy would run its own caffeinate behind its own
        // icon. NSRunningApplication cannot arbitrate that window: a directly
        // exec'd process is not registered with LaunchServices until
        // NSApplication initialises (~50 ms after this init), and two
        // LS-launched copies can each see the other and both exit. Let the
        // kernel decide instead. Only a real .app bundle takes part: `swift run`,
        // the bare .build binary and the xctest host (whose bundle id is
        // com.apple.dt.xctest.tool) are left alone.
        if Bundle.main.bundleURL.pathExtension == "app" {
            switch Self.acquireInstanceLock(at: Self.instanceLockURL) {
            case .acquired:
                // The lock only arbitrates between copies that take it. A build
                // ≤ 1.2.0 that is still running would keep its icon and its
                // caffeinate next to ours: a DMG upgrade replaces the bundle on
                // disk (or adds one in /Applications beside ~/Applications)
                // without quitting the old copy; only install.sh quits first.
                Self.terminateLockUnawareInstances()
            case .heldByOtherInstance(let holder):
                // .notice so the "did nothing and quit" path is persisted in the
                // unified log; .info is memory-only by default.
                Self.log.notice("another NoSleep instance (pid \(holder.map(String.init) ?? "?", privacy: .public)) holds the instance lock; exiting")
                exit(0)
            case .unavailable(let code):
                Self.log.error("instance lock unavailable (errno \(code, privacy: .public)); continuing without the single-instance guard")
            }
        }
        _caffeinateManager = State(initialValue: CaffeinateManager())
        _loginManager = State(initialValue: LoginItemManager())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(manager: caffeinateManager, loginManager: loginManager)
        } label: {
            Image(systemName: caffeinateManager.isActive
                  ? "cup.and.saucer.fill"
                  : "cup.and.saucer")
                .accessibilityLabel(caffeinateManager.isActive
                                    ? "NoSleep, keeping your Mac awake"
                                    : "NoSleep, inactive")
                // Fires when MenuBarExtra creates the status item at launch
                // (including a launchd/login-item exec); the manager makes it a
                // one-shot, so any re-appearance is harmless.
                .onAppear { caffeinateManager.startOnLaunchIfNeeded() }
        }
    }

    // MARK: - Pre-lock instances

    /// Quits every other running process with our bundle identifier, and the
    /// `caffeinate` children it spawned. We hold the lock, so any such process
    /// is a build that predates it. ≤ 1.1.0 did not pass `-w`, so its caffeinate
    /// would outlive it as an orphan; reap the children first, while they are
    /// still attached. `terminate()` is an asynchronous quit Apple Event; a
    /// false return means the process is already gone.
    private static func terminateLockUnawareInstances() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id)
        where app.processIdentifier != me {
            Self.log.notice("quitting pre-lock NoSleep instance pid \(app.processIdentifier, privacy: .public)")
            let reap = Process()
            reap.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            reap.arguments = ["-P", "\(app.processIdentifier)", "-x", "caffeinate"]
            if (try? reap.run()) != nil { reap.waitUntilExit() }
            app.terminate()
        }
    }

    // MARK: - Instance lock (unit-tested)

    enum InstanceLock: Equatable {
        /// This process now owns the lock; `fd` stays open until exit.
        case acquired(fd: Int32)
        /// Another process owns it (its pid, if it got as far as writing it).
        case heldByOtherInstance(pid: Int32?)
        /// The lock file could not be created or opened.
        case unavailable(errno: Int32)
    }

    /// Opens `url` with an exclusive, non-blocking BSD lock (`O_EXLOCK`) and
    /// records the owner's pid in it. flock-style locks belong to the open file
    /// description, so a second open in the same process also reports
    /// `.heldByOtherInstance`, which is what the unit test relies on.
    /// `O_CLOEXEC` keeps the descriptor out of the caffeinate child.
    nonisolated static func acquireInstanceLock(at url: URL) -> InstanceLock {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, 0o600)
        if fd >= 0 {
            _ = ftruncate(fd, 0)
            let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
            _ = pid.withCString { Darwin.write(fd, $0, strlen($0)) }
            return .acquired(fd: fd)
        }
        let code = errno
        guard code == EWOULDBLOCK else { return .unavailable(errno: code) }
        let holder = (try? String(contentsOf: url, encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return .heldByOtherInstance(pid: holder)
    }
}
