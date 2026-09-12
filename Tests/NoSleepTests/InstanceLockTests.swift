// InstanceLockTests.swift
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

/// The single-instance guard is a kernel lock, so two processes starting in
/// the same millisecond cannot both win or both lose. BSD locks belong to the
/// open file description, which lets one process stand in for two here.
final class InstanceLockTests: XCTestCase {
    private func temporaryLockURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nosleep-lock-\(UUID().uuidString)/instance.lock")
    }

    func testLockIsExclusiveUntilReleasedAndRecordsTheOwnerPid() throws {
        let url = temporaryLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // In production the file always already exists after the first launch
        // and holds a previous owner's pid; the winner must overwrite it fully.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "9999999999\n".write(to: url, atomically: true, encoding: .utf8)

        guard case .acquired(let fd) = NoSleepApp.acquireInstanceLock(at: url) else {
            return XCTFail("first acquire should succeed")
        }
        XCTAssertNotEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0, "lock fd must not leak into the caffeinate child")
        let second = NoSleepApp.acquireInstanceLock(at: url)
        if case .acquired(let leaked) = second { close(leaked) }   // do not let a failure cascade
        XCTAssertEqual(second,
                       .heldByOtherInstance(pid: ProcessInfo.processInfo.processIdentifier),
                       "a second holder must lose and learn who won (stale content truncated)")
        close(fd)

        guard case .acquired(let fd2) = NoSleepApp.acquireInstanceLock(at: url) else {
            return XCTFail("acquire after the holder released (exited) should succeed")
        }
        close(fd2)
    }

    func testUnwritableLocationReportsUnavailableNotHeld() {
        // No parent can be created under a file, so open() fails with a real
        // error rather than EWOULDBLOCK; the app then runs without the guard
        // instead of wrongly believing another instance exists.
        let url = URL(fileURLWithPath: "/dev/null/NoSleep/instance.lock")
        guard case .unavailable(let code) = NoSleepApp.acquireInstanceLock(at: url) else {
            return XCTFail("expected .unavailable")
        }
        XCTAssertNotEqual(code, EWOULDBLOCK)
    }

    func testCreatesTheParentDirectoryOnFirstUse() throws {
        let url = temporaryLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        guard case .acquired(let fd) = NoSleepApp.acquireInstanceLock(at: url) else {
            return XCTFail("acquire should create Application Support/NoSleep on demand")
        }
        close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
