// Reproducible, dependency-free flat vertical-lift bridge icon.
// Run from repository root: swift Scripts/generate-icon.swift
// Writes the packaging source, complete iconset, Assets/Drawbridge.icns,
// and review previews under ignored .build/icon-redesign-preview.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")
let iconset = assets.appendingPathComponent("AppIcon.iconset")
let preview = root.appendingPathComponent(".build/icon-redesign-preview")
for dir in [iconset, preview] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
              bytesPerRow: w * 4, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}
func write(_ image: CGImage, _ url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination), "Cannot write \(url.path)")
}

let ctx = context(1024, 1024)
// Top-left coordinate system keeps the steel elevation easy to edit.
ctx.translateBy(x: 0, y: 1024)
ctx.scaleBy(x: 1, y: -1)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                   cornerWidth: 220, cornerHeight: 220, transform: nil))
ctx.clip()
// Seeded copper-orange patina, not a lighting gradient or a drop shadow.
// Broad oxide variation plus fine grain stays deliberately low contrast.
var state: UInt64 = 0x4452415742524944
func random() -> Double {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    return Double(state >> 32) / Double(UInt32.max)
}
var pixels = [UInt8](repeating: 255, count: 1024 * 1024 * 4)
for y in 0..<1024 {
    for x in 0..<1024 {
        let u = Double(x), v = Double(y)
        let broad = sin(u * 0.013 + sin(v * 0.009) * 2.2) * sin(v * 0.017 + u * 0.003)
        let oxide = sin(u * 0.039 + v * 0.018) * sin(v * 0.031 - u * 0.011)
        let grain = (random() - 0.5) * 7
        let delta = broad * 7 + oxide * 2.6 + grain
        let i = (y * 1024 + x) * 4
        pixels[i] = UInt8(max(0, min(255, 219 + delta)))
        pixels[i + 1] = UInt8(max(0, min(255, 116 + delta * 0.80)))
        pixels[i + 2] = UInt8(max(0, min(255, 49 + delta * 0.48)))
    }
}
let data = Data(pixels) as CFData
let patina = CGImage(width: 1024, height: 1024, bitsPerComponent: 8, bitsPerPixel: 32,
                     bytesPerRow: 4096, space: space,
                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                     provider: CGDataProvider(data: data)!, decode: nil,
                     shouldInterpolate: false, intent: .defaultIntent)!
ctx.draw(patina, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
// Sparse horizontal weather marks in the same orange family.
for _ in 0..<1100 {
    let x = random() * 1024, y = random() * 1024
    ctx.setFillColor(color(113, 53, 21, CGFloat(0.025 + random() * 0.035)))
    ctx.fill(CGRect(x: x, y: y, width: 1 + random() * 7, height: 0.6 + random()))
}
ctx.restoreGState()

// A single deep-rust silhouette: two rectangular steel lift towers, modest
// machinery caps, elevated Warren-truss span, and lower approach decks.
// No perspective faces, masonry, crenellations, cables, or decorative shadows.
let rust = color(87, 39, 18)
ctx.setFillColor(rust)
ctx.setStrokeColor(rust)
ctx.setLineCap(.square)
ctx.setLineJoin(.miter)
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
    ctx.fill(CGRect(x: x, y: y, width: w, height: h))
}
func line(_ points: [(CGFloat, CGFloat)], _ width: CGFloat) {
    ctx.setLineWidth(width)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: points[0].0, y: points[0].1))
    for point in points.dropFirst() { ctx.addLine(to: CGPoint(x: point.0, y: point.1)) }
    ctx.strokePath()
}
for x: CGFloat in [210, 700] {
    // Little flat caps and open, braced rectangular towers.
    rect(x - 12, 226, 136, 25)
    rect(x + 3, 216, 106, 12)
    rect(x, 250, 21, 520)
    rect(x + 91, 250, 21, 520)
    for y: CGFloat in [263, 393, 523, 653] {
        rect(x + 14, y, 84, 13)
    }
    for y: CGFloat in [276, 536, 666] {
        let bottom = min(y + 112, 756)
        line([(x + 22, y), (x + 90, bottom)], 12)
        line([(x + 90, y), (x + 22, bottom)], 12)
    }
    // Upper open tower bracing remains visible above the raised span.
    line([(x + 22, 276), (x + 90, 388)], 12)
    rect(x - 14, 769, 140, 25)
}
// Raised center span: strong top and bottom chords with four clear triangles.
rect(306, 409, 412, 21)
rect(306, 552, 412, 27)
let nodes: [CGFloat] = [317, 414.5, 512, 609.5, 707]
for i in 0..<4 {
    line([(nodes[i], 550), ((nodes[i] + nodes[i + 1]) / 2, 433), (nodes[i + 1], 550)], 17)
}
// Short approach spans below the lifted deck make the mechanism unambiguous.
rect(134, 706, 178, 24)
rect(712, 706, 178, 24)
line([(145, 737), (191, 773), (238, 737)], 14)
line([(786, 737), (833, 773), (879, 737)], 14)

let master = ctx.makeImage()!
write(master, assets.appendingPathComponent("db.png"))
write(master, preview.appendingPathComponent("drawbridge-1024.png"))
let names: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_64x64", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024), ("icon_1024x1024", 1024)
]
var images: [Int: CGImage] = [1024: master]
for (name, size) in names {
    if images[size] == nil {
        let small = context(size, size)
        small.interpolationQuality = .high
        small.draw(master, in: CGRect(x: 0, y: 0, width: size, height: size))
        images[size] = small.makeImage()!
    }
    write(images[size]!, iconset.appendingPathComponent(name + ".png"))
}
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("Drawbridge.icns").path]
try tool.run()
tool.waitUntilExit()
precondition(tool.terminationStatus == 0, "iconutil failed")

// Native-pixel previews on light/dark surroundings.
let sheet = context(1100, 640)
sheet.setFillColor(color(241, 235, 224))
sheet.fill(CGRect(x: 0, y: 320, width: 1100, height: 320))
sheet.setFillColor(color(34, 30, 27))
sheet.fill(CGRect(x: 0, y: 0, width: 1100, height: 320))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: sheet, flipped: false)
let sizes = [16, 32, 64, 128, 256]
for (index, size) in sizes.enumerated() {
    let x = CGFloat([55, 165, 285, 445, 695][index])
    for dark in [false, true] {
        let base: CGFloat = dark ? 0 : 320
        sheet.draw(images[size]!, in: CGRect(x: x, y: base + 45, width: CGFloat(size), height: CGFloat(size)))
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium), .foregroundColor: dark ? NSColor.white : NSColor.black]
        ("\(size) px" as NSString).draw(at: CGPoint(x: x, y: base + 15), withAttributes: attrs)
    }
}
NSGraphicsContext.restoreGraphicsState()
write(sheet.makeImage()!, preview.appendingPathComponent("small-size-contact-sheet.png"))
print("Generated Assets/db.png, 12 iconset PNGs, Assets/Drawbridge.icns")
print("Previews: \(preview.path)")
