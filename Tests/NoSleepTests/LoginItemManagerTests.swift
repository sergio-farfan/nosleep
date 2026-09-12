// LoginItemManagerTests.swift
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

import ServiceManagement   // only for the SMAppService.Status enum; nothing is registered
import XCTest
@testable import NoSleep

// MARK: - Test double

/// Scripted stand-in for SMAppService so the toggle and migration decision
/// trees run without touching Background Task Management on this machine.
@MainActor
final class FakeLoginItemService: LoginItemService {
    private var storedStatus: SMAppService.Status = .notRegistered
    private(set) var statusReads = 0
    var status: SMAppService.Status {
        get { statusReads += 1; return storedStatus }
        set { storedStatus = newValue }
    }
    var legacyStatuses: [URL: SMAppService.Status] = [:]
    /// What `status` becomes after a successful register() (BTM may want consent).
    var statusAfterRegister: SMAppService.Status = .enabled
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = statusAfterRegister
    }
    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
    func legacyStatus(at url: URL) -> SMAppService.Status { legacyStatuses[url] ?? .notRegistered }
    func openSystemSettingsLoginItems() { openSettingsCount += 1 }
}

// MARK: - Pure predicates

final class LoginItemManagerPredicateTests: XCTestCase {

    // isInstallableLocation

    func testInstallableLocationRequiresAnAppBundle() {
        XCTAssertFalse(LoginItemManager.isInstallableLocation(
            URL(fileURLWithPath: "/Users/me/nosleep/.build/debug/NoSleep")))
    }

    func testInstallableLocationRejectsGatekeeperTranslocation() {
        XCTAssertFalse(LoginItemManager.isInstallableLocation(
            URL(fileURLWithPath: "/private/var/folders/ab/T/AppTranslocation/1234-5678/d/NoSleep.app")))
    }

