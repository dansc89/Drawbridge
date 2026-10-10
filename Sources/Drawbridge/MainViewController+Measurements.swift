import AppKit
import PDFKit

@MainActor
private final class DrawingScaleForm: NSView {
    let preset = NSPopUpButton()
    let paper = NSTextField(string: "1/8")
    let real = NSTextField(string: "1")
    let pages = NSTextField(string: "1")
    let presets: [(String, DrawingScale)]
    init(presets: [(String, DrawingScale)], current: DrawingScale?, pageText: String) {
        self.presets = presets
        super.init(frame: CGRect(x: 0, y: 0, width: 420, height: 155))
        preset.addItems(withTitles: presets.map(\.0) + ["Custom architectural scale…"])
        let selected = presets.firstIndex { $0.1 == current } ?? presets.firstIndex { abs($0.1.unitsPerPoint - (current?.unitsPerPoint ?? 1.0/9)) < 1e-9 && $0.1.unit == (current?.unit ?? "ft") }
        preset.selectItem(at: selected ?? presets.count)
        if let current, current.unit == "ft" { paper.stringValue = String(format: "%.8g", 1 / (72 * current.unitsPerPoint)) }
        pages.stringValue = pageText
        pages.setAccessibilityLabel("Pages to apply scale to")
        paper.setAccessibilityLabel("Drawing inches")
        real.setAccessibilityLabel("Real feet")
        preset.setAccessibilityLabel("Drawing scale preset")
        preset.target = self; preset.action = #selector(changed)
        let custom = NSStackView(views: [NSTextField(labelWithString: "Paper"), paper, NSTextField(labelWithString: "inches ="), real, NSTextField(labelWithString: "feet")])
        custom.spacing = 6
        paper.widthAnchor.constraint(equalToConstant: 75).isActive = true
        real.widthAnchor.constraint(equalToConstant: 75).isActive = true
        let row = NSStackView(views: [NSTextField(labelWithString: "Apply to pages"), pages]); row.spacing = 8
        let helper = NSTextField(wrappingLabelWithString: "Page numbers: 1, 3-6, 9. Use a known dimension to verify the sheet scale; resized drawings and details may use a different scale.")
        helper.font = .systemFont(ofSize: 11); helper.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [preset, custom, row, helper])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor), row.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        changed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { paper.isEnabled = preset.indexOfSelectedItem == presets.count; real.isEnabled = paper.isEnabled }
    var scale: DrawingScale? {
        let index = preset.indexOfSelectedItem
        if presets.indices.contains(index) { return presets[index].1 }
        guard let inches = MeasurementParsing.parseArchitecturalInches(paper.stringValue), let feet = Double(real.stringValue) else { return nil }
        return DrawingScale.architectural(inches: inches, feet: feet, name: "\(paper.stringValue)\" = \(real.stringValue)'" )
    }
}

@MainActor
extension MainViewController {
    @objc func commandSetPageDrawingScale(_ sender: Any?) {
        guard pdfView.rectangleMarkup.canEdit(), let document = pdfView.document, let page = pdfView.currentPage else { beep(); return }
        pdfView.rectangleMarkup.finishTextEditing()
        pdfView.rectangleMarkup.cancelGesture()
        let architectural = drawingScalePresets.compactMap { preset -> (String,DrawingScale)? in
            DrawingScale.architectural(inches: preset.drawingInches, feet: preset.realFeet, name: preset.label).map { (preset.label, $0) }
        }
        let metric = [20.0,50,100,200,500].compactMap { DrawingScale.metric(ratio: $0).map { ($0.name + " (metric)", $0) } }
        let current = document.index(for: page)
        let selected = pagesTableView.selectedRowIndexes
        let numbers = selected.count > 1 ? selected.map { String($0+1) }.joined(separator: ", ") : String(current+1)
        let form = DrawingScaleForm(presets: architectural+metric, current: MeasurementMetadata.scale(on: page), pageText: numbers)
        let alert = NSAlert(); alert.messageText = "Set Drawing Scale"
        alert.informativeText = "Apply a scale to one or several sheets. Existing measurements on these pages will be recalculated."
        alert.accessoryView = form; alert.addButton(withTitle: "Apply Scale"); alert.addButton(withTitle: "Cancel")
        while alert.runModal() == .alertFirstButtonReturn {
            guard pdfView.document === document else { return }
            guard let scale = form.scale, let indices = MeasurementGeometry.pages(form.pages.stringValue, count: document.pageCount) else {
                runAlert(title: "Check the scale and page numbers", informativeText: "Enter a positive scale and valid page numbers, such as 1, 3-6. No pages have been changed.", style: .warning)
                continue
            }
            let pages = indices.compactMap { document.page(at: $0) }
            guard pages.allSatisfy(MeasurementMetadata.supportedPage) else {
                runAlert(title: "Unsupported page units", informativeText: "One of these sheets uses non-standard PDF page units. Its scale cannot be set with this tool yet. No pages have been changed.", style: .warning)
                continue
            }
            pdfView.rectangleMarkup.applyDrawingScale(scale, to: pages)
            refreshMeasurementScaleDisplay()
            return
        }
    }
    @objc func areaMeasure(_ sender: Any?) { chooseMeasurementTool(.area) }
    @objc func perimeterMeasure(_ sender: Any?) { chooseMeasurementTool(.perimeter) }
    private func chooseMeasurementTool(_ tool: RectangleMarkupController.Tool) {
        guard pdfView.rectangleMarkup.canEdit(), let page = pdfView.currentPage else { beep(); return }
        if MeasurementMetadata.scale(on: page) == nil { commandSetPageDrawingScale(nil) }
        guard MeasurementMetadata.scale(on: page) != nil else { return }
        pdfView.rectangleMarkup.tool = tool
        view.window?.makeFirstResponder(pdfView)
    }
    func refreshMeasurementScaleDisplay() {
        let scale = pdfView.currentPage.flatMap(MeasurementMetadata.scale)
        rectangleToolbar.scaleButton.title = pdfView.rectangleMarkup.tool == .calibrate ? "Pick endpoints…" : (scale?.name ?? "Scale…")
        rectangleToolbar.scaleButton.toolTip = scale.map { "Current sheet: \($0.name). Set scale for one or several pages." } ?? "Set a drawing scale for one or several pages"
        rectangleToolbar.scaleButton.isEnabled = pdfView.rectangleMarkup.canEdit()
    }
}

