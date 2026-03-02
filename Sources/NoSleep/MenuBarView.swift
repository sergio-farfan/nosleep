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
            // Status line
            if manager.isActive {
                Label(
                    "Active — \(manager.formattedRemaining) left",
                    systemImage: "circle.fill"
                )
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            } else {
                Label("Inactive", systemImage: "circle")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }

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
    }
}
