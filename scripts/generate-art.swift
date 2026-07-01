// generate-art.swift
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
//
// Renders the app icon and the DMG background image, entirely from the
// system's SF Symbols — no external art. Run via `swift scripts/generate-art.swift`
// (or through ./make-icons.sh). Output PNGs are written under ./assets/.

import AppKit
import Foundation

// Initialise AppKit so SF Symbol rendering works from a plain script.
_ = NSApplication.shared

// MARK: - Palette (tweak here to restyle)
let iconTopColor    = NSColor(srgbRed: 0.90, green: 0.68, blue: 0.44, alpha: 1) // warm caramel
let iconBottomColor = NSColor(srgbRed: 0.29, green: 0.17, blue: 0.09, alpha: 1) // espresso
let glyphColor      = NSColor.white
let bgTopColor      = NSColor(srgbRed: 0.97, green: 0.96, blue: 0.94, alpha: 1)
let bgBottomColor   = NSColor(srgbRed: 0.90, green: 0.87, blue: 0.83, alpha: 1)

let outputDir = "assets"

// MARK: - Drawing helpers

func makeContext(width: Int, height: Int) -> (NSBitmapImageRep, NSGraphicsContext) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        FileHandle.standardError.write("Failed to create bitmap context\n".data(using: .utf8)!)
        exit(1)
    }
    rep.size = NSSize(width: width, height: height)
    return (rep, ctx)
}

func savePNG(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("Failed to encode PNG: \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    } catch {
        FileHandle.standardError.write("Failed to write \(path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// MARK: - App icon

func drawAppIcon(size: Int) {
    let (rep, ctx) = makeContext(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let s = CGFloat(size)
    let margin = s * 0.06
    let rect = NSRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let radius = rect.width * 0.2237 // Apple "squircle" corner ratio approximation

    NSGraphicsContext.saveGraphicsState()
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    squircle.addClip()
    NSGradient(starting: iconTopColor, ending: iconBottomColor)!.draw(in: rect, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Centered white cup.and.saucer.fill glyph
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [glyphColor]))
    if let symbol = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let symSize = symbol.size
        let drawRect = NSRect(
            x: (s - symSize.width) / 2,
            y: (s - symSize.height) / 2,
            width: symSize.width,
            height: symSize.height
        )
        symbol.draw(in: drawRect)
    } else {
        FileHandle.standardError.write("Failed to load SF Symbol cup.and.saucer.fill\n".data(using: .utf8)!)
        exit(1)
    }

    NSGraphicsContext.restoreGraphicsState()
    savePNG(rep, to: "\(outputDir)/AppIcon.png")
}

// MARK: - DMG background

func drawDMGBackground(width: Int, height: Int, path: String) {
    let (rep, ctx) = makeContext(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let w = CGFloat(width), h = CGFloat(height)
    // Design baseline is 600x400; everything scales from there.
    let sx = w / 600.0, sy = h / 400.0

    NSGradient(starting: bgTopColor, ending: bgBottomColor)!
        .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

    // Arrow pointing from the app icon slot toward the Applications drop-target.
    // Icons sit at Finder y=190 → image y = h - 190*sy (bottom-left origin here).
    let arrowY = h - 190 * sy
    let startX = 250 * sx
    let endX = 350 * sx
    let arrowColor = NSColor(white: 0.45, alpha: 0.9)
    arrowColor.setStroke()
    arrowColor.setFill()

    let shaft = NSBezierPath()
    shaft.lineWidth = 6 * sx
    shaft.lineCapStyle = .round
    shaft.move(to: NSPoint(x: startX, y: arrowY))
    shaft.line(to: NSPoint(x: endX, y: arrowY))
    shaft.stroke()

    let hs = 18 * sx
    let head = NSBezierPath()
    head.move(to: NSPoint(x: endX + hs, y: arrowY))
    head.line(to: NSPoint(x: endX - hs * 0.2, y: arrowY + hs))
    head.line(to: NSPoint(x: endX - hs * 0.2, y: arrowY - hs))
    head.close()
    head.fill()

    // Caption near the bottom.
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 20 * sx, weight: .medium),
        .foregroundColor: NSColor(white: 0.35, alpha: 1),
        .paragraphStyle: paragraph,
    ]
    let text = NSAttributedString(string: "Drag NoSleep to Applications to install", attributes: attrs)
    let textSize = text.size()
    text.draw(in: NSRect(x: (w - textSize.width) / 2, y: 55 * sy, width: textSize.width, height: textSize.height))

    NSGraphicsContext.restoreGraphicsState()
    savePNG(rep, to: path)
}

// MARK: - Main

try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
drawAppIcon(size: 1024)
drawDMGBackground(width: 600, height: 400, path: "\(outputDir)/dmg-background.png")
drawDMGBackground(width: 1200, height: 800, path: "\(outputDir)/dmg-background@2x.png")
