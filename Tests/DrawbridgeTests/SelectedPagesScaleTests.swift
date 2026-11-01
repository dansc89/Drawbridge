import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class SelectedPagesScaleTests: XCTestCase {
    private func fixture(_ body: (MainViewController, PDFDocument, NSSegmentedControl) throws -> Void) throws {
        _ = NSApplication.shared
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        for _ in 0..<6 { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("selected-scale-source-\(UUID()).pdf")
        try (data as Data).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        let controller = MainViewController()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.pdfView.setMarkupDocument(document)
        controller.pdfView.rectangleMarkup.canEdit = { true }
        controller.pdfView.go(to: document.page(at: 0)!)
        controller.pagesTableView.reloadData()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let tabs = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 2 && $0.label(forSegment: 0) == "Pages" })
        try body(controller, document, tabs)
        window.orderOut(nil)
        window.contentViewController = nil
    }
    private func switchTab(_ tab: Int, _ control: NSSegmentedControl) {
        control.selectedSegment = tab
        _ = control.sendAction(control.action, to: control.target)
    }
    private func selectedItem(_ form: DrawingScaleForm) throws -> NSMenuItem {
        try XCTUnwrap(form.scope.itemArray.first { $0.title.hasPrefix("Selected Pages") })
    }
    func testPagesSelectionDefaultsToExplicitScopeAndFreezesNoncontiguousSheets() throws {
        try fixture { c, d, tabs in
            switchTab(0, tabs)
            c.pagesTableView.selectRowIndexes(IndexSet([1, 4]), byExtendingSelection: false)
            let form = try XCTUnwrap(c.makeDrawingScaleForm())
            let item = try selectedItem(form)
            XCTAssertEqual(item.title, "Selected Pages (2)")
            XCTAssertTrue(form.scope.selectedItem === item)
            XCTAssertEqual(form.pageIndices, [1, 4])
            c.pagesTableView.selectRowIndexes(IndexSet([2, 3]), byExtendingSelection: false)
            let undo = c.pdfView.rectangleMarkup.undo
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            XCTAssertTrue(c.applyDrawingScaleForm(form))
            undo.endUndoGrouping()
            for i in 0..<6 { XCTAssertEqual(MeasurementMetadata.scale(on: d.page(at: i)!), [1, 4].contains(i) ? form.scale : nil) }
            XCTAssertTrue(undo.canUndo)
            undo.undo()
            for i in 0..<6 { XCTAssertNil(MeasurementMetadata.scale(on: d.page(at: i)!)) }
            undo.redo()
            for i in 0..<6 { XCTAssertEqual(MeasurementMetadata.scale(on: d.page(at: i)!), [1, 4].contains(i) ? form.scale : nil) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("selected-scale-\(UUID()).pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertTrue(PDFRectangleWriter.write(document: d, source: try XCTUnwrap(d.documentURL), destination: url, pageLabels: [:], records: RectangleMarkupRecord.capture(d)))
            let reopened = try XCTUnwrap(PDFDocument(url: url))
            for i in 0..<6 { XCTAssertEqual(MeasurementMetadata.scale(on: reopened.page(at: i)!), [1, 4].contains(i) ? form.scale : nil) }
        }
    }
    func testBookmarksResolveDestinationsDeduplicateAndIgnoreHiddenPagesSelection() throws {
        try fixture { c, d, tabs in
            switchTab(0, tabs)
            c.pagesTableView.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
            let root = PDFOutline()
            let foreign = PDFDocument(); foreign.insert(PDFPage(), at: 0)
            for (i, page) in [d.page(at: 5), d.page(at: 1), d.page(at: 5), nil, foreign.page(at: 0)].enumerated() {
                let node = PDFOutline(); node.label = "Target \(i)"
                if let page {
                    if i == 1 { node.action = PDFActionGoTo(destination: PDFDestination(page: page, at: .zero)) }
                    else { node.destination = PDFDestination(page: page, at: .zero) }
                }
                if i == 3 {
                    let child = PDFOutline(); child.destination = PDFDestination(page: d.page(at: 3)!, at: .zero); node.insertChild(child, at: 0)
                }
                root.insertChild(node, at: i)
            }
            d.outlineRoot = root; c.bookmarksOutlineView.reloadData()
            switchTab(1, tabs)
            c.bookmarksOutlineView.selectRowIndexes(IndexSet(integersIn: 0..<5), byExtendingSelection: false)
            _ = c.view.window?.makeFirstResponder(c.pdfView)
            let form = try XCTUnwrap(c.makeDrawingScaleForm())
            XCTAssertEqual(try selectedItem(form).title, "Selected Pages (2)")
            XCTAssertEqual(form.pageIndices, [1, 5])
            XCTAssertTrue(c.applyDrawingScaleForm(form))
            for i in 0..<6 { XCTAssertEqual(MeasurementMetadata.scale(on: d.page(at: i)!), [1, 5].contains(i) ? form.scale : nil) }
        }
    }
    func testDuplicateBookmarksDefaultToSelectedScopeEvenWhenOnlyOneUniquePage() throws {
        try fixture { c, d, tabs in
            let root = PDFOutline()
            for i in 0..<2 {
                let node = PDFOutline(); node.label = "Duplicate \(i)"
                node.destination = PDFDestination(page: d.page(at: 4)!, at: .zero)
                root.insertChild(node, at: i)
            }
            d.outlineRoot = root; c.bookmarksOutlineView.reloadData()
            switchTab(1, tabs)
            c.bookmarksOutlineView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
            let form = try XCTUnwrap(c.makeDrawingScaleForm())
            XCTAssertTrue(form.scope.selectedItem === (try selectedItem(form)))
            XCTAssertEqual(form.pageIndices, [4])
            XCTAssertTrue(c.applyDrawingScaleForm(form))
            for i in 0..<6 { XCTAssertEqual(MeasurementMetadata.scale(on: d.page(at: i)!), i == 4 ? form.scale : nil) }
        }
    }
    func testEmptySelectionDisablesSelectedScopeAndPreservesCurrentAllCustom() throws {
        try fixture { c, d, tabs in
            switchTab(1, tabs); c.bookmarksOutlineView.deselectAll(nil)
            let form = try XCTUnwrap(c.makeDrawingScaleForm())
            let item = try selectedItem(form)
            XCTAssertFalse(item.isEnabled)
            XCTAssertEqual(form.pageIndices, [0])
            form.scope.select(item)
            XCTAssertNil(form.pageIndices)
            XCTAssertFalse(c.applyDrawingScaleForm(form))
            form.scope.selectItem(at: 1)
            XCTAssertEqual(form.pageIndices, Array(0..<6))
            form.scope.selectItem(at: 2); form.pages.stringValue = "2, 5-6"
            _ = form.scope.sendAction(form.scope.action, to: form.scope.target)
            XCTAssertTrue(form.pages.isEnabled)
            XCTAssertEqual(form.pageIndices, [1, 4, 5])
            XCTAssertTrue(c.applyDrawingScaleForm(form))
            for i in 0..<6 { XCTAssertEqual(MeasurementMetadata.scale(on: d.page(at: i)!), [1, 4, 5].contains(i) ? form.scale : nil) }
        }
    }
    func testCurrentAllAndSingleSelectedScopeApplyThroughController() throws {
        try fixture { c, d, tabs in
            switchTab(0, tabs)
            c.pagesTableView.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
            let form = try XCTUnwrap(c.makeDrawingScaleForm())
            XCTAssertEqual(try selectedItem(form).title, "Selected Pages (1)")
            XCTAssertTrue(try selectedItem(form).isEnabled)
            XCTAssertEqual(form.scope.indexOfSelectedItem, 0)
            XCTAssertTrue(c.applyDrawingScaleForm(form))
            for i in 0..<6 { XCTAssertEqual(MeasurementMetadata.scale(on: d.page(at: i)!), i == 0 ? form.scale : nil) }
            form.scope.select(try selectedItem(form))
            XCTAssertEqual(form.pageIndices, [4])
            XCTAssertTrue(c.applyDrawingScaleForm(form))
            XCTAssertEqual(MeasurementMetadata.scale(on: d.page(at: 4)!), form.scale)
            form.scope.selectItem(at: 1)
            XCTAssertTrue(c.applyDrawingScaleForm(form))
            for i in 0..<6 { XCTAssertEqual(MeasurementMetadata.scale(on: d.page(at: i)!), form.scale) }
        }
    }
    func testInvalidCustomRangeAndLostEditPermissionRejectAtomically() throws {
        try fixture { c, d, tabs in
            switchTab(0, tabs)
            c.pagesTableView.selectRowIndexes(IndexSet([1, 4]), byExtendingSelection: false)
            let form = try XCTUnwrap(c.makeDrawingScaleForm())
            c.pdfView.rectangleMarkup.canEdit = { false }
            XCTAssertFalse(c.applyDrawingScaleForm(form))
            c.pdfView.rectangleMarkup.canEdit = { true }
            form.scope.selectItem(at: 2); form.pages.stringValue = "2, 999"
            XCTAssertFalse(c.applyDrawingScaleForm(form))
            for i in 0..<6 { XCTAssertNil(MeasurementMetadata.scale(on: d.page(at: i)!)) }
        }
    }
    func testInsertionDeletionAndSameIndexReplacementRejectAllScopes() throws {
        try fixture { c, d, tabs in
            switchTab(0, tabs)
            for change in 0..<3 {
                for scope in 0..<4 {
                    c.pagesTableView.selectRowIndexes(IndexSet([1, 4]), byExtendingSelection: false)
                    let form = try XCTUnwrap(c.makeDrawingScaleForm())
                    form.scope.selectItem(at: scope)
                    let old = try XCTUnwrap(d.page(at: 1))
                    if change == 0 { d.insert(PDFPage(), at: 1) }
                    else if change == 1 { d.removePage(at: 1) }
                    else { d.removePage(at: 1); d.insert(PDFPage(), at: 1) }
                    XCTAssertFalse(c.applyDrawingScaleForm(form))
                    for i in 0..<d.pageCount { XCTAssertNil(MeasurementMetadata.scale(on: d.page(at: i)!)) }
                    if change == 0 { d.removePage(at: 1) }
                    else if change == 1 { d.insert(old, at: 1) }
                    else { d.removePage(at: 1); d.insert(old, at: 1) }
                }
            }
        }
    }
    func testSelectedScopeRecalculatesMeasurementsAndUndoRestoresHeterogeneousScales() throws {
        try fixture { c, d, tabs in
            switchTab(0, tabs)
            let session = c.pdfView.rectangleMarkup
            let undo = session.undo; undo.groupsByEvent = false
            let a = try XCTUnwrap(d.page(at: 1)), b = try XCTUnwrap(d.page(at: 4))
            let priorA = try XCTUnwrap(DrawingScale.architectural(inches: 0.25, name: "Quarter"))
            let priorB = try XCTUnwrap(DrawingScale.architectural(inches: 0.5, name: "Half"))
            undo.beginUndoGrouping()
            session.applyDrawingScale(priorA, to: [a]); session.applyDrawingScale(priorB, to: [b])
            let measurement = try XCTUnwrap(session.createMeasurement(on: a, points: [CGPoint(x: 20,y: 20), CGPoint(x: 164,y: 20)], kind: .perimeter, closed: false, scale: priorA))
            undo.endUndoGrouping()
            let before = measurement.contents
            c.pagesTableView.selectRowIndexes(IndexSet([1, 4]), byExtendingSelection: false)
            let form = try XCTUnwrap(c.makeDrawingScaleForm())
            form.preset.selectItem(at: form.presets.firstIndex { abs($0.1.unitsPerPoint - 1.0/9) < 1e-9 }!)
            undo.beginUndoGrouping(); XCTAssertTrue(c.applyDrawingScaleForm(form)); undo.endUndoGrouping()
            let after = measurement.contents
            XCTAssertNotEqual(before, after)
            for _ in 0..<2 {
                undo.undo()
                XCTAssertEqual(measurement.contents, before)
                XCTAssertEqual(MeasurementMetadata.scale(on: a), priorA)
                XCTAssertEqual(MeasurementMetadata.scale(on: b), priorB)
                undo.redo()
                XCTAssertEqual(measurement.contents, after)
                XCTAssertEqual(MeasurementMetadata.scale(on: a), form.scale)
                XCTAssertEqual(MeasurementMetadata.scale(on: b), form.scale)
            }
            for i in [0, 2, 3, 5] { XCTAssertNil(MeasurementMetadata.scale(on: d.page(at: i)!)) }
        }
    }
    func testModalDocumentReplacementAndStructuralChangesRejectWithoutMutation() throws {
        try fixture { c, d, tabs in
            switchTab(0, tabs)
            c.pagesTableView.selectRowIndexes(IndexSet([1, 4]), byExtendingSelection: false)
            let form = try XCTUnwrap(c.makeDrawingScaleForm())
            d.exchangePage(at: 1, withPageAt: 2)
            XCTAssertFalse(c.applyDrawingScaleForm(form))
            for i in 0..<6 { XCTAssertNil(MeasurementMetadata.scale(on: d.page(at: i)!)) }
            let fresh = try XCTUnwrap(c.makeDrawingScaleForm())
            let replacement = try XCTUnwrap(PDFDocument(data: XCTUnwrap(d.dataRepresentation())))
            c.pdfView.setMarkupDocument(replacement)
            XCTAssertFalse(c.applyDrawingScaleForm(fresh))
            for i in 0..<6 { XCTAssertNil(MeasurementMetadata.scale(on: replacement.page(at: i)!)) }
        }
    }
}
