import AppKit
import PDFKit

@MainActor
extension MainViewController {
    func currentMeasurementScaleState() -> PageScaleLock {
        let scale = max(0.0001, measurementScaleField.doubleValue > 0 ? measurementScaleField.doubleValue : 1.0)
        let unit = measurementUnitPopup.titleOfSelectedItem ?? pdfView.measurementUnitLabel
        return PageScaleLock(unit: unit, scale: scale)
    }

    private func applyMeasurementScaleState(_ state: PageScaleLock, updateControls: Bool, updateStatus: Bool) {
        let scale = max(0.0001, CGFloat(state.scale))
        let unit = state.unit
        let baseUnitsPerPoint = baseUnitsPerPoint(for: unit)
        pdfView.measurementUnitsPerPoint = baseUnitsPerPoint * scale
        pdfView.measurementUnitLabel = unit
        if updateControls {
            measurementUnitPopup.selectItem(withTitle: unit)
            measurementScaleField.stringValue = String(format: "%.6f", state.scale)
            synchronizeScalePresetSelection()
        }
        updateMeasurementSummary()
        if updateStatus {
            updateStatusBar()
        }
    }

    @objc func applyMeasurementScale() {
        applyMeasurementScaleState(currentMeasurementScaleState(), updateControls: true, updateStatus: true)
    }

    @objc func changeScalePreset() {
        let idx = max(0, scalePresetPopup.indexOfSelectedItem)
        let preset = drawingScalePresets[min(idx, drawingScalePresets.count - 1)]
        if preset.drawingInches < 0 {
            commandSetDrawingScale(nil)
            return
        }
        if preset.drawingInches == 0 || preset.realFeet == 0 {
            measurementUnitPopup.selectItem(withTitle: "ft")
            measurementScaleField.stringValue = "1.000000"
            applyMeasurementScale()
            return
        }
        guard preset.drawingInches > 0, preset.realFeet > 0 else {
            return
        }
        applyDrawingScale(drawingInches: preset.drawingInches, realFeet: preset.realFeet)
    }

    private func applyDrawingScale(drawingInches: Double, realFeet: Double) {
        let points = CGFloat(drawingInches * 72.0)
        guard points > 0, realFeet > 0 else { return }
        let unitsPerPoint = CGFloat(realFeet) / points
        let base = baseUnitsPerPoint(for: "ft")
        let scale = unitsPerPoint / base
        applyMeasurementScaleState(
            PageScaleLock(unit: "ft", scale: Double(scale)),
            updateControls: true,
            updateStatus: true
        )
    }

