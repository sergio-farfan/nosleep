// MenuBarViewTests.swift
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

final class MenuBarViewTests: XCTestCase {
    func testAboutDescriptionShowsTheBundleVersion() {
        XCTAssertEqual(MenuBarView.aboutDescription(version: "1.2.0"),
                       "Keeps your Mac awake from the menu bar.\nVersion 1.2.0")
    }

    func testAboutDescriptionForAnUnbundledBinary() {
        XCTAssertEqual(MenuBarView.aboutDescription(version: nil),
                       "Keeps your Mac awake from the menu bar.\nDevelopment build")
    }

    @MainActor
    func testStatusDotsAreCachedPerState() {
        XCTAssertTrue(MenuBarView.statusDot(.active) === MenuBarView.statusDot(.active))
        XCTAssertFalse(MenuBarView.statusDot(.active) === MenuBarView.statusDot(.inactive))
        XCTAssertFalse(MenuBarView.statusDot(.ended).isTemplate)
    }
}
