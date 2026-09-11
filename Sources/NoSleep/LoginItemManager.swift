// LoginItemManager.swift
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

import AppKit
import Foundation
import Observation
import os
import ServiceManagement

/// "Start at Login" backed by `SMAppService.mainApp` (macOS 13+).
///
/// Background Task Management tracks the app by bundle identity, so the login
/// item keeps working when NoSleep.app is moved, and it appears under
/// System Settings › General › Login Items with the app's name and icon. The
/// previous implementation wrote a LaunchAgent plist with the executable path
/// baked in at enable time, which broke silently whenever the bundle moved and
/// reported "enabled" purely from the plist's existence.
@MainActor
@Observable
final class LoginItemManager {
    nonisolated private static let log = Logger(subsystem: "com.nosleep.app", category: "login-item")

    /// Plist written by NoSleep ≤ 1.1.0.
    nonisolated static let legacyPlistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.nosleep.app.plist")

    /// Authoritative state from Background Task Management — what System
    /// Settings shows. Refreshed at launch, every time the menu opens, and
    /// after each toggle, so a change made in System Settings shows up without
    /// relaunching.
    private(set) var status: SMAppService.Status = .notRegistered

    /// True while the ≤ 1.1.0 LaunchAgent is still on disk and launchd will run
    /// it at login (migration could not hand it to SMAppService yet). Folded into
    /// `isEnabled` so the toggle shows the real autostart state and can turn it off.
    private(set) var legacyJobEnabled = false

    /// Why the last toggle() had no effect; nil once one succeeds.
    private(set) var lastError: String?

    /// False from a mounted DMG, a Gatekeeper-translocated copy or a bare
    /// binary — none of those exist at next login. Fixed for the process lifetime.
    let canRegister = LoginItemManager.isInstallableLocation(Bundle.main.bundleURL)

    /// True only when something will actually launch NoSleep at login.
    /// `.requiresApproval` means the item is registered but the user switched it
    /// off under System Settings › Login Items; that shows as unchecked plus a hint.
    var isEnabled: Bool { status == .enabled || legacyJobEnabled }
    var requiresApproval: Bool { status == .requiresApproval }

    /// One-line caption shown under the toggle when it cannot simply be flipped.
    var hint: String? {
        if !canRegister && !isEnabled { return "Move NoSleep to Applications to enable" }
        if requiresApproval && !legacyJobEnabled { return "Allow NoSleep in System Settings › Login Items" }
        return lastError
    }

    @ObservationIgnored private let service = SMAppService.mainApp
    @ObservationIgnored private var menuObserver: NSObjectProtocol?

