import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor private final class MatchShortcutWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor final class MatchPropertiesRoundtripTests: XCTestCase {
    func fixture(_ body: (MarkupPDFView, PDFPage, RectangleMarkupController, UserDefaults) throws -> Void) throws {
        _ = NSApplication.shared
        let suite = "MatchPropertiesTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let v = MarkupPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 700))
        let d = PDFDocument(), p = PDFPage(); p.setBounds(CGRect(x: 0, y: 0, width: 600, height: 600), for: .mediaBox); d.insert(p, at: 0)
        v.setMarkupDocument(d)
        let c = RectangleMarkupController(defaults: defaults); c.view = v; c.bind(to: d); c.undo.groupsByEvent = false
        defer { v.setMarkupDocument(nil) }
        try body(v, p, c, defaults)
    }
    func styled(_ c: RectangleMarkupController, _ p: PDFPage) throws -> PDFAnnotation {
        c.undo.beginUndoGrouping(); defer { c.undo.endUndoGrouping() }
        let a = try XCTUnwrap(c.create(on: p, bounds: CGRect(x: 20, y: 20, width: 180, height: 100), kind: .text, text: "Text\nAll content"))
        var s = TextBoxAppearance(); s.fontName = "Courier"; s.bold = true; s.italic = true; s.underline = true
        s.borderWidth = 4.5; s.borderColor = [0, 0, 1]; s.borderPattern = "dashed"; s.borderOpacity = 0.45; s.fill = [1, 1, 0, 0.6]
        c.setTextBoxAppearance(s, on: a)
        return a
    }
    // PDFKit rejects setting standard /CA via setValue; import a real PDF dictionary.
    func standardTransparentShapeDocument(overlappingPeer: Bool = false) throws -> PDFDocument {
        let references = overlappingPeer ? "4 0 R 5 0 R" : "4 0 R"
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 600] /Annots [\(references)] >>", "<< /Type /Annot /Subtype /Square /Rect [250 250 350 330] /C [0 0 0] /IC [1 0 0] /CA 0.35 >>"]
        if overlappingPeer { objects.append("<< /Type /Annot /Subtype /Square /Rect [250 250 350 330] /C [0 0 0] /IC [0 0 1] /CA 0.8 >>") }
        var pdf = "%PDF-1.7\n", offsets = [0]
        for (i, object) in objects.enumerated() { offsets.append(pdf.utf8.count); pdf += "\(i + 1) 0 obj\n\(object)\nendobj\n" }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return try XCTUnwrap(PDFDocument(data: Data(pdf.utf8)))
    }
    func testStandardImportedFillOpacityToNativeUndoRedoAndWriter() throws {
        try fixture { v, _, c, _ in
            let imported = try standardTransparentShapeDocument()
            let p = try XCTUnwrap(imported.page(at: 0))
            v.setMarkupDocument(imported); c.bind(to: imported)
            let foreign = try XCTUnwrap(p.annotations.first)
            XCTAssertNil(foreign.value(forAnnotationKey: MarkupStyle.fillOpacityKey))
            XCTAssertNil(RectangleMarkupRecord.polygonFill(foreign))
            let sourceBounds = foreign.bounds
            c.undo.beginUndoGrouping()
            c.setBounds(sourceBounds.offsetBy(dx: 70, dy: 40), of: foreign, on: p, action: "Move")
            c.undo.endUndoGrouping()
            XCTAssertEqual(foreign.bounds, sourceBounds.offsetBy(dx: 70, dy: 40))
            let brush = try XCTUnwrap(c.captureMatchAppearance(foreign))
            XCTAssertEqual(brush.opacity, 0.35, accuracy: 0.001, "Standard stroke opacity")
            XCTAssertEqual(brush.fill?.alphaComponent ?? -1, 0.35, accuracy: 0.001, "Standard fill opacity must not become opaque or be multiplied twice")
            c.undo.beginUndoGrouping()
            let native = try XCTUnwrap(c.create(on: p, bounds: CGRect(x: 20, y: 250, width: 100, height: 80)))
            c.undo.endUndoGrouping()
            RectangleMarkupRecord.setPolygonFill(NSColor.green.withAlphaComponent(0.8), on: native)
            MarkupStyle.apply(pattern: .solid, opacity: 0.7, to: native)
            let id = RectangleMarkupRecord.identity(native), bounds = native.bounds
            func assertAlpha(_ stroke: Double, _ fill: Double, file: StaticString = #filePath, line: UInt = #line) {
                XCTAssertEqual(MarkupStyle.strokeOpacity(native), stroke, accuracy: 0.001, file: file, line: line)
                XCTAssertEqual(RectangleMarkupRecord.polygonFill(native)?.alphaComponent ?? -1, fill, accuracy: 0.001, file: file, line: line)
                XCTAssertEqual(RectangleMarkupRecord.identity(native), id, file: file, line: line)
                XCTAssertEqual(native.bounds, bounds, file: file, line: line)
            }
            c.undo.beginUndoGrouping(); c.applyMatchAppearance(brush, to: native); c.undo.endUndoGrouping()
            assertAlpha(0.35, 0.35)
            c.undo.undo(); assertAlpha(0.7, 0.8)
            c.undo.redo(); assertAlpha(0.35, 0.35)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let input = root.appendingPathComponent("input.pdf"), output = root.appendingPathComponent("output.pdf")
            let blank = PDFDocument(); blank.insert(PDFPage(), at: 0); XCTAssertTrue(blank.write(to: input))
            XCTAssertTrue(PDFRectangleWriter.write(document: p.document!, source: input, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(p.document!)))
            let reopened = try XCTUnwrap(PDFDocument(url: output))
            let saved = try XCTUnwrap(reopened.page(at: 0)?.annotations.first { RectangleMarkupRecord.identity($0) == id })
            XCTAssertEqual(MarkupStyle.strokeOpacity(saved), 0.35, accuracy: 0.001, "Reopened stroke")
            XCTAssertEqual(RectangleMarkupRecord.polygonFill(saved)?.alphaComponent ?? -1, 0.35, accuracy: 0.001, "Reopened fill")
            v.setMarkupDocument(reopened); c.bind(to: reopened)
            let displayedSaved = try XCTUnwrap(reopened.page(at: 0)?.annotations.first { RectangleMarkupRecord.identity($0) == id })
            let savedBrush = try XCTUnwrap(c.captureMatchAppearance(displayedSaved))
            XCTAssertEqual(savedBrush.opacity, 0.35, accuracy: 0.001)
            XCTAssertEqual(savedBrush.fill?.alphaComponent ?? -1, 0.35, accuracy: 0.001)
        }
    }
    func testImportedOpacityFollowsOverlappingIdentityThroughMoveAndStacking() throws {
        try fixture { v, _, c, _ in
            let imported = try standardTransparentShapeDocument(overlappingPeer: true)
            let p = try XCTUnwrap(imported.page(at: 0))
            v.setMarkupDocument(imported); c.bind(to: imported)
            let source = p.annotations[0], peer = p.annotations[1]
            let original = source.bounds
            XCTAssertEqual(source.bounds, peer.bounds)
            @MainActor func assertOpacity(_ a: PDFAnnotation, _ expected: Double, file: StaticString = #filePath, line: UInt = #line) throws {
                let brush = try XCTUnwrap(c.captureMatchAppearance(a), file: file, line: line)
                XCTAssertEqual(brush.opacity, expected, accuracy: 0.001, file: file, line: line)
                XCTAssertEqual(brush.fill?.alphaComponent ?? -1, expected, accuracy: 0.001, file: file, line: line)
            }
            try assertOpacity(source, 0.35); try assertOpacity(peer, 0.8)
            c.selected = source; c.reorderSelected(toFront: true)
            XCTAssertTrue(p.annotations[0] === peer); XCTAssertTrue(p.annotations[1] === source)
            try assertOpacity(source, 0.35); try assertOpacity(peer, 0.8)
            c.undo.beginUndoGrouping()
            c.setBounds(original.offsetBy(dx: 70, dy: 40), of: source, on: p, action: "Move")
            c.undo.endUndoGrouping()
            XCTAssertEqual(source.bounds, original.offsetBy(dx: 70, dy: 40))
            try assertOpacity(source, 0.35); try assertOpacity(peer, 0.8)
            c.undo.undo()
            XCTAssertEqual(source.bounds, original)
            try assertOpacity(source, 0.35); try assertOpacity(peer, 0.8)
            c.undo.redo(); try assertOpacity(source, 0.35)
            c.selected = peer; c.deleteSelected()
            XCTAssertFalse(p.annotations.contains { $0 === peer })
            try assertOpacity(source, 0.35)
            c.bind(to: nil); c.bind(to: imported)
            try assertOpacity(source, 0.35)
        }
    }
    func testImportedOpacityReplacementPreservesOriginalButExplicitPaintWins() throws {
        try fixture { v, _, c, _ in
            let imported = try standardTransparentShapeDocument()
            let p = try XCTUnwrap(imported.page(at: 0))
            v.setMarkupDocument(imported); c.bind(to: imported)
            let source = try XCTUnwrap(p.annotations.first)
            c.undo.beginUndoGrouping()
            c.setBounds(source.bounds.offsetBy(dx: 70, dy: 40), of: source, on: p, action: "Move")
            c.undo.endUndoGrouping()
            let replacement = c.editedImportedCopy(source)
            replacement.color = .blue
            c.undo.beginUndoGrouping()
            XCTAssertTrue(c.replaceImported(source, with: replacement, on: p, fields: ["/C"], action: "Color"))
            c.undo.endUndoGrouping()
            var brush = try XCTUnwrap(c.captureMatchAppearance(replacement))
            XCTAssertEqual(brush.opacity, 0.35, accuracy: 0.001)
            XCTAssertEqual(brush.fill?.alphaComponent ?? -1, 0.35, accuracy: 0.001)
            c.undo.undo()
            XCTAssertEqual(try XCTUnwrap(c.captureMatchAppearance(source)).opacity, 0.35, accuracy: 0.001)
            c.undo.redo()
            brush.opacity = 0.65; brush.fill = NSColor.green.withAlphaComponent(0.45)
            c.undo.beginUndoGrouping(); c.applyMatchAppearance(brush, to: replacement); c.undo.endUndoGrouping()
            let painted = try XCTUnwrap(c.selected)
            let captured = try XCTUnwrap(c.captureMatchAppearance(painted))
            XCTAssertEqual(captured.opacity, 0.65, accuracy: 0.001, "Do not revive stale original stroke alpha after editing")
            XCTAssertEqual(captured.fill?.alphaComponent ?? -1, 0.45, accuracy: 0.001, "Do not revive stale original fill alpha after editing")
            c.undo.undo()
            XCTAssertEqual(try XCTUnwrap(c.captureMatchAppearance(replacement)).opacity, 0.35, accuracy: 0.001)
            c.undo.redo()
            XCTAssertEqual(try XCTUnwrap(c.captureMatchAppearance(painted)).opacity, 0.65, accuracy: 0.001)
        }
    }
    func testImportedFillCaptureOpacityPrecedenceControls() throws {
        let a = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 100, height: 80), forType: .square, withProperties: nil)
        a.interiorColor = NSColor.red.withAlphaComponent(0.6)
        XCTAssertNil(a.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/CA")))
        XCTAssertEqual(a.interiorColor?.alphaComponent ?? -1, 0.6, accuracy: 0.001, "PDFKit retains interiorColor alpha without /CA")
        XCTAssertEqual(MatchMarkupAppearance(a).fill?.alphaComponent ?? -1, 0.6, accuracy: 0.001)
        try fixture { v, _, c, _ in
            let imported = try standardTransparentShapeDocument()
            let b = try XCTUnwrap(imported.page(at: 0)?.annotations.first)
            v.setMarkupDocument(imported); c.bind(to: imported)
            b.interiorColor = NSColor.red.withAlphaComponent(0.6)
            XCTAssertEqual(try XCTUnwrap(c.captureMatchAppearance(b)).fill?.alphaComponent ?? -1, 0.35, accuracy: 0.001, "/CA replaces, not multiplies, color alpha")
            b.setValue(0.75, forAnnotationKey: MarkupStyle.fillOpacityKey)
            XCTAssertEqual(try XCTUnwrap(c.captureMatchAppearance(b)).fill?.alphaComponent ?? -1, 0.75, accuracy: 0.001, "Explicit independent fill overrides /CA")
            XCTAssertEqual(try XCTUnwrap(c.captureMatchAppearance(b)).opacity, 0.35, accuracy: 0.001)
            RectangleMarkupRecord.setPolygonFill(NSColor.blue.withAlphaComponent(0.8), on: b)
            XCTAssertEqual(try XCTUnwrap(c.captureMatchAppearance(b)).fill?.alphaComponent ?? -1, 0.8, accuracy: 0.001, "Native polygon fill remains independent")
            XCTAssertEqual(try XCTUnwrap(c.captureMatchAppearance(b)).opacity, 0.35, accuracy: 0.001)
            MarkupStyle.apply(pattern: .solid, opacity: 0.55, to: b)
            XCTAssertEqual(try XCTUnwrap(c.captureMatchAppearance(b)).opacity, 0.55, accuracy: 0.001, "Explicit independent stroke overrides original /CA")
            XCTAssertEqual(try XCTUnwrap(c.captureMatchAppearance(b)).fill?.alphaComponent ?? -1, 0.8, accuracy: 0.001)
        }
    }
    func testRemediationStandardInteriorFillBothDirections() throws {
        try fixture { v, p, _, prefs in
            let foreign = PDFAnnotation(bounds: CGRect(x: 250, y: 250, width: 100, height: 80), forType: .square, withProperties: nil)
            foreign.interiorColor = .red; foreign.contents = "foreign"; p.addAnnotation(foreign)
            foreign.setValue("retain-me", forAnnotationKey: PDFAnnotationKey(rawValue: "/ForeignMetadata"))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let input = root.appendingPathComponent("input.pdf"), output = root.appendingPathComponent("output.pdf")
            XCTAssertTrue(p.document!.write(to: input))
            let c = RectangleMarkupController(defaults: prefs); c.view = v; c.bind(to: p.document); c.undo.groupsByEvent = false
            let brush = MatchMarkupAppearance(foreign)
            XCTAssertEqual(brush.fill?.usingColorSpace(.deviceRGB)?.redComponent ?? -1, 1, accuracy: 0.01)
            c.undo.beginUndoGrouping()
            let native = try XCTUnwrap(c.create(on: p, bounds: CGRect(x: 20, y: 250, width: 100, height: 80)))
            c.undo.endUndoGrouping()
            brush.install(on: native)
            XCTAssertEqual(RectangleMarkupRecord.polygonFill(native)?.usingColorSpace(.deviceRGB)?.redComponent ?? -1, 1, accuracy: 0.01)
            RectangleMarkupRecord.setPolygonFill(.green, on: native)
            c.undo.beginUndoGrouping(); c.applyMatchAppearance(MatchMarkupAppearance(native), to: foreign); c.undo.endUndoGrouping()
            let matched = try XCTUnwrap(c.selected)
            XCTAssertEqual(matched.interiorColor?.usingColorSpace(.deviceRGB)?.greenComponent ?? -1, 1, accuracy: 0.01)
            XCTAssertEqual(matched.bounds, foreign.bounds); XCTAssertEqual(matched.contents, "foreign")
            c.undo.undo(); XCTAssertTrue(p.annotations.contains { $0 === foreign }); c.undo.redo()
            XCTAssertTrue(PDFRectangleWriter.write(document: p.document!, source: input, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(p.document!), importedPlan: c.importedState?.plan(document: p.document!, stamp: PDFMarkupSourceStamp.capture(input))))
            let saved = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0)?.annotations.first)
            XCTAssertEqual(saved.interiorColor?.usingColorSpace(.deviceRGB)?.greenComponent ?? -1, 1, accuracy: 0.01)
            XCTAssertEqual(saved.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/ForeignMetadata")) as? String, "retain-me")
        }
    }
    func testRemediationCopiedStackAndIndependentTextAlpha() throws {
        try fixture { _, p, c, _ in
            let source = try styled(c, p)
            RectangleMarkupRecord.setTextColor(.black, on: source)
            let original = PDFAnnotation(bounds: CGRect(x: 0, y: 150, width: 180, height: 100), forType: .freeText, withProperties: nil)
            original.contents = "MMMM"; original.font = NSFont.systemFont(ofSize: 30); original.fontColor = .black; original.color = .clear
            original.setValue([0, 0, 0, 0], forAnnotationKey: PDFAnnotationKey(rawValue: "/RD"))
            let payload = try XCTUnwrap(CopiedMarkupPayload.capture(original))
            let target = try XCTUnwrap(payload.annotation(bounds: original.bounds))
            target.setValue(RectangleMarkupRecord.prefix + UUID().uuidString, forAnnotationKey: RectangleMarkupRecord.identityKey)
            p.addAnnotation(target)
            let top = PDFAnnotation(bounds: target.bounds, forType: .square, withProperties: nil); p.addAnnotation(top)
            let slot = try XCTUnwrap(p.annotations.firstIndex { $0 === target })
            c.undo.beginUndoGrouping(); c.applyMatchAppearance(MatchMarkupAppearance(source), to: target); c.undo.endUndoGrouping()
            let result = try XCTUnwrap(c.selected)
            XCTAssertTrue(p.annotations[slot] === result); XCTAssertTrue(p.annotations.last === top)
            XCTAssertEqual(MarkupStyle.strokeOpacity(result), MarkupStyle.strokeOpacity(source), accuracy: 0.001)
            XCTAssertEqual(TextBoxAppearance.read(result).borderOpacity, 0.45, accuracy: 0.001)
            XCTAssertEqual(TextBoxAppearance.read(result).fill?.last ?? -1, 0.6, accuracy: 0.001)
            XCTAssertEqual(result.contents, target.contents); XCTAssertEqual(result.bounds, target.bounds)
            c.undo.undo(); XCTAssertTrue(p.annotations[slot] === target); c.undo.redo(); XCTAssertTrue(p.annotations.last === top)
            let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 600, bitsPerComponent: 8, bytesPerRow: 2400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
            result.draw(with: .mediaBox, in: context)
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            var darkest = 255
            // Bitmap storage is top-down, while the PDF draw uses bottom-up
            // page coordinates. Sample the same interior page region, not its
            // vertically mirrored (blank) region.
            for y in 160..<240 { for x in 10..<170 { let i = (context.height - 1 - y) * context.bytesPerRow + x * 4; darkest = min(darkest, max(Int(bytes[i]), Int(bytes[i+1]), Int(bytes[i+2]))) } }
            XCTAssertLessThan(darkest, 60, "Opaque text must not inherit 0.45 border alpha")
            let frozen = ImportedTextContent.freeze(result, fields: [])
            let reopened = try XCTUnwrap(PDFDocument(data: frozen.metadata)?.page(at: 0)?.annotations.first)
            XCTAssertEqual(TextBoxAppearance.read(reopened).borderOpacity, 0.45, accuracy: 0.001)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let input = root.appendingPathComponent("input.pdf"), output = root.appendingPathComponent("output.pdf")
            let blank = PDFDocument(); blank.insert(PDFPage(), at: 0); XCTAssertTrue(blank.write(to: input))
            XCTAssertTrue(PDFRectangleWriter.write(document: p.document!, source: input, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(p.document!)))
            let saved = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0)?.annotations.first { RectangleMarkupRecord.identity($0) == RectangleMarkupRecord.identity(result) })
            XCTAssertEqual(TextBoxAppearance.read(saved).borderOpacity, 0.45, accuracy: 0.001)
            XCTAssertEqual(TextBoxAppearance.read(saved).fill?.last ?? -1, 0.6, accuracy: 0.001)
            XCTAssertEqual(MarkupStyle.strokeOpacity(saved), 1, accuracy: 0.001)
        }
    }
    func testUninitializedNativeTextBoxCanReadAndDrawWithoutRasterRecursion() throws {
        let a = DrawbridgeTextBoxAnnotation(bounds: CGRect(x: 0, y: 0, width: 180, height: 80), forType: .freeText, withProperties: nil)
        a.contents = "Reconstructed before style installation"
        XCTAssertEqual(TextBoxAppearance.read(a).borderWidth, 0)
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        a.draw(with: .mediaBox, in: context)
        XCTAssertNotNil(context.makeImage())
    }
    func testMatchShortcutIsConfigurableAction() throws {
        let action = try XCTUnwrap(ShortcutAction(rawValue: "matchProperties"))
        XCTAssertEqual(action.defaultBinding, ShortcutBinding(key: "c", modifier: .commandShift))
        XCTAssertEqual(ShortcutBinding.decode("shift:m"), ShortcutBinding(key: "m", modifier: .shift))
        XCTAssertEqual(action.displayName, "Match Properties")
    }
    func testMatchShortcutMenuCustomizationAndTextFocusProtection() throws {
        _ = NSApplication.shared
        let c = MainViewController(); _ = c.view
        c.shortcutBindings = c.defaultShortcutBindings()
        let window = MatchShortcutWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = c
        let oldMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = oldMenu; window.close() }
        let doc = PDFDocument(); doc.insert(PDFPage(), at: 0); c.pdfView.setMarkupDocument(doc)
        // Production markup commands require an opened-document identity, not
        // merely a PDFView document (the fixture never reads or writes this URL).
        c.openDocumentURL = URL(fileURLWithPath: "/tmp/Drawbridge-match-shortcut-fixture.pdf")
        XCTAssertTrue(c.pdfView.rectangleMarkup.canEdit())
        let delegate = AppDelegate(); delegate.setupMainMenu(controller: c)
        let item = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "Edit")?.submenu?.item(withTitle: "Match Properties"))
        XCTAssertEqual(item.keyEquivalent, "c"); XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        func event(_ key: String, _ flags: NSEvent.ModifierFlags, repeatKey: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: repeatKey, keyCode: 8))
        }
        window.makeFirstResponder(c.pdfView)
        XCTAssertNil(c.routeKeyDownEvent(try event("c", [.command, .shift])))
        XCTAssertTrue(c.pdfView.rectangleMarkup.matchPropertiesActive)
        c.pdfView.rectangleMarkup.cancelGesture()
        XCTAssertNil(c.routeKeyDownEvent(try event("c", [.command, .shift], repeatKey: true)))
        XCTAssertFalse(c.pdfView.rectangleMarkup.matchPropertiesActive)
        c.shortcutBindings[.matchProperties] = ShortcutBinding(key: "m", modifier: .shift)
        c.updateShortcutHintLabel()
        XCTAssertEqual(item.keyEquivalent, "m"); XCTAssertEqual(item.keyEquivalentModifierMask, [.shift])
        XCTAssertTrue(c.rectangleToolbar.matchPropertiesButton.toolTip?.contains("Shift+M") == true)
        XCTAssertNil(c.shortcutAction(for: try event("c", [.command, .shift])))
        XCTAssertNil(c.routeKeyDownEvent(try event("m", [.shift])))
        XCTAssertTrue(c.pdfView.rectangleMarkup.matchPropertiesActive)
        c.pdfView.rectangleMarkup.cancelGesture()
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 30)); c.view.addSubview(text); window.makeFirstResponder(text)
        let editing = try event("m", [.shift])
        XCTAssertTrue(c.routeKeyDownEvent(editing) === editing)
        XCTAssertFalse(c.validateMenuItem(item))
        c.commandMatchProperties(nil)
        XCTAssertFalse(c.pdfView.rectangleMarkup.matchPropertiesActive)
    }
    func testRealClipboardTextBoxRoundtripUndoAndWriter() throws {
        try fixture { v, p, c, _ in
            let a = try styled(c, p), expected = TextBoxAppearance.read(a)
            let board = NSPasteboard(name: .init(UUID().uuidString)); defer { board.releaseGlobally() }
            XCTAssertTrue(MarkupClipboard.copy([a], to: board))
            // Force a separate serialization/read boundary, not an in-memory annotation copy.
            let data = try XCTUnwrap(board.data(forType: MarkupClipboard.type)); board.clearContents(); board.setData(data, forType: MarkupClipboard.type)
            let items = try XCTUnwrap(MarkupClipboard.read(from: board))
            XCTAssertTrue(items[0] is DrawbridgeTextBoxAnnotation)
            XCTAssertEqual(TextBoxAppearance.read(items[0]), expected)
            let b = try XCTUnwrap(c.pasteMarkups(items, on: p, center: CGPoint(x: 400, y: 400)).first)
            XCTAssertEqual(b.contents, a.contents); XCTAssertEqual(TextBoxAppearance.read(b), expected); XCTAssertEqual(b.font?.fontName, a.font?.fontName)
            XCTAssertEqual(b.border?.lineWidth, 4.5)
            c.undo.undo(); XCTAssertFalse(p.annotations.contains { $0 === b }); c.undo.redo()
            XCTAssertEqual(TextBoxAppearance.read(b), expected)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source.pdf"), output = root.appendingPathComponent("output.pdf")
            let blank = PDFDocument(); blank.insert(PDFPage(), at: 0); XCTAssertTrue(blank.write(to: source))
            XCTAssertTrue(PDFRectangleWriter.write(document: v.document!, source: source, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(v.document!)))
            let reopened = try XCTUnwrap(PDFDocument(url: output)); let saved = try XCTUnwrap(reopened.page(at: 0)?.annotations.last)
            XCTAssertEqual(TextBoxAppearance.read(saved), expected); XCTAssertEqual(saved.contents, a.contents)
        }
    }
    func testTextBoxDefaultsFreshControllerAndToolSwitch() throws {
        try fixture { v, p, c, prefs in
            let a = try styled(c, p); c.selected = a; XCTAssertTrue(c.saveCurrentAsDefault())
            let expected = TextBoxAppearance.read(a)
            for controller in [c, RectangleMarkupController(defaults: prefs)] {
                controller.view = v; controller.bind(to: v.document); controller.undo.groupsByEvent = false
                controller.tool = .rectangle; controller.tool = .text
                controller.undo.beginUndoGrouping()
                let b = try XCTUnwrap(controller.create(on: p, bounds: CGRect(x: 250, y: 250, width: 180, height: 100), kind: .text, text: "New"))
                controller.undo.endUndoGrouping()
                XCTAssertEqual(TextBoxAppearance.read(b), expected); XCTAssertEqual(b.border?.lineWidth, 4.5)
            }
        }
    }
    func testBrushTextToShapeAndShapeToTextDoesNotChangeSemantics() throws {
        try fixture { _, p, c, _ in
            let a = try styled(c, p)
            c.undo.beginUndoGrouping(); let b = try XCTUnwrap(c.create(on: p, bounds: CGRect(x: 300, y: 300, width: 90, height: 90))); c.undo.endUndoGrouping()
            let bounds = b.bounds, id = RectangleMarkupRecord.identity(b), content = b.contents
            c.selected = a; c.beginMatchProperties()
            c.undo.beginUndoGrouping(); XCTAssertTrue(c.matchPropertiesPointerDown(at: c.view!.convert(CGPoint(x: b.bounds.midX, y: b.bounds.midY), from: p))); c.undo.endUndoGrouping()
            XCTAssertEqual(b.border?.lineWidth, 4.5); XCTAssertEqual(MarkupStyle.pattern(b), .dashed)
            XCTAssertEqual(b.bounds, bounds); XCTAssertEqual(RectangleMarkupRecord.identity(b), id); XCTAssertEqual(b.contents, content)
            XCTAssertEqual(RectangleMarkupRecord.polygonFill(b)?.usingColorSpace(.deviceRGB)?.alphaComponent ?? 0, 0.6, accuracy: 0.001)
            c.undo.undo(); XCTAssertEqual(b.border?.lineWidth, 2); c.undo.redo(); XCTAssertEqual(b.border?.lineWidth, 4.5)
        }
    }
}
