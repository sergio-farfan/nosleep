// ProcessCaffeinateLauncherTests.swift
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

/// Exercises the production launcher's terminationReason/terminationStatus →
/// `clean` mapping, which the FakeLauncher-based state tests bypass. Uses tiny
/// system binaries as stand-ins for caffeinate so no power assertion is taken.
@MainActor
final class ProcessCaffeinateLauncherTests: XCTestCase {

    @MainActor private final class Box { var clean: Bool? }

    /// Launches `executable` and returns the `clean` flag the launcher reports.
    /// `afterLaunch` runs once the child exists (e.g. to terminate it).
    private func reportedClean(executable: String,
                               arguments: [String] = [],
                               afterLaunch: @MainActor (any CaffeinateHandle) -> Void = { _ in }) async throws -> Bool {
        var launcher = ProcessCaffeinateLauncher()
        launcher.executableURL = URL(fileURLWithPath: executable)
        let box = Box()
        let done = expectation(description: "onTermination for \(executable)")
        let handle = try launcher.launch(arguments: arguments) { clean in
            box.clean = clean
            done.fulfill()
        }
        afterLaunch(handle)
        await fulfillment(of: [done], timeout: 10)
        XCTAssertFalse(handle.isRunning)
        return try XCTUnwrap(box.clean)
    }

    func testNormalExitWithStatusZeroIsClean() async throws {
        let clean = try await reportedClean(executable: "/usr/bin/true")
        XCTAssertTrue(clean)
    }

    func testNormalExitWithNonZeroStatusIsNotClean() async throws {
        let clean = try await reportedClean(executable: "/usr/bin/false")
        XCTAssertFalse(clean)
    }

    func testTerminationBySignalIsNotClean() async throws {
        // What stop() does to caffeinate, and what `killall caffeinate` does.
        let clean = try await reportedClean(executable: "/bin/sleep", arguments: ["30"]) { $0.terminate() }
        XCTAssertFalse(clean)
    }

    func testMissingExecutableThrowsInsteadOfTrapping() {
        var launcher = ProcessCaffeinateLauncher()
        launcher.executableURL = URL(fileURLWithPath: "/nonexistent/caffeinate")
        XCTAssertThrowsError(try launcher.launch(arguments: []) { _ in })
    }
}