@MainActor
private final class CalibrationForm: NSView {
    let distance = NSTextField(string: "")
    let unit = NSPopUpButton()
    let pages = NSTextField(string: "")
    init(pageText: String, preferredUnit: String) {
        super.init(frame: CGRect(x: 0, y: 0, width: 420, height: 120))
        unit.addItems(withTitles: ["Feet", "Meters"]); unit.selectItem(at: preferredUnit == "m" ? 1 : 0)
        pages.stringValue = pageText
        distance.placeholderString = "20 or 20' 6\""
        distance.setAccessibilityLabel("Known distance")
        unit.setAccessibilityLabel("Calibration units")
        pages.setAccessibilityLabel("Pages to calibrate")
        let dimension = NSStackView(views: [NSTextField(labelWithString: "Known distance"), distance, unit]); dimension.spacing = 8
        let pageRow = NSStackView(views: [NSTextField(labelWithString: "Apply to pages"), pages]); pageRow.spacing = 8
        let helper = NSTextField(wrappingLabelWithString: "Use the same calibration only for pages printed at the same scale and size. Feet accept decimals or feet and inches, such as 20' 6\" or 20' 6 1/2\". Meters accept decimals.")
        helper.font = .systemFont(ofSize: 11); helper.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [dimension, pageRow, helper]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor), dimension.widthAnchor.constraint(equalTo: stack.widthAnchor), pageRow.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    }
    var selectedUnit: String { unit.indexOfSelectedItem == 1 ? "m" : "ft" }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
extension MainViewController {
    @objc func commandCalibrateDrawingScale(_ sender: Any?) {
        guard pdfView.rectangleMarkup.canEdit(), let page = pdfView.currentPage else { beep(); return }
        guard MeasurementMetadata.supportedPage(page) else {
            runAlert(title: "Unsupported page units", informativeText: "This page uses non-standard PDF units. Calibration is not available for it yet.", style: .warning); return
        }
        let alert = NSAlert(); alert.messageText = "Calibrate Drawing Scale"
        alert.informativeText = "Click the two ends of a known dimension on the drawing, then enter its real distance. Zoom in for accurate endpoints. Hold Shift to constrain the line; Escape cancels."
        alert.addButton(withTitle: "Pick Endpoints"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        pdfView.rectangleMarkup.tool = .calibrate
        view.window?.makeFirstResponder(pdfView)
    }
    func completeDrawingCalibration(on page: PDFPage, start: CGPoint, end: CGPoint) {
        guard let document = pdfView.document, document.index(for: page) != NSNotFound, pdfView.rectangleMarkup.canEdit() else { return }
        let selection = pagesTableView.selectedRowIndexes
        let numbers = selection.count > 1 ? selection.map { String($0+1) }.joined(separator: ", ") : String(document.index(for: page)+1)
        let form = CalibrationForm(pageText: numbers, preferredUnit: MeasurementMetadata.scale(on: page)?.unit ?? "ft")
        let alert = NSAlert(); alert.messageText = "Enter the Known Distance"
        alert.informativeText = "Existing measurements on the selected pages will be recalculated. Calibration changes the measurement scale, not the PDF's page size."
        alert.accessoryView = form; alert.addButton(withTitle: "Apply Calibration"); alert.addButton(withTitle: "Cancel")
        while alert.runModal() == .alertFirstButtonReturn {
            guard pdfView.document === document, pdfView.rectangleMarkup.canEdit() else { return }
            guard let distance = CalibrationDistance.parse(form.distance.stringValue, unit: form.selectedUnit),
                  let scale = DrawingScale.calibrated(from: start, to: end, distance: distance, unit: form.selectedUnit),
                  let indices = MeasurementGeometry.pages(form.pages.stringValue, count: document.pageCount) else {
                runAlert(title: "Check the distance and pages", informativeText: "Enter a positive distance and valid PDF page numbers. No pages have been changed.", style: .warning); continue
            }
            let pages = indices.compactMap { document.page(at: $0) }
            guard pages.allSatisfy(MeasurementMetadata.supportedPage) else {
                runAlert(title: "Unsupported page units", informativeText: "One selected page uses non-standard PDF units. No pages have been changed.", style: .warning); continue
            }
            pdfView.rectangleMarkup.applyDrawingScale(scale, to: pages)
            refreshMeasurementScaleDisplay(); view.window?.makeFirstResponder(pdfView)
            return
        }
    }
}
