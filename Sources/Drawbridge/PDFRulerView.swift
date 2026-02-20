import AppKit
import PDFKit

final class PDFRulerView: NSView {
    enum Orientation {
        case horizontal
        case vertical
    }

    private let orientation: Orientation
    weak var pdfView: PDFView?
    var pointsPerUnit: CGFloat = 72.0
    var unitSuffix: String = "\""

    init(orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()

        guard let pdfView,
              let page = pdfView.currentPage else {
            return
        }

        let pageBounds = page.bounds(for: .cropBox)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        if orientation == .horizontal {
            NSColor.separatorColor.setStroke()
            let border = NSBezierPath()
            border.move(to: NSPoint(x: bounds.minX, y: 0.5))
            border.line(to: NSPoint(x: bounds.maxX, y: 0.5))
            border.lineWidth = 1
            border.stroke()

            let centerInPage = pdfView.convert(NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY), to: page)
            let leftInPage = pdfView.convert(NSPoint(x: 0, y: pdfView.bounds.midY), to: page)
            let rightInPage = pdfView.convert(NSPoint(x: pdfView.bounds.maxX, y: pdfView.bounds.midY), to: page)
            let visibleMinX = min(leftInPage.x, rightInPage.x)
            let visibleMaxX = max(leftInPage.x, rightInPage.x)
            let startUnit = Int(floor((visibleMinX - pageBounds.minX) / pointsPerUnit)) - 1
            let endUnit = Int(ceil((visibleMaxX - pageBounds.minX) / pointsPerUnit)) + 1
            let totalUnits = Int(ceil(pageBounds.width / pointsPerUnit))
            for unit in max(0, startUnit)...min(totalUnits, max(0, endUnit)) {
                let xInPage = pageBounds.minX + CGFloat(unit) * pointsPerUnit
                let inPDFView = pdfView.convert(NSPoint(x: xInPage, y: centerInPage.y), from: page)
                let xInView = convert(inPDFView, from: pdfView).x

                let isMajor = (unit % 6 == 0) || unit == totalUnits || unit == 0
                let tickHeight: CGFloat = isMajor ? 11 : 7
                NSColor.tertiaryLabelColor.setStroke()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: xInView, y: bounds.maxY))
                tick.line(to: NSPoint(x: xInView, y: bounds.maxY - tickHeight))
                tick.lineWidth = 1
                tick.stroke()

                if isMajor {
                    let label = "\(unit)\(unitSuffix)"
                    label.draw(at: NSPoint(x: xInView + 2, y: 2), withAttributes: labelAttrs)
                }
            }
        } else {
            NSColor.separatorColor.setStroke()
            let border = NSBezierPath()
            border.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
            border.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
            border.lineWidth = 1
            border.stroke()

            let centerInPage = pdfView.convert(NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY), to: page)
            let topInPage = pdfView.convert(NSPoint(x: pdfView.bounds.midX, y: 0), to: page)
            let bottomInPage = pdfView.convert(NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.maxY), to: page)
            let visibleMinY = min(topInPage.y, bottomInPage.y)
            let visibleMaxY = max(topInPage.y, bottomInPage.y)
            let startUnit = Int(floor((visibleMinY - pageBounds.minY) / pointsPerUnit)) - 1
            let endUnit = Int(ceil((visibleMaxY - pageBounds.minY) / pointsPerUnit)) + 1
            let totalUnits = Int(ceil(pageBounds.height / pointsPerUnit))
            for unit in max(0, startUnit)...min(totalUnits, max(0, endUnit)) {
                let yInPage = pageBounds.minY + CGFloat(unit) * pointsPerUnit
                let inPDFView = pdfView.convert(NSPoint(x: centerInPage.x, y: yInPage), from: page)
                let yInView = convert(inPDFView, from: pdfView).y

                let isMajor = (unit % 6 == 0) || unit == totalUnits || unit == 0
                let tickWidth: CGFloat = isMajor ? 11 : 7
                NSColor.tertiaryLabelColor.setStroke()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: bounds.maxX, y: yInView))
                tick.line(to: NSPoint(x: bounds.maxX - tickWidth, y: yInView))
                tick.lineWidth = 1
                tick.stroke()

                if isMajor {
                    let label = "\(unit)\(unitSuffix)"
                    label.draw(at: NSPoint(x: 2, y: yInView + 2), withAttributes: labelAttrs)
                }
            }
        }
    }
}
