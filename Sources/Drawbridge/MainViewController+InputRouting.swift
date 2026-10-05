import AppKit

@MainActor
extension MainViewController {
    func hasEditablePolygonSelection() -> Bool {
        return false
    }

    func setPolygonVertexEditMode(_ enabled: Bool) {
        isPolygonVertexEditModeEnabled = enabled
        pdfView.polygonVertexEditModeEnabled = enabled
        updateStatusBar()
    }

    func cancelPendingMarkupInteractions(except preservedMode: ToolMode? = nil) {
        pdfView.cancelPendingMeasurement()
        pdfView.cancelPendingCallout()
        pdfView.cancelPendingPolyline()
        pdfView.cancelPendingPolygon()
        pdfView.cancelPendingArrow()
        pdfView.cancelPendingLine()
        pdfView.cancelPendingArea()
        pdfView.cancelPendingCircle()
    }

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

        let optionNavigationModifiersAllowed =
            modifiers.contains(.option) &&
            modifiers.isDisjoint(with: [.command, .control, .shift])
        if optionNavigationModifiersAllowed {
            switch event.keyCode {
            case 123: // Option + Left
                lastUserInteractionAt = Date()
                commandNavigateBack(nil)
                return nil
            case 124: // Option + Right
                lastUserInteractionAt = Date()
                commandNavigateForward(nil)
                return nil
            default:
                break
            }
        }

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
            // Keep paste shortcuts available to text fields, never the PDF canvas.
            if view.window?.firstResponder is NSTextView || view.window?.firstResponder is NSTextField {
                return event
            }
            return nil
        }
        if modifiers == [.command, .shift],
           (view.window?.firstResponder is NSTextView) == false,
           (view.window?.firstResponder is NSTextField) == false,
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            lastUserInteractionAt = Date()
            commandAutoGenerateSheetNames(nil)
            return nil
        }
        if modifiers == [.command, .shift],
           (view.window?.firstResponder is NSTextView) == false,
           (view.window?.firstResponder is NSTextField) == false,
           event.charactersIgnoringModifiers?.lowercased() == "h" {
            lastUserInteractionAt = Date()
            commandBatchLinkSheetNumbers(nil)
            return nil
        }
        if modifiers == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            lastUserInteractionAt = Date()
            commandCloseDocument(nil)
            return nil
        }

        if modifiers == [.command, .shift],
           (view.window?.firstResponder is NSTextView) == false,
           (view.window?.firstResponder is NSTextField) == false,
           let action = shortcutAction(for: event),
           performShortcutAction(action) {
            lastUserInteractionAt = Date()
            return nil
        }

        if modifiers.isDisjoint(with: [.command, .option, .control]) {
            if view.window?.firstResponder is NSTextView || view.window?.firstResponder is NSTextField {
                return event
            }
            if pdfView.rectangleMarkup.handleToolShortcut(event) {
                view.window?.makeFirstResponder(pdfView)
                return nil
            }
            if [36,76].contains(event.keyCode), pdfView.rectangleMarkup.finishPolyline() { return nil }
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

        if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z",
           view.window?.firstResponder === pdfView {
            if modifiers.contains(.shift) { rectangleRedo(nil) } else { rectangleUndo(nil) }
            return nil
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
            if view.window?.firstResponder === bookmarksOutlineView {
                deleteBookmarkFromSidebar()
                return nil
            }
            if view.window?.firstResponder === pdfView { rectangleDelete(nil) }
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

        if let action = shortcutAction(for: event), performShortcutAction(action) {
            lastUserInteractionAt = Date()
            return nil
        }
        return event
    }

    func handleEscapePress() {
        pdfView.rectangleMarkup.escape()
        cancelPendingMarkupInteractions()
        if pdfView.toolMode != .select {
            setTool(.select)
            clearMarkupSelection()
            return
        }
        if currentSelectedMarkupItem() != nil {
            clearMarkupSelection()
        }
        escapePressTracker.reset()
    }
}
