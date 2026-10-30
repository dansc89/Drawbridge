import AppKit

@MainActor
enum ToolbarIcons {
    /// Layers pressed together versus pulled apart; monochrome for every theme.
    static func markupLayers(expanding: Bool) -> NSImage {
        let name = NSImage.Name(expanding ? "DrawbridgeUnflattenLayers" : "DrawbridgeFlattenLayers")
        if let existing = NSImage(named: name) { return existing }
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            NSColor.black.setStroke()
            let sheets = NSBezierPath()
            sheets.lineWidth = 1.8
            sheets.lineCapStyle = .round; sheets.lineJoinStyle = .round
            // Nearly touching sheets for Flatten; a wide opening for Unflatten.
            for y: CGFloat in expanding ? [3, 21] : [10, 14] {
                sheets.move(to: NSPoint(x: 2, y: y))
                sheets.line(to: NSPoint(x: 12, y: y+2))
                sheets.line(to: NSPoint(x: 22, y: y))
                sheets.line(to: NSPoint(x: 12, y: y-2)); sheets.close()
            }
            sheets.stroke()
            NSColor.black.setFill()
            func arrow(tip: CGFloat, tail: CGFloat) {
                let direction: CGFloat = tip > tail ? 1 : -1
                let shoulder = tip - direction * 3.5
                let arrow = NSBezierPath()
                for (index, point) in [NSPoint(x:12,y:tip), NSPoint(x:8.5,y:shoulder),
                    NSPoint(x:10.75,y:shoulder), NSPoint(x:10.75,y:tail),
                    NSPoint(x:13.25,y:tail), NSPoint(x:13.25,y:shoulder),
                    NSPoint(x:15.5,y:shoulder)].enumerated() {
                    if index == 0 { arrow.move(to:point) } else { arrow.line(to:point) }
                }
                arrow.close(); arrow.fill()
            }
            if expanding {
                // Bold outward arrowheads occupy the opening between the sheets.
                arrow(tip:17.5,tail:12); arrow(tip:6.5,tail:12)
            } else {
                // Arrows sit outside the stack and visibly press toward its center.
                arrow(tip:17.5,tail:23.5); arrow(tip:6.5,tail:0.5)
            }
            return true
        }
        image.isTemplate = true; image.setName(name); return image
    }

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
