import AppKit
import PDFKit

final class ImageMarkupAnnotation: PDFAnnotation {
    static let contentsPrefix = "DrawbridgeImagePath|"
    private enum CodingKeys {
        static let renderOpacity = "DrawbridgeImageRenderOpacity"
        static let renderTintRed = "DrawbridgeImageRenderTintRed"
        static let renderTintGreen = "DrawbridgeImageRenderTintGreen"
        static let renderTintBlue = "DrawbridgeImageRenderTintBlue"
        static let renderTintAlpha = "DrawbridgeImageRenderTintAlpha"
        static let renderTintStrength = "DrawbridgeImageRenderTintStrength"
    }

    private(set) var imageURL: URL?
    private var cachedImage: NSImage?
    var renderOpacity: CGFloat = 1.0
    var renderTintColor: NSColor?
    var renderTintStrength: CGFloat = 0.0

    convenience init(bounds: NSRect, imageURL: URL) {
        self.init(bounds: bounds, imageURL: imageURL, contents: Self.contentsPrefix + imageURL.path)
    }

    override init(bounds: NSRect, forType annotationType: PDFAnnotationSubtype, withProperties properties: [AnyHashable : Any]? = nil) {
        super.init(bounds: bounds, forType: annotationType, withProperties: properties)
    }

    init(bounds: NSRect, imageURL: URL, contents: String) {
        self.imageURL = imageURL
        self.cachedImage = NSImage(contentsOf: imageURL)
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
        refreshImageFromContents()
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(Double(renderOpacity), forKey: CodingKeys.renderOpacity)
        coder.encode(Double(renderTintStrength), forKey: CodingKeys.renderTintStrength)
        if let rgba = renderTintColor?.usingColorSpace(.deviceRGB) {
            coder.encode(Double(rgba.redComponent), forKey: CodingKeys.renderTintRed)
            coder.encode(Double(rgba.greenComponent), forKey: CodingKeys.renderTintGreen)
            coder.encode(Double(rgba.blueComponent), forKey: CodingKeys.renderTintBlue)
            coder.encode(Double(rgba.alphaComponent), forKey: CodingKeys.renderTintAlpha)
        }
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        if cachedImage == nil {
            refreshImageFromContents()
        }
        guard let image = cachedImage else {
            super.draw(with: box, in: context)
            return
        }
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.saveGState()
            context.interpolationQuality = .high
            context.setAlpha(max(0.0, min(1.0, renderOpacity)))
            context.draw(cg, in: bounds)
            if let tint = renderTintColor?.usingColorSpace(.deviceRGB) {
                let strength = max(0.0, min(1.0, renderTintStrength))
                if strength > 0.001 {
                    context.setBlendMode(.sourceAtop)
                    context.setFillColor(tint.withAlphaComponent(strength).cgColor)
                    context.fill(bounds)
                }
            }
            context.restoreGState()
            return
        }
        super.draw(with: box, in: context)
    }

    func refreshImageFromContents() {
        guard let contents, contents.hasPrefix(Self.contentsPrefix) else {
            imageURL = nil
            cachedImage = nil
            return
        }
        let path = String(contents.dropFirst(Self.contentsPrefix.count))
        let url = URL(fileURLWithPath: path)
        imageURL = url
        cachedImage = NSImage(contentsOf: url)
    }
}
