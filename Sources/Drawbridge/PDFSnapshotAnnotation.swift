import AppKit
import PDFKit

final class PDFSnapshotAnnotation: PDFAnnotation {
    static let contentsPrefix = "DrawbridgePDFSnapshotPath|"
    enum TintBlendStyle: Int {
        case screen = 0
        case multiply = 1
    }

    private enum CodingKeys {
        static let renderOpacity = "DrawbridgePDFSnapshotRenderOpacity"
        static let renderTintRed = "DrawbridgePDFSnapshotRenderTintRed"
        static let renderTintGreen = "DrawbridgePDFSnapshotRenderTintGreen"
        static let renderTintBlue = "DrawbridgePDFSnapshotRenderTintBlue"
        static let renderTintAlpha = "DrawbridgePDFSnapshotRenderTintAlpha"
        static let renderTintStrength = "DrawbridgePDFSnapshotRenderTintStrength"
        static let tintBlendStyle = "DrawbridgePDFSnapshotTintBlendStyle"
        static let lineworkOnlyTint = "DrawbridgePDFSnapshotLineworkOnlyTint"
        static let snapshotLayerName = "DrawbridgePDFSnapshotLayerName"
    }

    private(set) var snapshotURL: URL?
    private var cachedPDFDocument: CGPDFDocument?
    var renderOpacity: CGFloat = 1.0
    var renderTintColor: NSColor?
    var renderTintStrength: CGFloat = 0.0
    var tintBlendStyle: TintBlendStyle = .screen
    var lineworkOnlyTint: Bool = true
    var snapshotLayerName: String?

    convenience init(bounds: NSRect, snapshotURL: URL) {
        self.init(bounds: bounds, snapshotURL: snapshotURL, contents: Self.contentsPrefix + snapshotURL.path)
    }

    override init(bounds: NSRect, forType annotationType: PDFAnnotationSubtype, withProperties properties: [AnyHashable : Any]? = nil) {
        super.init(bounds: bounds, forType: annotationType, withProperties: properties)
    }

    init(bounds: NSRect, snapshotURL: URL, contents: String) {
        self.snapshotURL = snapshotURL
        self.cachedPDFDocument = CGPDFDocument(snapshotURL as CFURL)
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        color = .clear
        shouldDisplay = true
        shouldPrint = true
        self.contents = contents
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        if coder.containsValue(forKey: CodingKeys.renderOpacity) {
            renderOpacity = CGFloat(coder.decodeDouble(forKey: CodingKeys.renderOpacity))
        }
        if coder.containsValue(forKey: CodingKeys.renderTintStrength) {
            renderTintStrength = CGFloat(coder.decodeDouble(forKey: CodingKeys.renderTintStrength))
        }
        if coder.containsValue(forKey: CodingKeys.tintBlendStyle) {
            let raw = coder.decodeInteger(forKey: CodingKeys.tintBlendStyle)
            tintBlendStyle = TintBlendStyle(rawValue: raw) ?? .screen
        }
        if coder.containsValue(forKey: CodingKeys.lineworkOnlyTint) {
            lineworkOnlyTint = coder.decodeBool(forKey: CodingKeys.lineworkOnlyTint)
        }
        if coder.containsValue(forKey: CodingKeys.snapshotLayerName) {
            snapshotLayerName = coder.decodeObject(forKey: CodingKeys.snapshotLayerName) as? String
        }
        if coder.containsValue(forKey: CodingKeys.renderTintRed),
           coder.containsValue(forKey: CodingKeys.renderTintGreen),
           coder.containsValue(forKey: CodingKeys.renderTintBlue),
           coder.containsValue(forKey: CodingKeys.renderTintAlpha) {
            let red = CGFloat(coder.decodeDouble(forKey: CodingKeys.renderTintRed))
            let green = CGFloat(coder.decodeDouble(forKey: CodingKeys.renderTintGreen))
            let blue = CGFloat(coder.decodeDouble(forKey: CodingKeys.renderTintBlue))
            let alpha = CGFloat(coder.decodeDouble(forKey: CodingKeys.renderTintAlpha))
            renderTintColor = NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha)
        }
        refreshDocumentFromContents()
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(Double(renderOpacity), forKey: CodingKeys.renderOpacity)
        coder.encode(Double(renderTintStrength), forKey: CodingKeys.renderTintStrength)
        coder.encode(tintBlendStyle.rawValue, forKey: CodingKeys.tintBlendStyle)
        coder.encode(lineworkOnlyTint, forKey: CodingKeys.lineworkOnlyTint)
        coder.encode(snapshotLayerName, forKey: CodingKeys.snapshotLayerName)
        if let rgba = renderTintColor?.usingColorSpace(.deviceRGB) {
            coder.encode(Double(rgba.redComponent), forKey: CodingKeys.renderTintRed)
            coder.encode(Double(rgba.greenComponent), forKey: CodingKeys.renderTintGreen)
            coder.encode(Double(rgba.blueComponent), forKey: CodingKeys.renderTintBlue)
            coder.encode(Double(rgba.alphaComponent), forKey: CodingKeys.renderTintAlpha)
        }
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        if cachedPDFDocument == nil {
            refreshDocumentFromContents()
        }
        guard let pdf = cachedPDFDocument, let page = pdf.page(at: 1) else {
            super.draw(with: box, in: context)
            return
        }

        let mediaBox = page.getBoxRect(.mediaBox)
        guard mediaBox.width > 0.1, mediaBox.height > 0.1 else {
            super.draw(with: box, in: context)
            return
        }

