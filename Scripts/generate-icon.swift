import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let width = size
let height = size
let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else {
    fputs("Failed to create CGContext.\n", stderr)
    exit(1)
}

let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

// White background.
ctx.setFillColor(white)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Subtle edge so the icon reads in Finder while staying minimal.
ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.08))
ctx.setLineWidth(4)
ctx.addPath(CGPath(roundedRect: CGRect(x: 72, y: 72, width: 880, height: 880), cornerWidth: 190, cornerHeight: 190, transform: nil))
ctx.strokePath()

// Centered minimalist lowercase "d".
let fontSize: CGFloat = 680
let font = NSFont.systemFont(ofSize: fontSize, weight: .black)
let text = "d" as NSString
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.black
]
let textSize = text.size(withAttributes: attrs)
let textRect = CGRect(
    x: (CGFloat(size) - textSize.width) * 0.5,
    y: (CGFloat(size) - textSize.height) * 0.5 - 24,
    width: textSize.width,
    height: textSize.height
)

NSGraphicsContext.saveGraphicsState()
let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = gc
text.draw(in: textRect, withAttributes: attrs)
NSGraphicsContext.restoreGraphicsState()

guard let image = ctx.makeImage() else {
    fputs("Failed to create CGImage.\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: "Assets/AppIcon.iconset/icon_1024x1024.png")
guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fputs("Failed to create image destination.\n", stderr)
    exit(1)
}

CGImageDestinationAddImage(destination, image, nil)
if !CGImageDestinationFinalize(destination) {
    fputs("Failed to write PNG file.\n", stderr)
    exit(1)
}

print("Wrote \(outputURL.path)")
