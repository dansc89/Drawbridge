import AppKit

/// Original folded-document / upload / tray geometry, not a stock symbol or raster asset.
/// Template alpha lets AppKit supply the correct enabled/disabled light/dark tint.
enum ReviewUploadIcon {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            NSColor.black.setStroke()
            let outline = NSBezierPath()
            outline.move(to: NSPoint(x: 14, y: 22))
            outline.line(to: NSPoint(x: 6, y: 22))
            outline.curve(to: NSPoint(x: 4, y: 20), controlPoint1: NSPoint(x: 4.9, y: 22), controlPoint2: NSPoint(x: 4, y: 21.1))
            outline.line(to: NSPoint(x: 4, y: 4))
            outline.curve(to: NSPoint(x: 6, y: 2), controlPoint1: NSPoint(x: 4, y: 2.9), controlPoint2: NSPoint(x: 4.9, y: 2))
            outline.line(to: NSPoint(x: 18, y: 2))
            outline.curve(to: NSPoint(x: 20, y: 4), controlPoint1: NSPoint(x: 19.1, y: 2), controlPoint2: NSPoint(x: 20, y: 2.9))
            outline.line(to: NSPoint(x: 20, y: 16))
            outline.close()
            let fold = NSBezierPath()
            fold.move(to: NSPoint(x: 14, y: 22))
            fold.line(to: NSPoint(x: 14, y: 18))
            fold.curve(to: NSPoint(x: 16, y: 16), controlPoint1: NSPoint(x: 14, y: 16.9), controlPoint2: NSPoint(x: 14.9, y: 16))
            fold.line(to: NSPoint(x: 20, y: 16))
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 12, y: 8.5))
            arrow.line(to: NSPoint(x: 12, y: 14))
            arrow.move(to: NSPoint(x: 9.5, y: 11.5))
            arrow.line(to: NSPoint(x: 12, y: 14))
            arrow.line(to: NSPoint(x: 14.5, y: 11.5))
            let tray = NSBezierPath()
            tray.move(to: NSPoint(x: 8, y: 7.5))
            tray.line(to: NSPoint(x: 8, y: 5.5))
            tray.line(to: NSPoint(x: 16, y: 5.5))
            tray.line(to: NSPoint(x: 16, y: 7.5))
            for path in [outline, fold, arrow, tray] {
                path.lineWidth = 1.6
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Upload PDFs"
        return image
    }
}
