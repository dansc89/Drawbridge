import AppKit

@MainActor
extension MainViewController {
    @discardableResult
    func guardOrBeep(_ condition: @autoclosure () -> Bool) -> Bool {
        guard condition() else {
            NSSound.beep()
            return false
        }
        return true
    }

    func beep() {
        NSSound.beep()
    }

    @discardableResult
    func runAlert(
        title: String,
        informativeText: String? = nil,
        style: NSAlert.Style = .informational,
        buttons: [String] = ["OK"],
        accessoryView: NSView? = nil,
        activateApp: Bool = false
    ) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        if let informativeText {
            alert.informativeText = informativeText
        }
        alert.alertStyle = style
        if let accessoryView {
            alert.accessoryView = accessoryView
        }
        for button in buttons {
            alert.addButton(withTitle: button)
        }
        if activateApp {
            NSApp.activate(ignoringOtherApps: true)
        }
        return alert.runModal()
    }
}
