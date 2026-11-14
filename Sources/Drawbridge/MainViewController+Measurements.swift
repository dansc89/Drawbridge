import AppKit
import PDFKit

@MainActor
final class DrawingScaleForm: NSView {
    let preset = NSPopUpButton()
    let paper = NSTextField(string: "1/8")
    let real = NSTextField(string: "1")
    let pages = NSTextField(string: "1")
    let scope = NSPopUpButton()
    let currentPage: Int
    let pageCount: Int
    let document: PDFDocument
    let capturedPages: [PDFPage]
    let selectedPageIndices: [Int]
    // Reject any structural change: even Current/All/Custom must refer to the
    // sheets shown when the modal opened, never replacement sheets at old indices.
    func matches(_ document: PDFDocument) -> Bool {
        self.document === document && document.pageCount == capturedPages.count &&
            capturedPages.enumerated().allSatisfy { document.page(at: $0.offset) === $0.element }
    }
    var pageIndices: [Int]? {
        switch scope.indexOfSelectedItem {
        case 0: return [currentPage]
        case 1: return Array(0..<pageCount)
        case 2: return MeasurementGeometry.pages(pages.stringValue, count: pageCount)
        case 3: return selectedPageIndices.isEmpty ? nil : selectedPageIndices
        default: return nil
        }
    }
    let presets: [(String, DrawingScale)]
    init(presets: [(String, DrawingScale)], current: DrawingScale?, pageText: String, currentPage: Int, document: PDFDocument, selectedPageIndices: [Int], selectedRowCount: Int) {
        self.document = document
        self.capturedPages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        self.selectedPageIndices = selectedPageIndices
        self.presets = presets
        self.currentPage = currentPage; self.pageCount = document.pageCount
        super.init(frame: CGRect(x: 0, y: 0, width: 420, height: 195))
        preset.addItems(withTitles: presets.map(\.0) + ["Custom architectural scale…"])
        let selected = presets.firstIndex { $0.1 == current } ?? presets.firstIndex { abs($0.1.unitsPerPoint - (current?.unitsPerPoint ?? 1.0/9)) < max($0.1.unitsPerPoint, 1e-9) * 1e-6 && $0.1.unit == (current?.unit ?? "ft") }
        preset.selectItem(at: selected ?? presets.count)
        if let current, current.unit == "ft" { paper.stringValue = String(format: "%.8g", 1 / (72 * current.unitsPerPoint)) }
        scope.addItems(withTitles: ["Current page (\(currentPage + 1))", "All pages (1-\(pageCount))", "Custom range", "Selected Pages (\(selectedPageIndices.count))"])
        scope.autoenablesItems = false
        scope.item(at: 3)?.isEnabled = !selectedPageIndices.isEmpty
        scope.selectItem(at: selectedRowCount > 1 && !selectedPageIndices.isEmpty ? 3 : 0)
        scope.setAccessibilityLabel("Scale page scope")
        scope.target = self; scope.action = #selector(changed)
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
        let row = NSStackView(views: [NSTextField(labelWithString: "Apply to"), scope, pages]); row.spacing = 8
        let helper = NSTextField(wrappingLabelWithString: "Page numbers: 1, 3-6, 9. Use a known dimension to verify the sheet scale; resized drawings and details may use a different scale.")
        helper.font = .systemFont(ofSize: 11); helper.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [preset, custom, row, helper])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor), row.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        changed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { paper.isEnabled = preset.indexOfSelectedItem == presets.count; real.isEnabled = paper.isEnabled; pages.isEnabled = scope.indexOfSelectedItem == 2 }
    var scale: DrawingScale? {
        let index = preset.indexOfSelectedItem
        if presets.indices.contains(index) { return presets[index].1 }
        guard let inches = MeasurementParsing.parseArchitecturalInches(paper.stringValue), let feet = Double(real.stringValue) else { return nil }
        return DrawingScale.architectural(inches: inches, feet: feet, name: "\(paper.stringValue)\" = \(real.stringValue)'" )
    }
}

