import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class TextBoxPropertiesTests: XCTestCase {
    private func canvas(_ body: (MarkupPDFView, PDFPage, MarkupPropertiesViewController) throws -> Void) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = MarkupPDFView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        let doc = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 600), for: .mediaBox); doc.insert(page, at: 0)
        view.setMarkupDocument(doc); view.displayMode = .singlePage; view.autoScales = false; view.scaleFactor = 1; view.go(to: page)
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
        let c = view.rectangleMarkup; c.canEdit = { true }; c.undo.groupsByEvent = false
        let inspector = MarkupPropertiesViewController(); inspector.session = c; _ = inspector.view
        defer { view.setMarkupDocument(nil); window.close() }
        try body(view, page, inspector)
    }
    private func control<T: NSControl>(_ id: String, in root: NSView, as type: T.Type = T.self) throws -> T {
        func walk(_ v: NSView) -> T? {
            if v.identifier?.rawValue == id { return v as? T }
            return v.subviews.lazy.compactMap { walk($0) }.first
        }
        let result = try XCTUnwrap(walk(root), "Reachable control missing: \(id)")
        XCTAssertFalse(result.isHiddenOrHasHiddenAncestor); XCTAssertTrue(result.isEnabled)
        return result
    }
    private func send(_ control: NSControl) { XCTAssertTrue(control.sendAction(control.action, to: control.target)) }
    private func number(_ id: String, _ value: Double, _ inspector: MarkupPropertiesViewController) throws {
        let f: NSTextField = try control(id, in: inspector.view); f.doubleValue = value; send(f)
    }
    private func styleSource(_ inspector: MarkupPropertiesViewController) throws {
        let border: SwatchColorWell = try control("textbox.borderColor", in: inspector.view)
        border.color = .blue; send(border)
        try number("textbox.borderWidth", 4.5, inspector)
        let pattern: NSPopUpButton = try control("textbox.borderPattern", in: inspector.view); pattern.selectItem(withTitle: "Dashed"); send(pattern)
        try number("textbox.borderOpacity", 45, inspector)
        let fill: SwatchColorWell = try control("textbox.fill", in: inspector.view); fill.color = .yellow; fill.isNoColor = false; send(fill)
        let font: NSPopUpButton = try control("textbox.font", in: inspector.view); font.selectItem(withTitle: "Courier"); send(font)
        for id in ["textbox.bold", "textbox.italic", "textbox.underline"] { let b: NSButton = try control(id, in: inspector.view); b.state = .on; send(b) }
        inspector.fontSize.doubleValue = 26.5; inspector.changeNumber(inspector.fontSize)
        inspector.stroke.color = .red; inspector.changeStroke(inspector.stroke)
    }
    private func appearance(_ annotation: PDFAnnotation) throws -> String {
        try XCTUnwrap(annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "DrawbridgeTextBoxAppearance")) as? String)
    }
    private func click(_ v: MarkupPDFView, _ p: PDFPage, _ a: PDFAnnotation) {
        XCTAssertTrue(v.rectangleMarkup.pointerDown(at: v.convert(CGPoint(x: a.bounds.midX, y: a.bounds.midY), from: p)))
    }
    func testInspectorIndependentBorderAndWholeBoxTextStyleUndo() throws {
        try canvas { v, p, i in
            let c = v.rectangleMarkup
            c.undo.beginUndoGrouping(); let a = try XCTUnwrap(c.create(on: p, bounds: CGRect(x: 30, y: 30, width: 180, height: 90), kind: .text, text: "Box contents")); c.undo.endUndoGrouping()
            c.selected = a; i.refresh()
            XCTAssertEqual(a.border?.lineWidth, 0)
            c.undo.beginUndoGrouping(); try styleSource(i); c.undo.endUndoGrouping()
            XCTAssertEqual(a.border?.lineWidth, 4.5)
            XCTAssertEqual(RectangleMarkupRecord.textFontSize(a), 26.5)
            XCTAssertEqual(RectangleMarkupRecord.markupColor(a).usingColorSpace(.deviceRGB)?.redComponent, 1)
            XCTAssertTrue(a.font?.fontName.contains("Courier") == true)
            let styled = try appearance(a)
            c.undo.undo(); XCTAssertEqual(a.border?.lineWidth, 0); XCTAssertEqual(a.contents, "Box contents")
            c.undo.redo(); XCTAssertEqual(try appearance(a), styled)
        }
    }
    func testPaintbrushCapturesThenAppliesWithoutChangingTargetIdentityAndEscCancels() throws {
        try canvas { v, p, i in
            let c = v.rectangleMarkup
            c.undo.beginUndoGrouping()
            let source = try XCTUnwrap(c.create(on: p, bounds: CGRect(x: 20, y: 30, width: 160, height: 100), kind: .text, text: "SOURCE"))
            let target = try XCTUnwrap(c.create(on: p, bounds: CGRect(x: 260, y: 300, width: 190, height: 90), kind: .text, text: "TARGET"))
            let shape = try XCTUnwrap(c.create(on: p, bounds: CGRect(x: 30, y: 300, width: 90, height: 80)))
            c.undo.endUndoGrouping()
            c.selected = source; i.refresh(); c.undo.beginUndoGrouping(); try styleSource(i); c.undo.endUndoGrouping()
            let expected = try appearance(source), bounds = target.bounds, id = RectangleMarkupRecord.identity(target)
            target.userName = "Target author"; target.setValue("target-subject", forAnnotationKey: PDFAnnotationKey(rawValue: "/Subj"))
            let toolbar = RectangleMarkupToolbar(frame: .zero)
            toolbar.propertiesController.session = c
            let brush: NSButton = try control("markup.matchProperties", in: toolbar)
            // Toolbar action captures the selected source; subsequent clicks paint, not select.
            send(brush)
            c.undo.beginUndoGrouping(); c.selected = source; i.refresh(); try number("textbox.borderWidth", 9, i); c.undo.endUndoGrouping()
            click(v, p, shape); XCTAssertEqual(shape.border?.lineWidth, 2)
            c.undo.beginUndoGrouping(); click(v, p, target); c.undo.endUndoGrouping()
            XCTAssertEqual(try appearance(target), expected, "Brush must freeze the source at activation")
            XCTAssertEqual(target.contents, "TARGET"); XCTAssertEqual(target.bounds, bounds); XCTAssertEqual(RectangleMarkupRecord.identity(target), id)
            XCTAssertEqual(target.userName, "Target author"); XCTAssertEqual(target.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Subj")) as? String, "target-subject")
            c.undo.undo(); XCTAssertEqual(target.border?.lineWidth, 0)
            c.undo.redo(); XCTAssertEqual(try appearance(target), expected)
            c.escape(); c.undo.beginUndoGrouping(); c.selected = target; i.refresh(); try number("textbox.borderWidth", 2, i); c.undo.endUndoGrouping()
            click(v, p, target); XCTAssertEqual(target.border?.lineWidth, 2, "Esc must disarm brush")
            // With no selected source, first click captures and next click paints.
            c.selected = nil; send(brush); click(v, p, source)
            c.undo.beginUndoGrouping(); click(v, p, target); c.undo.endUndoGrouping()
            XCTAssertEqual(try appearance(target), try appearance(source))
            c.cancelGesture()
        }
    }
    private func assertIndependentInk(_ annotation: PDFAnnotation, savedPage: PDFPage? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let side = 600
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        if let savedPage { savedPage.draw(with: .mediaBox, to: context) }
        else { annotation.draw(with: .mediaBox, in: context) }
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var red = 0, blue = 0
        for pixel in 0..<(side * side) {
            let r = bytes[pixel * 4], g = bytes[pixel * 4 + 1], b = bytes[pixel * 4 + 2]
            if r > 180 && g < 100 && b < 100 { red += 1 }
            if b > 180 && r < 100 && g < 100 { blue += 1 }
        }
        XCTAssertGreaterThan(red, 30, "Text ink must remain red", file: file, line: line)
        XCTAssertGreaterThan(blue, 100, "Independent border ink must remain blue", file: file, line: line)
    }
    func testReopenedNativeTextBoxInspectorEditorBrushAndSecondSave() throws {
        try canvas { v, p, i in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let c = v.rectangleMarkup
            let document = try XCTUnwrap(v.document)
            c.undo.beginUndoGrouping()
            let sourceBox = try XCTUnwrap(c.create(on: p, bounds: CGRect(x: 30, y: 40, width: 230, height: 140), kind: .text, text: "SOURCE"))
            let target = try XCTUnwrap(c.create(on: p, bounds: CGRect(x: 300, y: 300, width: 230, height: 140), kind: .text, text: "TARGET"))
            c.undo.endUndoGrouping()
            c.selected = sourceBox; i.refresh()
            c.undo.beginUndoGrouping(); try styleSource(i); c.undo.endUndoGrouping()
            let ids = [sourceBox, target].map(RectangleMarkupRecord.identity)
            for rotation in [0, 90, 180, 270] {
                p.rotation = rotation
                let source = root.appendingPathComponent("source-\(rotation).pdf")
                let first = root.appendingPathComponent("first-\(rotation).pdf")
                let second = root.appendingPathComponent("second-\(rotation).pdf")
                let blank = PDFDocument(), blankPage = PDFPage()
                blankPage.setBounds(p.bounds(for: .mediaBox), for: .mediaBox); blankPage.rotation = rotation; blank.insert(blankPage, at: 0)
                XCTAssertTrue(blank.write(to: source)); let originalBytes = try Data(contentsOf: source)
                XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: first, pageLabels: [:], records: RectangleMarkupRecord.capture(document)))
                let reopened = try XCTUnwrap(PDFDocument(url: first)), page = try XCTUnwrap(reopened.page(at: 0))
                let before = page.annotations
                let beforeRecords = RectangleMarkupRecord.capture(reopened)
                before[0].setValue("keep-subject", forAnnotationKey: PDFAnnotationKey(rawValue: "/Subj"))
                before[0].setValue("keep-custom", forAnnotationKey: PDFAnnotationKey(rawValue: "DrawbridgeTestExtra"))
                before[0].modificationDate = Date(timeIntervalSince1970: 1234567890)
                let date = before[0].modificationDate
                v.setMarkupDocument(reopened); v.go(to: page); v.layoutSubtreeIfNeeded()
                XCTAssertFalse(c.hasUnsavedChanges)
                XCTAssertEqual(RectangleMarkupRecord.capture(reopened), beforeRecords)
                XCTAssertEqual(page.rotation, rotation)
                XCTAssertEqual(page.annotations.map(RectangleMarkupRecord.identity), ids)
                let a = page.annotations[0], b = page.annotations[1]
                XCTAssertTrue(a is DrawbridgeTextBoxAnnotation, "Reopen must restore the live native renderer")
                XCTAssertTrue(b is DrawbridgeTextBoxAnnotation, "Legacy borderless native boxes must also be editable")
                XCTAssertEqual(a.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Subj")) as? String, "keep-subject")
                XCTAssertEqual(a.value(forAnnotationKey: PDFAnnotationKey(rawValue: "DrawbridgeTestExtra")) as? String, "keep-custom")
                XCTAssertEqual(a.modificationDate, date)
                c.selected = a; i.refresh(); c.undo.beginUndoGrouping()
                try number("textbox.borderWidth", 6, i); try number("textbox.borderOpacity", 100, i)
                let fill: SwatchColorWell = try control("textbox.fill", in: i.view); fill.isNoColor = true; send(fill)
                c.undo.endUndoGrouping()
                let style = try appearance(a), fontName = a.font?.fontName, bounds = a.bounds
                let documentUndo = c.undo
                c.beginTextEditing(on: page, bounds: a.bounds, annotation: a)
                let editor = try XCTUnwrap(v.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
                XCTAssertTrue(editor.font?.fontName.contains("Courier") == true, "Editor must display the whole-box font")
                editor.string = "EDITED"
                documentUndo.beginUndoGrouping(); c.finishTextEditing(); documentUndo.endUndoGrouping()
                XCTAssertEqual(a.contents, "EDITED"); XCTAssertEqual(a.bounds, bounds)
                XCTAssertEqual(try appearance(a), style); XCTAssertEqual(a.font?.fontName, fontName)
                XCTAssertEqual(a.border?.lineWidth, 6)
                try assertIndependentInk(a)
                let toolbar = RectangleMarkupToolbar(frame: .zero); toolbar.propertiesController.session = c
                let brush: NSButton = try control("markup.matchProperties", in: toolbar)
                c.selected = a; send(brush)
                c.undo.beginUndoGrouping(); click(v, page, b); c.undo.endUndoGrouping(); c.escape()
                XCTAssertEqual(try appearance(b), style); XCTAssertEqual(b.contents, "TARGET")
                XCTAssertEqual(b.bounds, before[1].bounds); XCTAssertEqual(RectangleMarkupRecord.identity(b), ids[1])
                try assertIndependentInk(b)
                let records = RectangleMarkupRecord.capture(reopened)
                XCTAssertTrue(PDFRectangleWriter.write(document: reopened, source: first, destination: second, pageLabels: [:], records: records))
                let fresh = try XCTUnwrap(PDFDocument(url: second)), freshPage = try XCTUnwrap(fresh.page(at: 0))
                XCTAssertEqual(RectangleMarkupRecord.capture(fresh), records)
                XCTAssertEqual(freshPage.rotation, rotation)
                try assertIndependentInk(try XCTUnwrap(freshPage.annotations.first), savedPage: freshPage)
                v.setMarkupDocument(fresh)
                XCTAssertTrue(freshPage.annotations.allSatisfy { $0 is DrawbridgeTextBoxAnnotation })
                XCTAssertEqual(try Data(contentsOf: source), originalBytes)
            }
        }
    }
    func testAdoptionPreservesForeignAndCopiedTextPayloads() throws {
        try canvas { v, _, i in
            let doc = PDFDocument(), page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 600), for: .mediaBox); doc.insert(page, at: 0)
            let foreign = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 180, height: 90), forType: .freeText, withProperties: nil)
            foreign.contents = "FOREIGN"; foreign.font = .systemFont(ofSize: 18)
            let copied = PDFAnnotation(bounds: CGRect(x: 220, y: 20, width: 180, height: 90), forType: .freeText, withProperties: nil)
            copied.contents = "COPIED"; copied.font = .systemFont(ofSize: 18)
            copied.setValue(RectangleMarkupRecord.prefix + "copy", forAnnotationKey: RectangleMarkupRecord.identityKey)
            let payload = CopiedMarkupPayload(metadata: Data([1]), appearance: Data([2]), richText: Data([3]))
            payload.install(on: copied)
            let malformed = PDFAnnotation(bounds: copied.bounds, forType: .freeText, withProperties: nil)
            malformed.setValue(RectangleMarkupRecord.prefix + "malformed-copy", forAnnotationKey: RectangleMarkupRecord.identityKey)
            malformed.setValue("unsupported-payload", forAnnotationKey: CopiedMarkupPayload.key)
            let imported = ImportedTextAnnotation(source: foreign, richText: NSAttributedString(string: "RICH IMPORT"))
            imported.setValue(RectangleMarkupRecord.prefix + "import", forAnnotationKey: RectangleMarkupRecord.identityKey)
            let originals = [foreign, copied, malformed, imported]
            originals.forEach(page.addAnnotation)
            v.setMarkupDocument(doc)
            XCTAssertEqual(page.annotations.count, originals.count)
            for (actual, original) in zip(page.annotations, originals) { XCTAssertTrue(actual === original) }
            XCTAssertEqual(CopiedMarkupPayload.read(copied), payload)
            for a in originals {
                v.rectangleMarkup.selected = a; i.refresh()
                v.rectangleMarkup.undo.beginUndoGrouping()
                var style = TextBoxAppearance(); style.borderWidth = 7
                v.rectangleMarkup.setTextBoxAppearance(style)
                v.rectangleMarkup.undo.endUndoGrouping()
                XCTAssertNil(a.value(forAnnotationKey: TextBoxAppearance.key), "Unsupported payload must not be rewritten")
            }
        }
    }
    func testStyledTextWriterSaveReopenAndLegacyNoBorder() throws {
        try canvas { v, p, i in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source.pdf"), output = root.appendingPathComponent("saved.pdf")
            let doc = try XCTUnwrap(v.document); XCTAssertTrue(doc.write(to: source)); let bytes = try Data(contentsOf: source)
            let c = v.rectangleMarkup
            c.undo.beginUndoGrouping(); let a = try XCTUnwrap(c.create(on: p, bounds: CGRect(x: 30, y: 30, width: 180, height: 90), kind: .text, text: "Styled PDF")); c.undo.endUndoGrouping()
            c.selected = a; i.refresh(); c.undo.beginUndoGrouping(); try styleSource(i); c.undo.endUndoGrouping()
            let record = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: a, pageIndex: 0)); XCTAssertTrue(record.isValid)
            var failure: PDFRectangleWriter.SaveFailure?
            XCTAssertTrue(PDFRectangleWriter.write(document: doc, source: source, destination: output, pageLabels: [:], records: [record], onFailure: { failure = $0 }), "\(failure?.stage ?? "unknown")")
            let reopened = try XCTUnwrap(PDFDocument(url: output)); let saved = try XCTUnwrap(reopened.page(at: 0)?.annotations.first)
            XCTAssertEqual(try appearance(saved), try appearance(a)); XCTAssertEqual(saved.border?.lineWidth, 4.5)
            let recaptured = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: saved, pageIndex: 0)); XCTAssertEqual(recaptured, record)
            let drawing = TextMarkupAppearance.drawing(recaptured)
            XCTAssertTrue(drawing.contains("4.5 w")); XCTAssertTrue(drawing.contains(" re S")); XCTAssertTrue(drawing.contains(" re f"))
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            // Old records without the new optional style remain borderless.
            let legacy = RectangleMarkupRecord(id: RectangleMarkupRecord.prefix + "old", pageIndex: 0, bounds: a.bounds, red: 0, green: 0, blue: 0, lineWidth: 2)
            XCTAssertFalse(TextMarkupAppearance.drawing(legacy).contains(" re S"))
        }
    }
}