    func testInstallableLocationAcceptsApplicationsFolders() {
        XCTAssertTrue(LoginItemManager.isInstallableLocation(
            URL(fileURLWithPath: "/Applications/NoSleep.app")))
        XCTAssertTrue(LoginItemManager.isInstallableLocation(
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/NoSleep.app")))
    }

    func testInstallableLocationAcceptsAppsOnOtherWritableVolumes() {
        // A path under /Volumes/ is not by itself disqualifying (external SSD,
        // second APFS volume); only read-only media (DMG, translocation) are.
        XCTAssertTrue(LoginItemManager.isInstallableLocation(
            URL(fileURLWithPath: "/Volumes/Data/Applications/NoSleep.app"), isReadOnlyVolume: { _ in false }))
    }

    func testInstallableLocationRejectsReadOnlyVolumes() {
        // A mounted DMG reports volumeIsReadOnly == true (verified against a real
        // NoSleep DMG); inject that answer so the test needs no disk image.
        let onDMG = URL(fileURLWithPath: "/Volumes/NoSleep/NoSleep.app")
        XCTAssertFalse(LoginItemManager.isInstallableLocation(onDMG, isReadOnlyVolume: { _ in true }))
        XCTAssertTrue(LoginItemManager.isInstallableLocation(onDMG, isReadOnlyVolume: { _ in false }))
        // Unknown (path does not exist yet) must not block registration.
        XCTAssertTrue(LoginItemManager.isInstallableLocation(onDMG, isReadOnlyVolume: { _ in nil }))
    }

    // mayMigrateLegacyPlist

    private let home = URL(fileURLWithPath: "/Users/me")
    private let installedProgram = "/Users/me/Applications/NoSleep.app/Contents/MacOS/NoSleep"

    func testInstalledCopiesMayMigrate() {
        XCTAssertTrue(LoginItemManager.mayMigrateLegacyPlist(
            bundleURL: URL(fileURLWithPath: "/Applications/NoSleep.app"),
            executableURL: nil, legacyProgramPath: installedProgram, homeDirectory: home))
        XCTAssertTrue(LoginItemManager.mayMigrateLegacyPlist(
            bundleURL: URL(fileURLWithPath: "/Users/me/Applications/NoSleep.app"),
            executableURL: nil, legacyProgramPath: installedProgram, homeDirectory: home))
    }

    func testBuildDirectoryCopyMustNotMigrate() {
        // `./build.sh && open NoSleep.app` from the checkout would otherwise bind
        // the login item to a bundle that the next build deletes and re-signs.
        XCTAssertFalse(LoginItemManager.mayMigrateLegacyPlist(
            bundleURL: URL(fileURLWithPath: "/Users/me/projects/nosleep/NoSleep.app"),
            executableURL: URL(fileURLWithPath: "/Users/me/projects/nosleep/NoSleep.app/Contents/MacOS/NoSleep"),
            legacyProgramPath: installedProgram, homeDirectory: home))
    }

    func testTheCopyTheLaunchAgentAlreadyLaunchesMayMigrate() {
        let elsewhere = "/Users/me/Tools/NoSleep.app"
        XCTAssertTrue(LoginItemManager.mayMigrateLegacyPlist(
            bundleURL: URL(fileURLWithPath: elsewhere),
            executableURL: URL(fileURLWithPath: elsewhere + "/Contents/MacOS/NoSleep"),
            legacyProgramPath: elsewhere + "/Contents/MacOS/NoSleep", homeDirectory: home))
    }

    func testUnreadableLegacyPlistDoesNotUnlockMigrationForArbitraryCopies() {
        XCTAssertFalse(LoginItemManager.mayMigrateLegacyPlist(
            bundleURL: URL(fileURLWithPath: "/Users/me/Downloads/NoSleep.app"),
            executableURL: URL(fileURLWithPath: "/Users/me/Downloads/NoSleep.app/Contents/MacOS/NoSleep"),
            legacyProgramPath: nil, homeDirectory: home))
    }

    // legacyMigrationStep

    func testMainAppAwaitingApprovalKeepsTheLegacyPlist() {
        XCTAssertEqual(LoginItemManager.legacyMigrationStep(legacyStatus: .enabled, mainAppStatus: .requiresApproval),
                       .keepPlistAwaitingApproval)
    }

    func testOnlyTheLegacyItemsOwnDenialDropsThePlist() {
        for main in [SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound] {
            XCTAssertEqual(LoginItemManager.legacyMigrationStep(legacyStatus: .requiresApproval, mainAppStatus: main),
                           .dropPlistUserDisabledIt, "main-app status \(main)")
        }
    }

    func testEnabledLegacyJobRegistersWhenNothingIsRegisteredYet() {
        XCTAssertEqual(LoginItemManager.legacyMigrationStep(legacyStatus: .enabled, mainAppStatus: .notRegistered), .register)
        XCTAssertEqual(LoginItemManager.legacyMigrationStep(legacyStatus: .enabled, mainAppStatus: .notFound), .register)
        XCTAssertEqual(LoginItemManager.legacyMigrationStep(legacyStatus: .enabled, mainAppStatus: .enabled), .dropPlistMigrated)
    }

    // legacyProgramPath

    func testLegacyProgramPathReadsProgramArgumentsZero() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoSleepTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("com.nosleep.app.plist")
        let plist: [String: Any] = [
            "Label": "com.nosleep.app",
            "ProgramArguments": [installedProgram],
            "RunAtLoad": true,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)

        XCTAssertEqual(LoginItemManager.legacyProgramPath(at: url), installedProgram)
        XCTAssertNil(LoginItemManager.legacyProgramPath(at: dir.appendingPathComponent("missing.plist")))
    }
}

// MARK: - Toggle and migration behaviour (fake service, temp plist)

@MainActor
final class LoginItemManagerBehaviourTests: XCTestCase {
    private var dir: URL!
    private var plistURL: URL!
    private var service: FakeLoginItemService!

