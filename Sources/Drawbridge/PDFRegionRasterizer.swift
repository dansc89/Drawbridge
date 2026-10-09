import AppKit
import PDFKit

/// Allocate only the requested OCR region, in the same oriented pixel grid as a full-page render.
enum PDFRegionRasterizer {
    static func render(page: PDFPage, box: PDFDisplayBox, rect: CGRect, scale: CGFloat = 4) -> CGImage? {
        guard scale.isFinite, scale > 0 else { return nil }
        let transform = page.transform(for: box)
        let full = page.bounds(for: box).applying(transform).standardized
        let crop = rect.applying(transform).standardized.intersection(full)
        guard !crop.isEmpty, !crop.isNull else { return nil }
        let x = floor((crop.minX - full.minX) * scale)
        let y = floor((crop.minY - full.minY) * scale)
        let width = ceil((crop.maxX - full.minX) * scale) - x
        let height = ceil((crop.maxY - full.minY) * scale) - y
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width < 12000, height < 12000,
              let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -full.minX - x / scale, y: -full.minY - y / scale)
        page.draw(with: box, to: context)
        return context.makeImage()
    }
}
