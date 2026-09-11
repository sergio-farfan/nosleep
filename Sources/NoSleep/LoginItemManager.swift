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

// MARK: - Service seam

/// The Background Task Management operations `LoginItemManager` performs.
/// Abstracted so the toggle and migration decision trees — the code that
/// deletes ~/Library/LaunchAgents/com.nosleep.app.plist and (un)registers the
/// login item — run under `swift test` against a scripted fake. A real
/// `SMAppService` would register login items on the developer's machine.
@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func legacyStatus(at url: URL) -> SMAppService.Status
    func openSystemSettingsLoginItems()
}

/// Production service: `SMAppService.mainApp` plus the class-level helpers.
struct SMAppServiceAdapter: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func legacyStatus(at url: URL) -> SMAppService.Status { SMAppService.statusForLegacyPlist(at: url) }
    func openSystemSettingsLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

// MARK: - Manager

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
    nonisolated static let defaultLegacyPlistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.nosleep.app.plist")

    nonisolated static let moveToApplicationsHint = "Move NoSleep to Applications, then quit and reopen it"
    nonisolated static let approvalHint = "Allow NoSleep in System Settings › Login Items"

    /// Authoritative state from Background Task Management — what System
    /// Settings shows. Refreshed at launch, every time the menu opens, and
    /// after each toggle, so a change made in System Settings shows up without
    /// relaunching.
    private(set) var status: SMAppService.Status = .notRegistered

    /// True while the ≤ 1.1.0 LaunchAgent is still on disk, points at a binary
    /// that exists, and launchd will run it at login (migration could not hand
    /// it to SMAppService yet). Folded into `isEnabled` so the toggle shows the
    /// real autostart state and can turn it off.
    private(set) var legacyJobEnabled = false

    /// Why the last toggle() had no effect; cleared when the observed state
    /// changes (e.g. the user fixed things in System Settings).
    private(set) var lastError: String?

    /// False from a mounted DMG, a Gatekeeper-translocated copy or a bare
    /// binary — none of those exist at next login. Fixed for the process lifetime.
    let canRegister: Bool

    /// True only when something will actually launch NoSleep at login.
    /// `.requiresApproval` means the item is registered but needs the user's
    /// consent in System Settings; that shows as unchecked plus a hint unless
    /// the legacy job still covers autostart in the meantime.
    var isEnabled: Bool { status == .enabled || legacyJobEnabled }
    var requiresApproval: Bool { status == .requiresApproval }

    /// One-line caption shown under the toggle when it cannot simply be flipped.
    var hint: String? {
        if !canRegister && !isEnabled { return Self.moveToApplicationsHint }
        // Either the user switched the item off, or register() succeeded but
        // Background Task Management still wants consent (the legacy job keeps
        // Start at Login working meanwhile). Both need the same click.
        if requiresApproval { return Self.approvalHint }
        return lastError
    }

    @ObservationIgnored private let service: any LoginItemService
    @ObservationIgnored private let legacyPlistURL: URL
    @ObservationIgnored private let bundleURL: URL
    @ObservationIgnored private let executableURL: URL?
    @ObservationIgnored private let homeDirectory: URL
    @ObservationIgnored private var menuObserver: NSObjectProtocol?

    init(service: any LoginItemService = SMAppServiceAdapter(),
         legacyPlistURL: URL = LoginItemManager.defaultLegacyPlistURL,
         bundleURL: URL = Bundle.main.bundleURL,
         executableURL: URL? = Bundle.main.executableURL,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         isReadOnlyVolume: (URL) -> Bool? = { try? $0.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly }) {
        self.service = service
        self.legacyPlistURL = legacyPlistURL
        self.bundleURL = bundleURL
        self.executableURL = executableURL
        self.homeDirectory = homeDirectory
        self.canRegister = Self.isInstallableLocation(bundleURL, isReadOnlyVolume: isReadOnlyVolume)

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
        let before = (status, legacyJobEnabled)
        status = service.status
        legacyJobEnabled = legacyJobIsLive()
        if before != (status, legacyJobEnabled) {
            // The world moved on (System Settings, another launch); a caption
            // about an earlier failed click would now contradict the checkbox.
            lastError = nil
        }
    }

    func openSystemSettings() {
        service.openSystemSettingsLoginItems()
    }

    func toggle() {
        lastError = nil
        refresh()
        if requiresApproval && !legacyJobEnabled {
            // Registered, but Background Task Management wants the user's
            // consent (or they turned NoSleep off there). register() cannot
            // override that and unregister() would silently drop the item;
            // only the user can flip the switch, so take them there.
            openSystemSettings()
            return
        }
        var failure: String?
        do {
            if isEnabled {
                // An explicit "off" is authoritative over both mechanisms, and
                // also cleans up a stale plist whose binary no longer exists.
                if FileManager.default.fileExists(atPath: legacyPlistURL.path) {
                    try FileManager.default.removeItem(at: legacyPlistURL)
                }
                if status == .enabled || status == .requiresApproval {
                    try service.unregister()
                }
            } else {
                guard canRegister else {
                    Self.log.error("refusing to register login item from \(self.bundleURL.path, privacy: .public); move NoSleep to Applications first")
                    lastError = Self.moveToApplicationsHint
                    return
                }
                try service.register()
            }
        } catch {
            Self.log.error("login item \(self.isEnabled ? "disable" : "enable", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            failure = error.localizedDescription
        }
        refresh()
        if let failure { lastError = failure }
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

    /// What `migrateLegacyPlistIfNeeded()` does once both BTM states are known.
    enum LegacyMigrationStep: Equatable {
        /// The legacy agent was switched off in Login Items; "off" carries over.
        case dropPlistUserDisabledIt
        /// The main-app item is registered but awaits consent; the legacy job is
        /// the only thing still launching the app, so it must survive.
        case keepPlistAwaitingApproval
        /// Nothing registered yet.
        case register
        /// The main-app item is already enabled.
        case dropPlistMigrated
    }

    /// `.requiresApproval` on the main-app item is *not* evidence about the
    /// legacy job: SMAppService.h documents it both for "registered, user must
    /// act in System Settings" and for a revoked consent. Only the legacy
    /// plist's own status can say the user turned that job off.
    nonisolated static func legacyMigrationStep(legacyStatus: SMAppService.Status,
                                                mainAppStatus: SMAppService.Status) -> LegacyMigrationStep {
        if legacyStatus == .requiresApproval { return .dropPlistUserDisabledIt }
        if mainAppStatus == .enabled { return .dropPlistMigrated }
        if mainAppStatus == .requiresApproval { return .keepPlistAwaitingApproval }
        return .register
    }

    /// `ProgramArguments[0]` of a legacy LaunchAgent plist, if readable.
    nonisolated static func legacyProgramPath(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else { return nil }
        return args.first
    }

    // MARK: - Legacy LaunchAgent

    /// `statusForLegacyPlist(at:)` reflects Background Task Management's
    /// disposition for the file, not whether launchd can actually run it; the
    /// ≤ 1.1.0 plist bakes in an absolute path, so also require that binary to
    /// exist before claiming the job will launch anything.
    private func legacyJobIsLive() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyPlistURL.path) else { return false }
        guard let program = Self.legacyProgramPath(at: legacyPlistURL), fm.fileExists(atPath: program) else {
            return false
        }
        return service.legacyStatus(at: legacyPlistURL) == .enabled
    }

    /// A legacy plist means the user had "Start at Login" on in ≤ 1.1.0 — unless
    /// they later switched the agent off under System Settings › Login Items,
    /// which leaves the file on disk but makes Background Task Management report
    /// it as `.requiresApproval`. Carry that choice over: "on" becomes an
    /// SMAppService registration, "off" stays unregistered. The plist is deleted
    /// only once the carried-over state is in effect, so the preference is never
    /// lost: if registration cannot happen here, or the new item still awaits
    /// the user's approval, the plist stays and a later launch retries.
    ///
    /// Deliberately no `launchctl bootout`: if this very process was started by
    /// that job, booting it out would terminate NoSleep. The loaded job is
    /// harmless for the rest of this login session (KeepAlive was false) and
    /// cannot load again without its plist.
    private func migrateLegacyPlistIfNeeded() {
        let url = legacyPlistURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard canRegister else { return }
        guard Self.mayMigrateLegacyPlist(bundleURL: bundleURL,
                                         executableURL: executableURL,
                                         legacyProgramPath: Self.legacyProgramPath(at: url),
                                         homeDirectory: homeDirectory) else {
            Self.log.info("legacy LaunchAgent kept: this copy (\(self.bundleURL.path, privacy: .public)) is not the installed one")
            return
        }
        do {
            switch Self.legacyMigrationStep(legacyStatus: service.legacyStatus(at: url),
                                            mainAppStatus: service.status) {
            case .dropPlistUserDisabledIt:
                try FileManager.default.removeItem(at: url)
                Self.log.info("removed legacy LaunchAgent the user had disabled; Start at Login stays off")
                return
            case .keepPlistAwaitingApproval:
                // Do not call register() again: it would throw
                // kSMErrorAlreadyRegistered / kSMErrorLaunchDeniedByUser. The
                // menu shows the approval hint; toggle() opens System Settings.
                Self.log.info("legacy LaunchAgent kept: SMAppService item awaits approval in Login Items")
                return
            case .register:
                try service.register()
                guard service.status == .enabled else {
                    Self.log.info("legacy LaunchAgent kept: SMAppService status is \(String(describing: self.service.status), privacy: .public)")
                    return
                }
            case .dropPlistMigrated:
                break
            }
            try FileManager.default.removeItem(at: url)
            Self.log.info("migrated legacy LaunchAgent plist to SMAppService")
        } catch {
            Self.log.error("legacy LaunchAgent migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