@MainActor
extension MainViewController {
    func makeDrawingScaleForm() -> DrawingScaleForm? {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return nil }
        let architectural = drawingScalePresets.compactMap { preset -> (String,DrawingScale)? in
            DrawingScale.architectural(inches: preset.drawingInches, feet: preset.realFeet, name: preset.label).map { (preset.label, $0) }
        }
        let metric = [20.0,50,100,200,500].compactMap { DrawingScale.metric(ratio: $0).map { ($0.name + " (metric)", $0) } }
        let current = document.index(for: page)
        guard current != NSNotFound else { return nil }
        // changeNavigationMode publishes the active tab through these scroll-view
        // visibility flags. Do not use firstResponder (a menu/toolbar changes it)
        // or isHiddenOrHasHiddenAncestor (the whole sidebar may be collapsed).
        let selected: [Int]
        let selectedRowCount: Int
        if pagesTableView.enclosingScrollView?.isHidden == false {
            selectedRowCount = pagesTableView.selectedRowIndexes.count
            selected = pagesTableView.selectedRowIndexes.filter { (0..<document.pageCount).contains($0) }
        } else if bookmarksOutlineView.enclosingScrollView?.isHidden == false {
            selectedRowCount = bookmarksOutlineView.selectedRowIndexes.count
            selected = Array(Set(bookmarksOutlineView.selectedRowIndexes.compactMap { row -> Int? in
                guard let outline = bookmarksOutlineView.item(atRow: row) as? PDFOutline,
                      let destination = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination,
                      let target = destination.page else { return nil }
                let index = document.index(for: target)
                guard index != NSNotFound, (0..<document.pageCount).contains(index),
                      document.page(at: index) === target else { return nil }
                // A destinationless group deliberately does not inherit a child's page.
                return index
            })).sorted()
        } else {
            selectedRowCount = 0
            selected = []
        }
        let numbers = selected.count > 1 ? selected.map { String($0+1) }.joined(separator: ", ") : String(current+1)
        return DrawingScaleForm(presets: architectural+metric, current: MeasurementMetadata.scale(on: page), pageText: numbers, currentPage: current, document: document, selectedPageIndices: selected, selectedRowCount: selectedRowCount)
    }
    @discardableResult
    func applyDrawingScaleForm(_ form: DrawingScaleForm) -> Bool {
        guard !isActiveReview, pdfView.rectangleMarkup.canEdit(), let document = pdfView.document,
              form.matches(document), let scale = form.scale, let indices = form.pageIndices,
              !indices.isEmpty, indices.allSatisfy({ form.capturedPages.indices.contains($0) }) else { return false }
        let pages = indices.map { form.capturedPages[$0] }
        guard pages.allSatisfy(MeasurementMetadata.supportedPage) else { return false }
        pdfView.rectangleMarkup.applyDrawingScale(scale, to: pages)
        refreshMeasurementScaleDisplay()
        return true
    }
    @objc func commandSetPageDrawingScale(_ sender: Any?) {
        guard !isActiveReview, pdfView.rectangleMarkup.canEdit(), let document = pdfView.document, pdfView.currentPage != nil else { beep(); return }
        pdfView.rectangleMarkup.finishTextEditing()
        pdfView.rectangleMarkup.cancelGesture()
        guard let form = makeDrawingScaleForm() else { return }
        let alert = NSAlert(); alert.messageText = "Set Drawing Scale"
        alert.informativeText = "Apply a scale to one or several sheets. Existing measurements on these pages will be recalculated."
        alert.accessoryView = form; alert.addButton(withTitle: "Apply Scale"); alert.addButton(withTitle: "Cancel")
        while alert.runModal() == .alertFirstButtonReturn {
            guard pdfView.document === document, form.matches(document), pdfView.rectangleMarkup.canEdit() else { return }
            guard form.scale != nil, let indices = form.pageIndices else {
                runAlert(title: "Check the scale and page numbers", informativeText: "Enter a positive scale and valid page numbers, such as 1, 3-6. No pages have been changed.", style: .warning)
                continue
            }
            let pages = indices.compactMap { document.page(at: $0) }
            guard pages.allSatisfy(MeasurementMetadata.supportedPage) else {
                runAlert(title: "Unsupported page units", informativeText: "One of these sheets uses non-standard PDF page units. Its scale cannot be set with this tool yet. No pages have been changed.", style: .warning)
                continue
            }
            _ = applyDrawingScaleForm(form)
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
        rectangleToolbar.scaleButton.isEnabled = !isActiveReview && pdfView.rectangleMarkup.canEdit()
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
        guard !isActiveReview, pdfView.rectangleMarkup.canEdit(), let page = pdfView.currentPage else { beep(); return }
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
        guard !isActiveReview, let document = pdfView.document, document.index(for: page) != NSNotFound, pdfView.rectangleMarkup.canEdit() else { return }
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