    init() {
        migrateLegacyPlistIfNeeded()
        refresh()
        // The .menu-style MenuBarExtra is an NSMenu: re-read BTM state each time
        // it opens. `queue: nil` delivers synchronously on the posting thread;
        // AppKit posts this notification on the main thread, so assumeIsolated
        // is safe and avoids a needless executor hop.
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        status = service.status
        legacyJobEnabled = FileManager.default.fileExists(atPath: Self.legacyPlistURL.path)
            && SMAppService.statusForLegacyPlist(at: Self.legacyPlistURL) == .enabled
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func toggle() {
        lastError = nil
        refresh()
        if requiresApproval && !legacyJobEnabled {
            // Registered, but the user turned NoSleep off in System Settings.
            // register() cannot override that and unregister() would silently
            // drop the item; only the user can flip the switch, so take them there.
            openSystemSettings()
            return
        }
        do {
            if isEnabled {
                // An explicit "off" is authoritative over both mechanisms.
                if legacyJobEnabled {
                    try FileManager.default.removeItem(at: Self.legacyPlistURL)
                }
                if status == .enabled || status == .requiresApproval {
                    try service.unregister()
                }
            } else {
                guard canRegister else {
                    Self.log.error("refusing to register login item from \(Bundle.main.bundleURL.path, privacy: .public); move NoSleep to Applications first")
                    lastError = "Move NoSleep to Applications to enable"
                    return
                }
                try service.register()
            }
        } catch {
            Self.log.error("login item \(self.isEnabled ? "disable" : "enable", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        refresh()
        if requiresApproval {
            // register() succeeded but Background Task Management wants the
            // user's consent; send them to the switch.
            openSystemSettings()
        }
    }

    // MARK: - Pure decisions (unit-tested)

    /// Whether a bundle at `url` is somewhere a login item may point: an .app
    /// on a writable volume that is not a Gatekeeper translocation. DMGs mount
    /// read-only and App Translocation is a read-only nullfs mount, so a
    /// volume-attribute check is both narrower and more robust than matching
    /// `/Volumes/` (which would also reject an app installed on a second disk).
    nonisolated static func isInstallableLocation(
        _ url: URL,
        isReadOnlyVolume: (URL) -> Bool? = { try? $0.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly }
    ) -> Bool {
        guard url.pathExtension == "app" else { return false }
        if url.path.contains("/AppTranslocation/") { return false }
        if isReadOnlyVolume(url) == true { return false }
        return true
    }

    /// `register()` binds the login item to *this* bundle's URL, so only a copy
    /// the user would want launched at login may migrate the legacy plist: one
    /// inside /Applications or ~/Applications, or the exact bundle the
    /// LaunchAgent already launches. A build-directory copy
    /// (`./build.sh && open NoSleep.app`) must leave the plist alone.
    nonisolated static func mayMigrateLegacyPlist(bundleURL: URL,
                                                  executableURL: URL?,
                                                  legacyProgramPath: String?,
                                                  homeDirectory: URL) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        if path.hasPrefix("/Applications/") { return true }
        if path.hasPrefix(homeDirectory.standardizedFileURL.path + "/Applications/") { return true }
        if let exe = executableURL?.standardizedFileURL.path,
           let legacy = legacyProgramPath,
           URL(fileURLWithPath: legacy).standardizedFileURL.path == exe {
            return true
        }
        return false
    }

    /// `ProgramArguments[0]` of a legacy LaunchAgent plist, if readable.
    nonisolated static func legacyProgramPath(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else { return nil }
        return args.first
    }

    // MARK: - Migration

    /// A legacy plist means the user had "Start at Login" on in ≤ 1.1.0 — unless
    /// they later switched the agent off under System Settings › Login Items,
    /// which leaves the file on disk but makes Background Task Management report
    /// it as `.requiresApproval`. Carry that choice over: "on" becomes an
    /// SMAppService registration, "off" stays unregistered. The plist is deleted
    /// only once the carried-over state is in effect, so the preference is never
    /// lost: if registration cannot happen here, the plist stays and the next
    /// launch from an installed copy retries.
    ///
    /// Deliberately no `launchctl bootout`: if this very process was started by
    /// that job, booting it out would terminate NoSleep. The loaded job is
    /// harmless for the rest of this login session (KeepAlive was false) and
    /// cannot load again without its plist.
    private func migrateLegacyPlistIfNeeded() {
        let url = Self.legacyPlistURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard canRegister else { return }
        guard Self.mayMigrateLegacyPlist(bundleURL: Bundle.main.bundleURL,
                                         executableURL: Bundle.main.executableURL,
                                         legacyProgramPath: Self.legacyProgramPath(at: url),
                                         homeDirectory: FileManager.default.homeDirectoryForCurrentUser) else {
            Self.log.info("legacy LaunchAgent kept: this copy (\(Bundle.main.bundleURL.path, privacy: .public)) is not the installed one")
            return
        }
        do {
            let legacyStatus = SMAppService.statusForLegacyPlist(at: url)
            if legacyStatus == .requiresApproval || service.status == .requiresApproval {
                // The user turned NoSleep off in Login Items; "off" carries over.
                try FileManager.default.removeItem(at: url)
                Self.log.info("removed legacy LaunchAgent the user had disabled; Start at Login stays off")
                return
            }
            if service.status != .enabled {
                try service.register()
            }
            guard service.status == .enabled else {
                Self.log.info("legacy LaunchAgent kept: SMAppService status is \(String(describing: self.service.status), privacy: .public)")
                return
            }
            try FileManager.default.removeItem(at: url)
            Self.log.info("migrated legacy LaunchAgent plist to SMAppService")
        } catch {
            Self.log.error("legacy LaunchAgent migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
