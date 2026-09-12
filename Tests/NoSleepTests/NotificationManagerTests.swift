// NotificationManagerTests.swift
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

import UserNotifications
import XCTest
@testable import NoSleep

/// The pure parts of the notification code: what the banner says and which
/// response runs Extend. Delivery itself needs an .app bundle and is covered
/// by running the app.
final class NotificationManagerTests: XCTestCase {

    func testCompletionContentReadsNaturallyForEveryPreset() {
        for duration in SleepDuration.allCases where duration != .indefinite {
            let text = NotificationManager.completionContent(for: duration)
            XCTAssertEqual(text.title, "Session ended")
            XCTAssertEqual(text.body, "Kept your Mac awake for \(duration.label). It can sleep again.")
            XCTAssertFalse(text.body.contains("Your \(duration.label) session"),
                           "plural labels must not be used as adjectives")
        }
    }

    func testOnlyTheExtendActionRunsExtend() {
        XCTAssertTrue(NotificationManager.shouldExtend(actionIdentifier: NotificationManager.extendActionID))
        XCTAssertTrue(NotificationManager.shouldExtend(actionIdentifier: "EXTEND_1H"),
                      "identifier is part of the registered category and must not drift")
        XCTAssertFalse(NotificationManager.shouldExtend(actionIdentifier: UNNotificationDefaultActionIdentifier),
                       "a plain tap on the banner must not start a session")
        XCTAssertFalse(NotificationManager.shouldExtend(actionIdentifier: UNNotificationDismissActionIdentifier))
    }

    func testCategoryAndActionIdentifiersAreStable() {
        // Delivered notifications keep these ids; changing them would orphan
        // banners posted by an earlier build.
        XCTAssertEqual(NotificationManager.categoryID, "SESSION_COMPLETE")
        XCTAssertEqual(NotificationManager.extendActionID, "EXTEND_1H")
    }
}
