import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count >= 3 else {
    fputs("Usage: prepare-icon.swift <source_png> <output_png> [fill_scale]\n", stderr)
    exit(1)
}

let sourcePath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]
let fillScale = max(1.0, Double(CommandLine.arguments.dropFirst(3).first ?? "1.0") ?? 1.0)

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: sourcePath) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("Failed to load source image: \(sourcePath)\n", stderr)
    exit(1)
}

let width = image.width
let height = image.height
let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel
var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: colorSpace,
    bitmapInfo: bitmapInfo
) else {
    fputs("Failed to create CGContext\n", stderr)
    exit(1)
}

context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

func isNearWhite(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> Bool {
    if a == 0 { return true }
    return r >= 245 && g >= 245 && b >= 245
}

func index(_ x: Int, _ y: Int) -> Int { (y * bytesPerRow) + (x * bytesPerPixel) }
func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[index(x, y) + 3] }

var visited = [Bool](repeating: false, count: width * height)
func visitIndex(_ x: Int, _ y: Int) -> Int { y * width + x }
var queue = [(Int, Int)]()

func enqueueIfBackground(_ x: Int, _ y: Int) {
    let vi = visitIndex(x, y)
    if visited[vi] { return }
    let i = index(x, y)
    if isNearWhite(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]) {
        visited[vi] = true
        queue.append((x, y))
    }
}

for x in 0..<width {
    enqueueIfBackground(x, 0)
    enqueueIfBackground(x, height - 1)
}
for y in 0..<height {
    enqueueIfBackground(0, y)
    enqueueIfBackground(width - 1, y)
}

var head = 0
while head < queue.count {
    let (x, y) = queue[head]
    head += 1
    let i = index(x, y)
    pixels[i + 3] = 0
    if x > 0 { enqueueIfBackground(x - 1, y) }
    if x + 1 < width { enqueueIfBackground(x + 1, y) }
    if y > 0 { enqueueIfBackground(x, y - 1) }
    if y + 1 < height { enqueueIfBackground(x, y + 1) }
}

var minX = width
var minY = height
var maxX = -1
var maxY = -1
for y in 0..<height {
    for x in 0..<width where alpha(x, y) > 0 {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
    }
}

if maxX < 0 || maxY < 0 {
    fputs("No visible pixels after white background removal.\n", stderr)
    exit(1)
}

let contentWidth = maxX - minX + 1
let contentHeight = maxY - minY + 1
let baseSide = max(contentWidth, contentHeight)
let cropSide = max(1, Int(round(Double(baseSide) / fillScale)))
let centerX = Double(minX + maxX) / 2.0
let centerY = Double(minY + maxY) / 2.0

var cropX = Int(round(centerX - Double(cropSide) / 2.0))
var cropY = Int(round(centerY - Double(cropSide) / 2.0))
cropX = max(0, min(width - cropSide, cropX))
cropY = max(0, min(height - cropSide, cropY))

guard let processedData = CFDataCreate(nil, pixels, pixels.count),
      let provider = CGDataProvider(data: processedData),
      let processed = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
      ),
      let cropped = processed.cropping(to: CGRect(x: cropX, y: cropY, width: cropSide, height: cropSide))
else {
    fputs("Failed to process icon image.\n", stderr)
    exit(1)
}

let outSize = 1024
guard let outCtx = CGContext(
    data: nil,
    width: outSize,
    height: outSize,
    bitsPerComponent: 8,
    bytesPerRow: outSize * 4,
    space: colorSpace,
    bitmapInfo: bitmapInfo
) else {
    fputs("Failed to create output context.\n", stderr)
    exit(1)
}
outCtx.clear(CGRect(x: 0, y: 0, width: outSize, height: outSize))
outCtx.interpolationQuality = .high
outCtx.draw(cropped, in: CGRect(x: 0, y: 0, width: outSize, height: outSize))

guard let outImage = outCtx.makeImage() else {
    fputs("Failed to create output image.\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: outputPath)
let outputType = UTType.png.identifier as CFString
guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, outputType, 1, nil) else {
    fputs("Failed to create output destination: \(outputPath)\n", stderr)
    exit(1)
}
CGImageDestinationAddImage(destination, outImage, nil)
if !CGImageDestinationFinalize(destination) {
    fputs("Failed to write output image: \(outputPath)\n", stderr)
    exit(1)
}