    private let home = URL(fileURLWithPath: "/Users/me")
    private let installed = URL(fileURLWithPath: "/Applications/NoSleep.app")
    private let checkout = URL(fileURLWithPath: "/Users/me/projects/nosleep/NoSleep.app")
    /// A binary that exists, so the legacy job counts as live.
    private let existingProgram = "/usr/bin/true"

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoSleepTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        plistURL = dir.appendingPathComponent("com.nosleep.app.plist")
        service = FakeLoginItemService()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    private func writeLegacyPlist(program: String, legacyStatus: SMAppService.Status = .enabled) throws {
        let plist: [String: Any] = ["Label": "com.nosleep.app", "ProgramArguments": [program], "RunAtLoad": true]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        service.legacyStatuses[plistURL] = legacyStatus
    }

    private var plistExists: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// Mirror of the CaffeinateManager check: the menu-open observer must
    /// capture the manager weakly, so it is deallocatable and a dead manager
    /// does nothing when a menu opens.
    func testManagerIsDeallocatableAndDeadManagerDoesNotRefresh() {
        weak var weakManager: LoginItemManager?
        do {
            let m = makeManager(bundle: installed)
            weakManager = m
        }
        XCTAssertNil(weakManager, "observer block must capture the manager weakly")
        let readsBefore = service.statusReads
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        XCTAssertEqual(service.statusReads, readsBefore, "a dead manager must not refresh")
    }

    private func makeManager(bundle: URL, readOnly: Bool = false) -> LoginItemManager {
        LoginItemManager(service: service,
                         legacyPlistURL: plistURL,
                         bundleURL: bundle,
                         executableURL: bundle.appendingPathComponent("Contents/MacOS/NoSleep"),
                         homeDirectory: home,
                         isReadOnlyVolume: { _ in readOnly })
    }

    // Migration

    func testMigrationRegistersAndDropsPlistWhenLegacyJobWasOn() throws {
        try writeLegacyPlist(program: existingProgram)
        let m = makeManager(bundle: installed)
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertFalse(plistExists, "plist must go once SMAppService has taken over")
        XCTAssertEqual(m.status, .enabled)
        XCTAssertTrue(m.isEnabled)
        XCTAssertFalse(m.legacyJobEnabled)
        XCTAssertNil(m.hint)
    }

    func testMigrationKeepsPlistWhileAwaitingApprovalAcrossLaunches() throws {
        try writeLegacyPlist(program: existingProgram)
        service.statusAfterRegister = .requiresApproval

        // Launch 1: register, BTM wants consent → the legacy job must survive.
        let first = makeManager(bundle: installed)
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertTrue(plistExists)
        XCTAssertTrue(first.isEnabled, "legacy job still launches the app")
        XCTAssertEqual(first.hint, LoginItemManager.approvalHint)

        // Launch 2 (started by the legacy job): same state, no re-register, plist kept.
        let second = makeManager(bundle: installed)
        XCTAssertEqual(service.registerCount, 1, "must not call register() again while awaiting approval")
        XCTAssertTrue(plistExists, "the only launcher must not be deleted")
        XCTAssertTrue(second.isEnabled)

        // Launch 3: the user allowed the item in System Settings → migration completes.
        service.status = .enabled
        let third = makeManager(bundle: installed)
        XCTAssertFalse(plistExists)
        XCTAssertTrue(third.isEnabled)
        XCTAssertFalse(third.legacyJobEnabled)
    }

    func testMigrationDropsPlistWithoutRegisteringWhenUserDisabledLegacyAgent() throws {
        try writeLegacyPlist(program: existingProgram, legacyStatus: .requiresApproval)
        let m = makeManager(bundle: installed)
        XCTAssertEqual(service.registerCount, 0, "an explicit 'off' must carry over")
        XCTAssertFalse(plistExists)
        XCTAssertFalse(m.isEnabled)
    }

    func testMigrationIsSkippedForABuildDirectoryCopy() throws {
        try writeLegacyPlist(program: existingProgram)
        let m = makeManager(bundle: checkout)
        XCTAssertEqual(service.registerCount, 0)
        XCTAssertTrue(plistExists)
        XCTAssertTrue(m.legacyJobEnabled, "the legacy job still counts as 'on'")
        XCTAssertTrue(m.isEnabled)
    }

