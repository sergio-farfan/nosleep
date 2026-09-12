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
import os
import UserNotifications

/// Seam between `CaffeinateManager` and the real notification centre so the
/// state machine can be unit-tested with a spy instead of `UNUserNotificationCenter`.
@MainActor
protocol NotificationPosting: AnyObject {
    /// Invoked when the user taps the "Extend 1 hour" action.
    var onExtend: (() -> Void)? { get set }
    /// Invoked with the latest answer to "has the user denied notifications?"
    /// after every authorization request or refresh.
    var onAuthorizationDenied: ((Bool) -> Void)? { get set }
    func requestAuthorization()
    func refreshAuthorizationStatus()
    func postCompletion(duration: SleepDuration)
    func clearDelivered()
}

@MainActor
final class NotificationManager: NSObject, NotificationPosting, UNUserNotificationCenterDelegate {
    nonisolated private static let log = Logger(subsystem: "com.nosleep.app", category: "notifications")

    private let categoryID = "SESSION_COMPLETE"
    private let extendActionID = "EXTEND_1H"
    private var didConfigure = false

    /// `UNUserNotificationCenter.current()` traps ("bundleProxyForCurrentProcess
    /// is nil") unless the process runs from an .app bundle. `swift run`, the bare
    /// `.build/…` binary and the xctest host are not bundles, so every entry point
    /// below is a no-op there instead of aborting the process.
    nonisolated static let isSupported = Bundle.main.bundleURL.pathExtension == "app"

    /// Invoked when the user taps the "Extend 1 hour" action.
    var onExtend: (() -> Void)?
    var onAuthorizationDenied: ((Bool) -> Void)?

    /// Call once at app launch. Registers the category + action, sets the
    /// delegate, and requests authorization. `CaffeinateManager.init` runs during
    /// app launch (via `@State` on the App), which satisfies the delegate's
    /// "before the app finishes launching" requirement. No-op outside an .app
    /// bundle, so the type is safe in `swift run` and unit tests.
    func requestAuthorization() {
        guard Self.isSupported, !didConfigure else { return }
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

        Task { @MainActor [weak self] in
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                Self.log.info("notification authorization granted=\(granted, privacy: .public)")
            } catch {
                Self.log.error("requestAuthorization failed: \(error.localizedDescription, privacy: .public)")
            }
            self?.refreshAuthorizationStatus()
        }
    }

    /// Re-read the authorization status and report whether the user has denied
    /// notifications, so the menu can say why no session-ended alert will show.
    func refreshAuthorizationStatus() {
        guard Self.isSupported else { return }
        Task { @MainActor [weak self] in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            self?.onAuthorizationDenied?(settings.authorizationStatus == .denied)
        }
    }

    /// Deliver the "session complete" banner with the Extend action.
    func postCompletion(duration: SleepDuration) {
        guard Self.isSupported else { return }

        let content = UNMutableNotificationContent()
        // The banner already shows the app name, so the title says what happened
        // and the body avoids "Your 2 hours session" grammar.
        content.title = "Session ended"
        content.body = "Kept your Mac awake for \(duration.label). It can sleep again."
        content.categoryIdentifier = categoryID
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.log.error("postCompletion failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Remove any delivered "session complete" banners from Notification Center
    /// so a stale "Extend 1 hour" action cannot be tapped after a new session has
    /// started (or after the app quit) and replace whatever is running.
    func clearDelivered() {
        guard Self.isSupported, didConfigure else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // Show the banner even though a menu-bar app is effectively always active,
    // and keep it in Notification Center (.list) so it can be found later.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
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
