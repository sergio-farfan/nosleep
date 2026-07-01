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

final class CaffeinateManagerTests: XCTestCase {
    func testNotifiesOnNaturalTimedExpiry() {
        XCTAssertTrue(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: false, duration: .twoHours))
    }

    func testNoNotifyWhenStoppedByUser() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: true, duration: .twoHours))
    }

    func testNoNotifyOnStaleTokenFromRestart() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 2, stoppedByUser: false, duration: .twoHours))
    }

    func testNoNotifyForIndefinite() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: false, duration: .indefinite))
    }

    func testNoNotifyForNilDuration() {
        XCTAssertFalse(CaffeinateManager.shouldNotifyOnCompletion(
            terminatedToken: 1, currentToken: 1, stoppedByUser: false, duration: nil))
    }
}
