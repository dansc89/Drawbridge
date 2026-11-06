import AppKit

/// A click retracts/reveals; movement beyond the threshold is exclusively a
/// resize. Track maximum movement, so a drag back to its origin never clicks.
@MainActor
final class SidebarDividerView: NSView {
    var onToggle: (() -> Void)?
    var onResizeStart: (() -> Void)?
    var onResize: ((CGFloat) -> Void)?
    var collapsed = false { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var leadingSide = true
    var horizontal = false
    private var downPoint: NSPoint?
    private var dragged = false
    private var hovered = false
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: collapsed ? .pointingHand : (horizontal ? .resizeUpDown : .resizeLeftRight))
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow; dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let downPoint else { return }
        let dx = event.locationInWindow.x - downPoint.x
        let dy = event.locationInWindow.y - downPoint.y
        let delta = horizontal ? dy : dx
        if !dragged, hypot(dx, dy) >= 4 {
            dragged = true; onResizeStart?()
        }
        if dragged { onResize?(delta) }
    }
    override func mouseUp(with event: NSEvent) {
        guard let downPoint else { return }
        let moved = hypot(event.locationInWindow.x - downPoint.x, event.locationInWindow.y - downPoint.y)
        let click = !dragged && moved < 4 && bounds.contains(convert(event.locationInWindow, from: nil))
        self.downPoint = nil; dragged = false
        if click { onToggle?() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { onToggle?() }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { onToggle?(); return onToggle != nil }
    override func draw(_ dirtyRect: NSRect) {
        (hovered ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.separatorColor.withAlphaComponent(0.15)).setFill()
        bounds.fill()
        let pointsLeft = leadingSide != collapsed
        let x = bounds.midX, y = bounds.midY
        let path = NSBezierPath(); path.lineWidth = 1.6; path.lineCapStyle = .round; path.lineJoinStyle = .round
        if horizontal {
            path.move(to: NSPoint(x: x - 5, y: y + (pointsLeft ? 2 : -2)))
            path.line(to: NSPoint(x: x, y: y + (pointsLeft ? -2 : 2)))
            path.line(to: NSPoint(x: x + 5, y: y + (pointsLeft ? 2 : -2)))
        } else {
            path.move(to: NSPoint(x: x + (pointsLeft ? 2 : -2), y: y - 5))
            path.line(to: NSPoint(x: x + (pointsLeft ? -2 : 2), y: y))
            path.line(to: NSPoint(x: x + (pointsLeft ? 2 : -2), y: y + 5))
        }
        (hovered ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setStroke(); path.stroke()
    }
}
