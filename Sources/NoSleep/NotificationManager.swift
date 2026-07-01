// NotificationManager.swift
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

import Foundation
import UserNotifications

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let categoryID = "SESSION_COMPLETE"
    private let extendActionID = "EXTEND_1H"
    private var didConfigure = false

    /// Invoked when the user taps the "Extend 1 hour" action.
    var onExtend: (() -> Void)?

    /// Call once at app launch. Registers the category + action, sets the
    /// delegate, and requests authorization. Kept out of `init` so the type is
    /// safe to construct in unit tests without touching UNUserNotificationCenter.
    func requestAuthorization() {
        guard !didConfigure else { return }
        didConfigure = true

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let extend = UNNotificationAction(identifier: extendActionID,
                                          title: "Extend 1 hour",
                                          options: [])
        let category = UNNotificationCategory(identifier: categoryID,
                                              actions: [extend],
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Deliver the "session complete" banner with the Extend action.
    func postCompletion(duration: SleepDuration) {
        let content = UNMutableNotificationContent()
        content.title = "NoSleep"
        content.body = "Your \(duration.label) session has ended."
        content.categoryIdentifier = categoryID
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show the banner even though a menu-bar app is effectively always active.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let actionID = response.actionIdentifier
        Task { @MainActor [weak self] in
            if actionID == self?.extendActionID { self?.onExtend?() }
            completionHandler()
        }
    }
}
