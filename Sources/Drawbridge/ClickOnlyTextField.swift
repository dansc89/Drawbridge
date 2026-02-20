import AppKit

final class ClickOnlyTextField: NSTextField {
    override var acceptsFirstResponder: Bool {
        false
    }
}
