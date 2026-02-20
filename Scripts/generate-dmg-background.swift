#!/usr/bin/env swift
import AppKit

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate-dmg-background.swift <output_png_path>\n", stderr)
    exit(1)
}

let outputPath = CommandLine.arguments[1]
let size = NSSize(width: 860, height: 520)
let image = NSImage(size: size)

image.lockFocus()

let rect = NSRect(origin: .zero, size: size)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.95, green: 0.98, blue: 1.0, alpha: 1.0),
    NSColor(calibratedRed: 0.88, green: 0.93, blue: 0.99, alpha: 1.0)
])!
gradient.draw(in: rect, angle: 90)

NSColor(calibratedWhite: 1.0, alpha: 0.8).setFill()
let banner = NSBezierPath(roundedRect: NSRect(x: 110, y: 410, width: 640, height: 72), xRadius: 16, yRadius: 16)
banner.fill()

let title = "Drag Drawbridge to Applications"
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 34, weight: .bold),
    .foregroundColor: NSColor(calibratedRed: 0.11, green: 0.23, blue: 0.40, alpha: 1.0)
]
let titleSize = title.size(withAttributes: titleAttrs)
title.draw(
    at: NSPoint(x: (size.width - titleSize.width) * 0.5, y: 430),
    withAttributes: titleAttrs
)

let subtitle = "Install by dropping the app onto Applications"
let subtitleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 18, weight: .medium),
    .foregroundColor: NSColor(calibratedRed: 0.24, green: 0.34, blue: 0.47, alpha: 1.0)
]
let subtitleSize = subtitle.size(withAttributes: subtitleAttrs)
subtitle.draw(
    at: NSPoint(x: (size.width - subtitleSize.width) * 0.5, y: 392),
    withAttributes: subtitleAttrs
)

let arrowPath = NSBezierPath()
arrowPath.lineWidth = 14
arrowPath.lineCapStyle = .round
arrowPath.move(to: NSPoint(x: 300, y: 250))
arrowPath.line(to: NSPoint(x: 560, y: 250))
NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.80, alpha: 0.95).setStroke()
arrowPath.stroke()

let arrowHead = NSBezierPath()
arrowHead.move(to: NSPoint(x: 560, y: 250))
arrowHead.line(to: NSPoint(x: 520, y: 285))
arrowHead.line(to: NSPoint(x: 520, y: 215))
arrowHead.close()
NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.80, alpha: 0.95).setFill()
arrowHead.fill()

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
} catch {
    fputs("Failed to write PNG: \(error)\n", stderr)
    exit(1)
}