    func testMigrationIsSkippedWhenNotRegistrable() throws {
        try writeLegacyPlist(program: existingProgram)
        let m = makeManager(bundle: installed, readOnly: true)   // running from the DMG
        XCTAssertEqual(service.registerCount, 0)
        XCTAssertTrue(plistExists)
        XCTAssertFalse(m.canRegister)
        XCTAssertTrue(m.isEnabled)
        XCTAssertNil(m.hint, "legacy job covers autostart; nothing to nag about")
    }

    // Legacy job liveness

    func testLegacyJobIsNotLiveWhenItsBinaryIsGone() throws {
        try writeLegacyPlist(program: "/nonexistent/NoSleep.app/Contents/MacOS/NoSleep")
        let m = makeManager(bundle: checkout)   // no migration, so the plist stays
        XCTAssertTrue(plistExists)
        XCTAssertFalse(m.legacyJobEnabled)
        XCTAssertFalse(m.isEnabled, "nothing can launch the app, so the toggle must not claim it will")
    }

    // Toggle

    func testToggleOnRegisters() {
        let m = makeManager(bundle: installed)
        XCTAssertFalse(m.isEnabled)
        m.toggle()
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertTrue(m.isEnabled)
        XCTAssertNil(m.hint)
    }

    func testToggleOffRemovesLegacyPlistAndUnregisters() throws {
        try writeLegacyPlist(program: existingProgram)
        service.status = .enabled                     // both mechanisms currently on
        let m = makeManager(bundle: checkout)         // migration skipped, plist kept
        XCTAssertTrue(m.isEnabled)
        m.toggle()
        XCTAssertFalse(plistExists)
        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertFalse(m.isEnabled)
    }

    func testToggleOffOnlyLegacyJobRemovesPlistWithoutUnregisterCall() throws {
        try writeLegacyPlist(program: existingProgram)
        let m = makeManager(bundle: checkout)
        XCTAssertTrue(m.isEnabled)
        m.toggle()
        XCTAssertFalse(plistExists)
        XCTAssertEqual(service.unregisterCount, 0, "unregister() throws kSMErrorJobNotFound when nothing is registered")
        XCTAssertFalse(m.isEnabled)
    }

    func testToggleOffAlsoCleansUpAStalePlist() throws {
        try writeLegacyPlist(program: "/nonexistent/NoSleep")
        service.status = .enabled
        let m = makeManager(bundle: checkout)
        m.toggle()
        XCTAssertFalse(plistExists)
        XCTAssertEqual(service.unregisterCount, 1)
    }

    func testToggleWhileAwaitingApprovalOpensSystemSettingsInsteadOfUnregistering() {
        service.status = .requiresApproval
        let m = makeManager(bundle: installed)
        XCTAssertFalse(m.isEnabled)
        XCTAssertEqual(m.hint, LoginItemManager.approvalHint)
        m.toggle()
        XCTAssertEqual(service.openSettingsCount, 1)
        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(service.unregisterCount, 0)
    }

    func testToggleOnThatEndsUpNeedingApprovalOpensSystemSettings() {
        service.statusAfterRegister = .requiresApproval
        let m = makeManager(bundle: installed)
        m.toggle()
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(service.openSettingsCount, 1)
        XCTAssertEqual(m.hint, LoginItemManager.approvalHint)
    }

    func testToggleOnFromNonInstallableLocationExplainsInsteadOfRegistering() {
        let m = makeManager(bundle: installed, readOnly: true)
        XCTAssertFalse(m.canRegister)
        XCTAssertEqual(m.hint, LoginItemManager.moveToApplicationsHint)
        m.toggle()
        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(m.lastError, LoginItemManager.moveToApplicationsHint)
    }

    func testRegisterFailureIsSurfacedAndClearedOnceStateChanges() {
        service.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        let m = makeManager(bundle: installed)
        m.toggle()
        XCTAssertEqual(m.hint, "Operation not permitted")

        // The user fixes it in System Settings; the next menu open must not
        // keep showing a caption that contradicts the checkbox.
        service.status = .enabled
        m.refresh()
        XCTAssertTrue(m.isEnabled)
        XCTAssertNil(m.hint)
    }
}
