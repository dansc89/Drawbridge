#!/usr/bin/env swift
import AppKit

// Finder draws the application and Applications icons over this image.
// Keep their centers at (200, 285) and (650, 285) in package-dmg.sh.
guard CommandLine.arguments.count == 3,
      let scale = Int(CommandLine.arguments[2]),
      scale == 1 || scale == 2 else {
    fputs("Usage: generate-dmg-background.swift <output_tiff_path> <scale: 1|2>\n", stderr)
    exit(1)
}

let outputPath = CommandLine.arguments[1]
let size = NSSize(width: 860, height: 520)
let image = NSImage(size: NSSize(width: size.width * CGFloat(scale), height: size.height * CGFloat(scale)))

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: 1
    )
}

func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, ink: NSColor) {
    text.draw(at: NSPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: ink
    ])
}

image.lockFocus()
// Draw at native pixel density; never enlarge a finished 1x bitmap.
let pixelTransform = NSAffineTransform()
pixelTransform.scale(by: CGFloat(scale))
pixelTransform.concat()
color(0xF7F6F2).setFill()
NSRect(origin: .zero, size: size).fill()

// A quiet brand accent, not an illustration competing with the Finder icons.
color(0xC27735).setFill()
NSRect(x: 52, y: 481, width: 28, height: 3).fill()
label("DRAWBRIDGE", x: 52, y: 454, size: 11, weight: .semibold, ink: color(0x81502D))
label("Install Drawbridge", x: 52, y: 405, size: 30, weight: .semibold, ink: color(0x242526))
label("Drag the app into Applications.", x: 53, y: 376, size: 16, weight: .regular, ink: color(0x606366))

// Slim connector, aligned with the two actual Finder icons (not baked-in mock icons).
let line = NSBezierPath()
line.lineWidth = 2
line.lineCapStyle = .round
line.move(to: NSPoint(x: 331, y: 235))
line.line(to: NSPoint(x: 517, y: 235))
color(0xB9AFA2).setStroke()
line.stroke()
let arrow = NSBezierPath()
arrow.lineWidth = 2
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 505, y: 243))
arrow.line(to: NSPoint(x: 517, y: 235))
arrow.line(to: NSPoint(x: 505, y: 227))
color(0xA0653B).setStroke()
arrow.stroke()

color(0xDDDBD5).setFill()
NSRect(x: 52, y: 80, width: 756, height: 1).fill()
label("Once copied, open Drawbridge from Applications.", x: 52, y: 51, size: 13, weight: .regular, ink: color(0x777773))
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let tiffData = rep.representation(using: .tiff, properties: [:]) else {
    fputs("Failed to encode TIFF\n", stderr)
    exit(1)
}

do {
    try tiffData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
} catch {
    fputs("Failed to write TIFF: \(error)\n", stderr)
    exit(1)
}
