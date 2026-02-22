import AppKit

@MainActor
extension MainViewController {
    func installScrollMonitorIfNeeded() {
        guard scrollEventMonitor == nil else { return }
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            guard self.view.window?.isKeyWindow == true else { return event }
            guard self.pdfView.document != nil else { return event }

            let point = self.pdfView.convert(event.locationInWindow, from: nil)
            guard self.pdfView.bounds.contains(point) else { return event }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.control) {
                // CAD-style fallback: hold Control and wheel to move page-by-page.
                if event.scrollingDeltaY > 0 {
                    self.commandPreviousPage(nil)
                } else if event.scrollingDeltaY < 0 {
                    self.commandNextPage(nil)
                }
                self.lastUserInteractionAt = Date()
                return nil
            }

            self.pdfView.handleWheelZoom(event)
            self.lastUserInteractionAt = Date()
            return nil
        }
    }

    func installKeyMonitorIfNeeded() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.routeKeyDownEvent(event)
        }
    }

    func routeKeyDownEvent(_ event: NSEvent) -> NSEvent? {
        guard view.window?.isKeyWindow == true else { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            lastUserInteractionAt = Date()
            if view.window?.firstResponder is NSTextView || view.window?.firstResponder is NSTextField {
                return event
            }
            commandSelectAll(nil)
            return nil
        }
        if event.keyCode == 48 {
            if modifiers == [.control] {
                lastUserInteractionAt = Date()
                commandCycleNextDocument(nil)
                return nil
            }
            if modifiers == [.control, .shift] {
                lastUserInteractionAt = Date()
                commandCyclePreviousDocument(nil)
                return nil
            }
        }
        if modifiers == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            lastUserInteractionAt = Date()
            pasteGrabSnapshotInPlace()
            return nil
        }
        if modifiers == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            lastUserInteractionAt = Date()
            commandCloseDocument(nil)
            return nil
        }

        if modifiers.isDisjoint(with: [.command, .option, .control]) {
            if view.window?.firstResponder is NSTextView || view.window?.firstResponder is NSTextField {
                return event
            }
            switch event.keyCode {
            case 123, 126: // Left / Up
                lastUserInteractionAt = Date()
                commandPreviousPage(nil)
                return nil
            case 124, 125: // Right / Down
                lastUserInteractionAt = Date()
                commandNextPage(nil)
                return nil
            default:
                break
            }
        }

        let forbidden: NSEvent.ModifierFlags = [.command, .option, .control]
        guard modifiers.isDisjoint(with: forbidden) else {
            return event
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            lastUserInteractionAt = Date()
            if view.window?.firstResponder is NSTextView || view.window?.firstResponder is NSTextField {
                return event
            }
            deleteSelectedMarkup()
            return nil
        }

        if view.window?.firstResponder is NSTextView || view.window?.firstResponder is NSTextField {
            return event
        }

        if event.keyCode == 53 {
            lastUserInteractionAt = Date()
            handleEscapePress()
            return nil
        }

        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
        switch key {
        case "v":
            lastUserInteractionAt = Date()
            setTool(.select)
            return nil
        case "g":
            lastUserInteractionAt = Date()
            setTool(.grab)
            return nil
        case "d":
            lastUserInteractionAt = Date()
            setTool(.pen)
            return nil
        case "a":
            lastUserInteractionAt = Date()
            if event.modifierFlags.contains(.shift) {
                setTool(.area)
            } else {
                setTool(.arrow)
            }
            return nil
        case "l":
            lastUserInteractionAt = Date()
            setTool(.line)
            return nil
        case "p":
            lastUserInteractionAt = Date()
            setTool(.polyline)
            return nil
        case "h":
            lastUserInteractionAt = Date()
            setTool(.highlighter)
            return nil
        case "c":
            lastUserInteractionAt = Date()
            setTool(.cloud)
            return nil
        case "r":
            lastUserInteractionAt = Date()
            setTool(.rectangle)
            return nil
        case "t":
            lastUserInteractionAt = Date()
            setTool(.text)
            return nil
        case "q":
            lastUserInteractionAt = Date()
            setTool(.callout)
            return nil
        case "m":
            lastUserInteractionAt = Date()
            setTool(.measure)
            return nil
        case "k":
            lastUserInteractionAt = Date()
            setTool(.calibrate)
            return nil
        default:
            return event
        }
    }

    func handleEscapePress() {
        let now = Date()
        if now.timeIntervalSince(lastEscapePressAt) <= 0.65 {
            pdfView.cancelPendingMeasurement()
            pdfView.cancelPendingCallout()
            pdfView.cancelPendingPolyline()
            pdfView.cancelPendingArrow()
            pdfView.cancelPendingArea()
            if pdfView.toolMode != .select {
                setTool(.select)
            }
            clearMarkupSelection()
            lastEscapePressAt = .distantPast
        } else {
            lastEscapePressAt = now
        }
    }
}