        let opacity = max(0.0, min(1.0, renderOpacity))
        let strength = max(0.0, min(1.0, renderTintStrength))
        let tint = renderTintColor?.usingColorSpace(.deviceRGB)
        let useLineworkOnlyTint = lineworkOnlyTint && strength > 0.001 && tint != nil

        if !useLineworkOnlyTint {
            context.saveGState()
            context.setAlpha(opacity)
            context.translateBy(x: bounds.minX, y: bounds.minY)
            context.scaleBy(x: bounds.width / mediaBox.width, y: bounds.height / mediaBox.height)
            context.drawPDFPage(page)

            if let tint {
                switch tintBlendStyle {
                case .screen:
                    // Light-background plans: black linework shifts toward tint while white stays white.
                    context.setBlendMode(.screen)
                case .multiply:
                    // Dark-background plans: white linework shifts toward tint while black stays black.
                    context.setBlendMode(.multiply)
                }
                context.setFillColor(tint.withAlphaComponent(strength).cgColor)
                context.fill(CGRect(origin: .zero, size: mediaBox.size))
            }
            context.restoreGState()
            return
        }

        guard let tint else { return }
        // "Colorize" mode: preserve only dark vectors and map them directly to tint.
        drawLineworkOnlyTint(page: page, mediaBox: mediaBox, tint: tint, in: context)
    }

    private func drawLineworkOnlyTint(page: CGPDFPage, mediaBox: CGRect, tint: NSColor, in context: CGContext) {
        let ctm = context.ctm
        let xScale = max(1.0, abs(ctm.a))
        let yScale = max(1.0, abs(ctm.d))
        let pixelWidth = max(1, min(4096, Int((bounds.width * xScale).rounded(.up))))
        let pixelHeight = max(1, min(4096, Int((bounds.height * yScale).rounded(.up))))

        guard let grayContext = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return
        }
        grayContext.interpolationQuality = .high
        grayContext.setFillColor(gray: 1.0, alpha: 1.0)
        grayContext.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        grayContext.saveGState()
        grayContext.scaleBy(x: CGFloat(pixelWidth) / mediaBox.width, y: CGFloat(pixelHeight) / mediaBox.height)
        grayContext.drawPDFPage(page)
        grayContext.restoreGState()

        guard let grayImage = grayContext.makeImage(),
              let sourceData = grayImage.dataProvider?.data,
              let sourceBytes = CFDataGetBytePtr(sourceData) else {
            return
        }
        let sourceBytesPerRow = max(1, grayImage.bytesPerRow)
        let strength = max(0.0, min(1.0, renderTintStrength))
        let opacity = max(0.0, min(1.0, renderOpacity))
        let tintRGB = tint.usingColorSpace(.deviceRGB) ?? tint
        let tintRed = Double(tintRGB.redComponent)
        let tintGreen = Double(tintRGB.greenComponent)
        let tintBlue = Double(tintRGB.blueComponent)
        let tintAlpha = Double(tintRGB.alphaComponent)
        // Thresholds tuned for architectural drawings:
        // dark vectors are kept, white/light fills become transparent.
        let darkCutoff: Double = 0.45
        let minimumVisibleAlpha: Double = 0.005

        var rgbaBytes = Data(count: pixelWidth * pixelHeight * 4)
        rgbaBytes.withUnsafeMutableBytes { dstRaw in
            guard let dst = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<pixelHeight {
                let srcRow = y * sourceBytesPerRow
                let dstRow = y * pixelWidth * 4
                for x in 0..<pixelWidth {
                    let luminance = Double(sourceBytes[srcRow + x]) / 255.0
                    let darkness = max(0.0, min(1.0, (darkCutoff - luminance) / darkCutoff))
                    let alpha = darkness * Double(strength) * Double(opacity) * tintAlpha
                    let index = dstRow + (x * 4)
                    if alpha <= minimumVisibleAlpha {
                        dst[index] = 0
                        dst[index + 1] = 0
                        dst[index + 2] = 0
                        dst[index + 3] = 0
                        continue
                    }
                    let premultipliedRed = UInt8(max(0, min(255, Int((tintRed * alpha * 255.0).rounded()))))
                    let premultipliedGreen = UInt8(max(0, min(255, Int((tintGreen * alpha * 255.0).rounded()))))
                    let premultipliedBlue = UInt8(max(0, min(255, Int((tintBlue * alpha * 255.0).rounded()))))
                    let alphaByte = UInt8(max(0, min(255, Int((alpha * 255.0).rounded()))))
                    dst[index] = premultipliedRed
                    dst[index + 1] = premultipliedGreen
                    dst[index + 2] = premultipliedBlue
                    dst[index + 3] = alphaByte
                }
            }
        }

        let outputBytesPerRow = pixelWidth * 4
        guard let provider = CGDataProvider(data: rgbaBytes as CFData),
              let colorizedImage = CGImage(
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: outputBytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            return
        }

        context.saveGState()
        context.setBlendMode(.normal)
        context.interpolationQuality = .high
        context.draw(colorizedImage, in: bounds)
        context.restoreGState()
    }

    func refreshDocumentFromContents() {
        guard let contents, contents.hasPrefix(Self.contentsPrefix) else {
            snapshotURL = nil
            cachedPDFDocument = nil
            return
        }
        let path = String(contents.dropFirst(Self.contentsPrefix.count))
        let url = URL(fileURLWithPath: path)
        snapshotURL = url
        cachedPDFDocument = CGPDFDocument(url as CFURL)
    }
}
