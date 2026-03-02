// LoginItemManager.swift
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

@MainActor
final class LoginItemManager: ObservableObject {
    private let plistLabel = "com.nosleep.app"

    @Published var isEnabled: Bool

    private var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(plistLabel).plist")
    }

    init() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.nosleep.app.plist")
        self.isEnabled = FileManager.default.fileExists(atPath: url.path)
    }

    func toggle() {
        if isEnabled {
            disable()
        } else {
            enable()
        }
    }

    private func enable() {
        guard let execPath = Bundle.main.executablePath else { return }

        let plist: [String: Any] = [
            "Label": plistLabel,
            "ProgramArguments": [execPath],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]

        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        if let data = data {
            try? data.write(to: plistURL, options: .atomic)
            isEnabled = true
        }
    }

    private func disable() {
        try? FileManager.default.removeItem(at: plistURL)
        isEnabled = false
    }
}
