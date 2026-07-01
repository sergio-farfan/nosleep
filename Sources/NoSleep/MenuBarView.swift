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

struct MenuBarView: View {
    @ObservedObject var manager: CaffeinateManager
    @ObservedObject var loginManager: LoginItemManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Status line — a Button so the native menu renders it in full
            // (black) text; the dot is a pre-colored (non-template) image so it
            // shows green regardless of the menu's monochrome symbol tinting.
            Button {
                manager.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(nsImage: MenuBarView.statusDot(active: manager.isActive))
                    Text(manager.isActive
                         ? "Active — \(manager.formattedRemaining) left"
                         : "Inactive")
                }
            }
            .padding(.horizontal, 4)

            Divider()

            // Toggle button
            Button {
                manager.toggle()
            } label: {
                Label(
                    manager.isActive ? "Stop" : "Start",
                    systemImage: manager.isActive ? "stop.fill" : "play.fill"
                )
            }
            .keyboardShortcut("s")
            .padding(.horizontal, 4)

            Divider()

            // Duration picker
            Text("Duration:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 2)

            ForEach(SleepDuration.allCases) { duration in
                Button {
                    manager.changeDuration(duration)
                } label: {
                    HStack {
                        Image(systemName: manager.selectedDuration == duration
                              ? "circle.inset.filled" : "circle")
                            .font(.caption2)
                        Text(duration.label)
                    }
                }
                .padding(.horizontal, 4)
            }

            Divider()

            // Start at Login
            Toggle("Start at Login", isOn: Binding(
                get: { loginManager.isEnabled },
                set: { _ in loginManager.toggle() }
            ))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)

            Divider()

            // Quit
            Button("Quit NoSleep") {
                manager.cleanup()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .padding(.horizontal, 4)
        }
        .padding(.vertical, 8)
        .frame(width: 220)
        .onAppear { manager.notifications.requestAuthorization() }
    }

    /// A small filled circle rendered as a non-template NSImage so it keeps its
    /// color (green = active, grey = inactive) inside the native menu.
    static func statusDot(active: Bool) -> NSImage {
        let size = NSSize(width: 9, height: 9)
        let image = NSImage(size: size)
        image.lockFocus()
        (active ? NSColor.systemGreen : NSColor.tertiaryLabelColor).setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
