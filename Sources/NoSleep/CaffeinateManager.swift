// CaffeinateManager.swift
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
import SwiftUI

enum SleepDuration: Int, CaseIterable, Identifiable, Sendable {
    case fifteenMin = 900
    case thirtyMin  = 1800
    case oneHour    = 3600
    case twoHours   = 7200
    case fourHours  = 14400
    case eightHours = 28800
    case tenHours   = 36000
    case indefinite = 0

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .fifteenMin: "15 minutes"
        case .thirtyMin:  "30 minutes"
        case .oneHour:    "1 hour"
        case .twoHours:   "2 hours"
        case .fourHours:  "4 hours"
        case .eightHours: "8 hours"
        case .tenHours:   "10 hours"
        case .indefinite: "Indefinite"
        }
    }
}

@MainActor
final class CaffeinateManager: ObservableObject {
    @Published var isActive = false
    @Published var remainingSeconds: Int = 0
    @Published var selectedDuration: SleepDuration {
        didSet {
            UserDefaults.standard.set(selectedDuration.rawValue, forKey: "selectedDuration")
        }
    }

    private var process: Process?
    private var timer: Timer?

    init() {
        let saved = UserDefaults.standard.integer(forKey: "selectedDuration")
        self.selectedDuration = SleepDuration(rawValue: saved) ?? .fourHours
    }

    var formattedRemaining: String {
        guard isActive else { return "" }
        if selectedDuration == .indefinite { return "∞" }
        let h = remainingSeconds / 3600
        let m = (remainingSeconds % 3600) / 60
        if h > 0 {
            return "\(h)h \(m)m"
        }
        let s = remainingSeconds % 60
        if m > 0 {
            return "\(m)m \(s)s"
        }
        return "\(s)s"
    }

    func start() {
        stop()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")

        var args = ["-d", "-i"]
        if selectedDuration != .indefinite {
            args += ["-t", "\(selectedDuration.rawValue)"]
            remainingSeconds = selectedDuration.rawValue
        } else {
            remainingSeconds = 0
        }
        proc.arguments = args

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTermination()
            }
        }

        do {
            try proc.run()
        } catch {
            return
        }

        process = proc
        isActive = true

        if selectedDuration != .indefinite {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.tick()
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        isActive = false
        remainingSeconds = 0
    }

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func changeDuration(_ duration: SleepDuration) {
        selectedDuration = duration
        if isActive {
            start()
        }
    }

    func cleanup() {
        stop()
    }

    private func tick() {
        guard isActive, remainingSeconds > 0 else { return }
        remainingSeconds -= 1
        if remainingSeconds <= 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    private func handleTermination() {
        timer?.invalidate()
        timer = nil
        process = nil
        isActive = false
        remainingSeconds = 0
    }
}
