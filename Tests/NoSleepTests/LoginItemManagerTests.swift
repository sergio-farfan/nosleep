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

import XCTest
@testable import NoSleep

/// Pure predicates only — `SMAppService` itself must stay out of the test
/// target (it would register real login items on the developer's machine).
final class LoginItemManagerTests: XCTestCase {

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
            URL(fileURLWithPath: "/Volumes/Data/Applications/NoSleep.app")))
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
