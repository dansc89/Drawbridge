import AppKit

@MainActor
enum ToolbarIcons {
    /// Template C-clamp: fixed jaw, frame and screw pressing inward.
    static func compressionClamp() -> NSImage {
        if let existing = NSImage(named: "DrawbridgeCompressionClamp") { return existing }
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            NSColor.black.setStroke()
            let frame = NSBezierPath()
            frame.lineWidth = 2; frame.lineCapStyle = .round; frame.lineJoinStyle = .round
            frame.move(to: NSPoint(x: 17, y: 19))
            frame.line(to: NSPoint(x: 8, y: 19))
            frame.curve(to: NSPoint(x: 4, y: 15), controlPoint1: NSPoint(x: 5, y: 19), controlPoint2: NSPoint(x: 4, y: 18))
            frame.line(to: NSPoint(x: 4, y: 8))
            frame.curve(to: NSPoint(x: 8, y: 4), controlPoint1: NSPoint(x: 4, y: 5), controlPoint2: NSPoint(x: 5, y: 4))
            frame.line(to: NSPoint(x: 17, y: 4)); frame.stroke()
            let screw = NSBezierPath()
            screw.lineWidth = 1.8; screw.lineCapStyle = .round
            for (a, b) in [(NSPoint(x: 16, y: 1), NSPoint(x: 16, y: 12)), (NSPoint(x: 12, y: 12), NSPoint(x: 20, y: 12)), (NSPoint(x: 12, y: 1), NSPoint(x: 20, y: 1)), (NSPoint(x: 13, y: 17), NSPoint(x: 20, y: 17))] { screw.move(to: a); screw.line(to: b) }
            screw.stroke(); return true
        }
        image.isTemplate = true
        image.setName(NSImage.Name("DrawbridgeCompressionClamp"))
        return image
    }
}
