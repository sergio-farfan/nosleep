// MenuBarView.swift
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

import SwiftUI

/// Content of the `.menu`-style MenuBarExtra. Everything here is bridged into
/// native `NSMenuItem`s: layout modifiers (VStack/HStack spacing, padding,
/// frame) are no-ops and are deliberately absent. What does survive the bridge:
/// `.font` (becomes the item's `attributedTitle`), `.keyboardShortcut` (key
/// equivalent), `.disabled`, and Toggle state. Do not use
/// `.foregroundStyle(.secondary)` on captions — the bridge bakes it to a static
/// colour, whereas disabled items are already drawn in dynamic grey.
struct MenuBarView: View {
    var manager: CaffeinateManager
    var loginManager: LoginItemManager

    var body: some View {
        // Status line — a Button so the native menu renders it in full (black)
        // text; the dot is a pre-coloured (non-template) image so it keeps its
        // colour regardless of the menu's monochrome symbol tinting.
        Button {
            manager.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(nsImage: MenuBarView.statusDot(dotState))
                Text(manager.statusText)
            }
        }

        Divider()

        Button {
            manager.toggle()
        } label: {
            Label(
                manager.isActive ? "Stop" : "Start",
                systemImage: manager.isActive ? "stop.fill" : "play.fill"
            )
        }
        .keyboardShortcut("s")

        if manager.notificationsDenied {
            // Notifications are denied, so the session-ended alert cannot appear.
            // Sits with the session controls it concerns, and offers the fix
            // rather than a dead-end caption.
            Button("Allow notifications in System Settings…") {
                if let url = MenuBarView.notificationSettingsURL {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        // Duration — Toggles so the native menu marks the running (or, when
        // inactive, the saved) preset via NSMenuItem.state (a real checkmark,
        // exposed to VoiceOver as AXMenuItemMarkChar). The setter ignores the
        // Bool so re-picking any duration (re)starts, as before. Section
        // supplies the separators and a grey header on both sides.
        Section("Duration") {
            ForEach(SleepDuration.allCases) { duration in
                Toggle(duration.label, isOn: Binding(
                    get: { manager.displayedDuration == duration },
                    set: { _ in manager.changeDuration(duration) }
                ))
            }
        }

        // Start at Login — state comes from Background Task Management (what
        // System Settings shows), not from a file the app wrote.
        Toggle("Start at Login", isOn: Binding(
            get: { loginManager.isEnabled },
            set: { _ in loginManager.toggle() }
        ))
        .disabled(!loginManager.canRegister && !loginManager.isEnabled)
        if let hint = loginManager.hint {
            // Non-interactive, so the menu draws it disabled/grey; .font(.caption)
            // is honoured via attributedTitle and keeps the menu narrow.
            Text(hint)
                .font(.caption)
        }

        Toggle("Activate on Launch", isOn: Binding(
            get: { manager.activateOnLaunch },
            set: { manager.activateOnLaunch = $0 }
        ))

        Divider()

        Button("About NoSleep") {
            MenuBarView.showAbout()
        }

        Divider()

        Button("Quit NoSleep") {
            manager.cleanup()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    // MARK: - About

    nonisolated static let aboutTagline = "Keeps your Mac awake from the menu bar."

    /// Body of the About alert. `version` is nil for a bare (unbundled) binary.
    nonisolated static func aboutDescription(version: String?) -> String {
        let versionLine = version.map { "Version \($0)" } ?? "Development build"
        return "\(aboutTagline)\n\(versionLine)"
    }

    /// Icon, name, tagline and version — the same shape as a standard app
    /// About alert. A menu-bar-only app is never the active app, so activate
    /// first or the alert appears behind whatever is frontmost.
    @MainActor
    static func showAbout() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "NoSleep"
        alert.informativeText = aboutDescription(
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        alert.icon = NSApplication.shared.applicationIconImage
        alert.addButton(withTitle: "OK")
        let previous = NSWorkspace.shared.frontmostApplication
        NSApplication.shared.activate()
        alert.runModal()
        // A menu-bar-only app has nothing to stay active for; hand focus back
        // to whatever the user was working in.
        previous?.activate(options: [])
    }

    /// Deep link to this app's pane in System Settings › Notifications.
    private static var notificationSettingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "com.nosleep.app")")
    }

    // MARK: - Status dot

    enum DotState: Hashable {
        case active, ended, inactive
    }

    private var dotState: DotState {
        if manager.isActive { return .active }
        if manager.lastEnded != nil { return .ended }
        return .inactive
    }

    @MainActor private static var dotCache: [DotState: NSImage] = [:]

    /// A small filled circle as a non-template `NSImage` so it keeps its colour
    /// inside the native menu: green = active, orange = the last session expired
    /// on its own and nothing has been started since, grey = inactive. Drawn with a drawing handler (not the
    /// deprecated `lockFocus`), so it is resolution-independent and re-evaluates
    /// dynamic colours per appearance; cached per state so the menu does not
    /// rebuild it on every body evaluation.
    @MainActor
    static func statusDot(_ state: DotState) -> NSImage {
        if let cached = dotCache[state] { return cached }
        let color: NSColor = switch state {
        case .active:   .systemGreen
        case .ended:    .systemOrange
        case .inactive: .tertiaryLabelColor
        }
        let image = NSImage(size: NSSize(width: 9, height: 9), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        dotCache[state] = image
        return image
    }
}