    @objc func commandSetDrawingScale(_ sender: Any?) {
        guard pdfView.document != nil else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Set Drawing Scale"
        alert.informativeText = "Architectural scale format. Example: 1/8\" = 1'-0\"."
        alert.alertStyle = .informational

        let drawingField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        drawingField.placeholderString = "1/8"
        drawingField.stringValue = "1/8"
        drawingField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        drawingField.alignment = .right
        drawingField.translatesAutoresizingMaskIntoConstraints = false
        drawingField.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let realFeetField = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        realFeetField.stringValue = "1"
        realFeetField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        realFeetField.alignment = .right
        realFeetField.translatesAutoresizingMaskIntoConstraints = false
        realFeetField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let realInchesField = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        realInchesField.stringValue = "0"
        realInchesField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        realInchesField.alignment = .right
        realInchesField.translatesAutoresizingMaskIntoConstraints = false
        realInchesField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let drawingLabel = NSTextField(labelWithString: "Drawing")
        drawingLabel.alignment = .right
        drawingLabel.setContentHuggingPriority(.required, for: .horizontal)
        let realLabel = NSTextField(labelWithString: "Real")
        realLabel.alignment = .right
        realLabel.setContentHuggingPriority(.required, for: .horizontal)

        let drawingInput = NSStackView(views: [drawingField, NSTextField(labelWithString: "\"")])
        drawingInput.orientation = .horizontal
        drawingInput.spacing = 6
        drawingInput.alignment = .centerY

        let realInput = NSStackView(views: [realFeetField, NSTextField(labelWithString: "ft"), realInchesField, NSTextField(labelWithString: "in")])
        realInput.orientation = .horizontal
        realInput.spacing = 6
        realInput.alignment = .centerY

        let grid = NSGridView(views: [
            [drawingLabel, drawingInput],
            [realLabel, realInput]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.xPlacement = .fill
        grid.yPlacement = .center
        grid.column(at: 0).xPlacement = .trailing

        let helperLabel = NSTextField(labelWithString: "Supported drawing values: decimal, fraction, or mixed (e.g. 0.125, 1/8, 1 1/2).")
        helperLabel.textColor = .secondaryLabelColor
        helperLabel.font = NSFont.systemFont(ofSize: 11)
        helperLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [grid, helperLabel])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 112))
        accessory.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: accessory.topAnchor),
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
        ])
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Apply Scale")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let drawingInches = parseArchitecturalInches(drawingField.stringValue),
              drawingInches > 0 else {
            NSSound.beep()
            return
        }
        let feet = max(0, realFeetField.doubleValue)
        let inches = max(0, realInchesField.doubleValue)
        let realFeet = feet + (inches / 12.0)
        guard realFeet > 0 else {
            NSSound.beep()
            return
        }

        applyDrawingScale(drawingInches: drawingInches, realFeet: realFeet)
        scalePresetPopup.selectItem(withTitle: "Custom…")
    }

    private func synchronizeScalePresetSelection() {
        let unit = measurementUnitPopup.titleOfSelectedItem ?? "pt"
        guard unit == "ft" else {
            scalePresetPopup.selectItem(withTitle: "Custom…")
            return
        }

        let scale = max(0.0001, measurementScaleField.doubleValue > 0 ? measurementScaleField.doubleValue : 1.0)
        let tolerance = 0.000001
        for preset in drawingScalePresets where preset.drawingInches > 0 && preset.realFeet > 0 {
            let expectedScale = preset.realFeet / (preset.drawingInches * 72.0) / Double(baseUnitsPerPoint(for: "ft"))
            if abs(expectedScale - scale) <= tolerance {
                scalePresetPopup.selectItem(withTitle: preset.label)
                return
            }
        }
        scalePresetPopup.selectItem(withTitle: "Custom…")
    }

    private func parseArchitecturalInches(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let decimal = Double(value) {
            return decimal
        }

        let parts = value.split(separator: " ")
        if parts.count == 2,
           let whole = Double(parts[0]),
           let fraction = parseFraction(parts[1]) {
            return whole + fraction
        }

        return parseFraction(Substring(value))
    }

    private func parseFraction(_ fraction: Substring) -> Double? {
        let items = fraction.split(separator: "/")
        guard items.count == 2,
              let numerator = Double(items[0]),
              let denominator = Double(items[1]),
              denominator != 0 else { return nil }
        return numerator / denominator
    }

    func baseUnitsPerPoint(for unit: String) -> CGFloat {
        switch unit {
        case "in":
            return 1.0 / 72.0
        case "ft":
            return 1.0 / 864.0
        case "m":
            return 0.0003527777778
        default:
            return 1.0
        }
    }

    func showCalibrationDialog(distanceInPoints: CGFloat) {
        pendingCalibrationDistanceInPoints = distanceInPoints

        let alert = NSAlert()
        alert.messageText = "Calibrate Measurement Scale"
        alert.informativeText = "Enter the real-world distance between the two calibration points."
        alert.alertStyle = .informational

        let knownDistanceField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        knownDistanceField.placeholderString = "Known distance"
        knownDistanceField.stringValue = "10"

        let unitPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 100, height: 24), pullsDown: false)
        unitPopup.addItems(withTitles: ["pt", "in", "ft", "m"])
        if let current = measurementUnitPopup.titleOfSelectedItem {
            unitPopup.selectItem(withTitle: current)
        } else {
            unitPopup.selectItem(withTitle: "ft")
        }

        let row = NSStackView(views: [NSTextField(labelWithString: "Distance:"), knownDistanceField, unitPopup])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        alert.accessoryView = row
        alert.addButton(withTitle: "Apply Calibration")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let knownDistance = CGFloat(knownDistanceField.doubleValue)
        let selectedUnit = unitPopup.titleOfSelectedItem ?? "ft"
        guard knownDistance > 0, let points = pendingCalibrationDistanceInPoints, points > 0 else {
            NSSound.beep()
            return
        }

        let unitsPerPoint = knownDistance / points
        let base = baseUnitsPerPoint(for: selectedUnit)
        let scale = unitsPerPoint / base

        applyMeasurementScaleState(
            PageScaleLock(unit: selectedUnit, scale: Double(scale)),
            updateControls: true,
            updateStatus: true
        )
        pendingCalibrationDistanceInPoints = nil
        setTool(.measure)
    }

    func applyScaleLockForCurrentPageIfNeeded() {
        guard let document = pdfView.document,
              let page = pdfView.currentPage else {
            lastScaleLockAppliedPageIndex = -1
            return
        }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return }
        guard pageIndex != lastScaleLockAppliedPageIndex else { return }
        lastScaleLockAppliedPageIndex = pageIndex
        guard let lock = pageScaleLocks[pageIndex] else { return }
        let current = currentMeasurementScaleState()
        let sameUnit = current.unit == lock.unit
        let sameScale = abs(current.scale - lock.scale) <= 0.000001
        guard !(sameUnit && sameScale) else { return }
        applyMeasurementScaleState(lock, updateControls: true, updateStatus: false)
    }

    @objc func commandLockScaleToPages(_ sender: Any?) {
        guard let document = pdfView.document else {
            NSSound.beep()
            return
        }
        let currentIndex = max(0, document.index(for: pdfView.currentPage ?? document.page(at: 0)!))
        let currentPageNumber = currentIndex + 1
        let currentScale = currentMeasurementScaleState()

        let alert = NSAlert()
        alert.messageText = "Lock Scale to Pages"
        alert.informativeText = "Apply current scale \(String(format: "%.6f", currentScale.scale)) \(currentScale.unit) to a page range."
        alert.alertStyle = .informational

        let startField = NSTextField(string: "\(currentPageNumber)")
        let endField = NSTextField(string: "\(currentPageNumber)")
        startField.alignment = .right
        endField.alignment = .right
        startField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        endField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        startField.translatesAutoresizingMaskIntoConstraints = false
        endField.translatesAutoresizingMaskIntoConstraints = false
        startField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        endField.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let row = NSStackView(views: [
            NSTextField(labelWithString: "Pages"),
            startField,
            NSTextField(labelWithString: "to"),
            endField,
            NSTextField(labelWithString: "(\(document.pageCount) total)")
        ])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY

        alert.accessoryView = row
        alert.addButton(withTitle: "Lock Scale")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let start = max(1, min(document.pageCount, startField.integerValue))
        let end = max(1, min(document.pageCount, endField.integerValue))
        let lower = min(start, end) - 1
        let upper = max(start, end) - 1
        guard lower <= upper else {
            NSSound.beep()
            return
        }

        for pageIndex in lower...upper {
            pageScaleLocks[pageIndex] = currentScale
        }
        lastScaleLockAppliedPageIndex = -1
        applyScaleLockForCurrentPageIfNeeded()
        markMarkupChanged()
        scheduleAutosave()
        updateStatusBar()
    }

    @objc func commandClearScaleLocks(_ sender: Any?) {
        guard let document = pdfView.document else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Clear Scale Locks"
        alert.informativeText = "Choose whether to clear all locked page scales, or only for a page range."
        alert.alertStyle = .informational

        let modePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 170, height: 24), pullsDown: false)
        modePopup.addItems(withTitles: ["All Pages", "Page Range"])
        modePopup.selectItem(at: 0)
        let startField = NSTextField(string: "1")
        let endField = NSTextField(string: "\(document.pageCount)")
        startField.alignment = .right
        endField.alignment = .right
        startField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        endField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        startField.translatesAutoresizingMaskIntoConstraints = false
        endField.translatesAutoresizingMaskIntoConstraints = false
        startField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        endField.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let row = NSStackView(views: [
            modePopup,
            NSTextField(labelWithString: "from"),
            startField,
            NSTextField(labelWithString: "to"),
            endField
        ])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        alert.accessoryView = row
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if modePopup.indexOfSelectedItem == 0 {
            pageScaleLocks.removeAll(keepingCapacity: false)
        } else {
            let start = max(1, min(document.pageCount, startField.integerValue))
            let end = max(1, min(document.pageCount, endField.integerValue))
            let lower = min(start, end) - 1
            let upper = max(start, end) - 1
            for pageIndex in lower...upper {
                pageScaleLocks.removeValue(forKey: pageIndex)
            }
        }
        lastScaleLockAppliedPageIndex = -1
        applyScaleLockForCurrentPageIfNeeded()
        markMarkupChanged()
        scheduleAutosave()
        updateStatusBar()
    }
}
