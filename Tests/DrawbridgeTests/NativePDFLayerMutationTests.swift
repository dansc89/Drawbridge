import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

/// Written before the mutation implementation. Execution is reserved for the build owner.
@MainActor final class NativePDFLayerMutationTests: XCTestCase {
    private func fixture(content: String = "/OC /A BDC 0 0 0 rg 10 10 30 30 re f EMC\n/OC /B BDC 60 60 20 20 re f EMC\n", extra: String = "", groupExtra: String = "", twoPages: Bool = false, type3: Bool = false) throws -> URL {
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] /D << /BaseState /ON /Order [5 0 R 6 0 R] \(extra) >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /Properties << /A 5 0 R /B 6 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            "<< /Type /OCG /Name (Duplicate) \(groupExtra) >>", "<< /Type /OCG /Name (Duplicate) >>"
        ]
        if twoPages {
            objects[1] = "<< /Type /Pages /Kids [3 0 R 7 0 R] /Count 2 >>"
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /Properties << /A 5 0 R /B 6 0 R >> >> /Contents 4 0 R >>")
        }
        if type3 {
            objects[2] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /Font << /F 7 0 R >> >> /Contents 4 0 R >>"
            objects.append("<< /Type /Font /Subtype /Type3 /FontBBox [0 0 100 100] /FontMatrix [0.01 0 0 0.01 0 0] /CharProcs << /A 8 0 R >> /Encoding << /Type /Encoding /Differences [65 /A] >> /FirstChar 65 /LastChar 65 /Widths [100] /Resources << /Properties << /A 5 0 R >> >> >>")
            let glyph = "100 0 d0 /OC /A BDC 10 10 30 30 re f EMC\n"
            objects.append("<< /Length \(glyph.utf8.count) >>\nstream\n\(glyph)endstream")
        }
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NativeLayerMutation-\(UUID()).pdf")
        try bytes.write(to: url); return url
    }
    private func requireHelper() throws {
        if PDFTKBookmarkWriter.executableURL() == nil { throw XCTSkip("qpdf unavailable") }
    }
    private func pixel(_ document: PDFDocument, x: Int, y: Int) throws -> CGFloat {
        let page = try XCTUnwrap(document.page(at: 0))
        let image = page.thumbnail(of: NSSize(width: 100, height: 100), for: .mediaBox)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        return min(color.redComponent, color.greenComponent, color.blueComponent)
    }
    @MainActor private final class UndoDelegate: NSObject, NSWindowDelegate {
        let manager = UndoManager()
        func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { manager }
    }

    func testNativeHideRemainsDirtyAfterRealSidecarAutosave() async throws {
        try await nativeAutosaveRoundTrip(operation: .visibility(false), carryMarkup: false)
    }
    func testNativeDeleteRemainsDirtyAfterRealSidecarAutosave() async throws {
        try await nativeAutosaveRoundTrip(operation: .deleteContent, carryMarkup: false)
    }
    func testNativeHideCarriedUnsavedMarkupRemainsDirtyAfterRealSidecarAutosave() async throws {
        try await nativeAutosaveRoundTrip(operation: .visibility(false), carryMarkup: true)
    }
    func testNativeDeleteCarriedUnsavedMarkupRemainsDirtyAfterRealSidecarAutosave() async throws {
        try await nativeAutosaveRoundTrip(operation: .deleteContent, carryMarkup: true)
    }
    private func nativeAutosaveRoundTrip(operation: NativePDFLayerMutation.Operation, carryMarkup: Bool) async throws {
        try requireHelper()
        let source = try fixture(), original = try Data(contentsOf: source)
        let controller = MainViewController(); controller.loadViewIfNeeded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.openDocument(at: source)
        let sidecar = controller.sidecarURL(for: source)
        defer {
            controller.persistenceCoordinator.cancelScheduledAutosave()
            window.contentViewController = nil
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: sidecar)
        }
        if carryMarkup {
            let markup = controller.pdfView.rectangleMarkup
            markup.undo.beginUndoGrouping()
            XCTAssertNotNil(markup.create(on: try XCTUnwrap(controller.pdfView.document?.page(at: 0)), bounds: CGRect(x: 45, y: 10, width: 10, height: 10), kind: .text, text: "carried unsaved"))
            markup.undo.endUndoGrouping()
        }
        controller.hasPromptedForInitialMarkupSaveCopy = true
        try await controller.editNativePDFLayer(registryIndex: 0, operation: operation)
        // Execute the real sidecar writer; only its queue is made deterministic.
        controller.autosaveWorkScheduler = { work in work() }
        controller.performAutosaveNow()
        let deadline = Date().addingTimeInterval(5)
        while controller.lastAutosaveAt == .distantPast && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotEqual(controller.lastAutosaveAt, .distantPast, "The real sidecar completion must run")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertEqual(try Data(contentsOf: source), original, "Sidecar autosave is not a PDF commit")
        XCTAssertTrue(controller.hasUnsavedChanges(), "Native PDF and carried markup are not recoverable from sidecar alone")
        controller.unsavedChangesResponse = { .alertThirdButtonReturn }
        XCTAssertFalse(controller.confirmDiscardUnsavedChangesIfNeeded(), "Cancel must prevent data-losing close")
        let saved = await save(controller, to: source)
        XCTAssertTrue(saved)
        XCTAssertFalse(controller.hasUnsavedChanges())
        XCTAssertTrue(controller.confirmDiscardUnsavedChangesIfNeeded())
        let reopened = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertGreaterThan(try pixel(reopened, x: 25, y: 75), 0.9)
        XCTAssertLessThan(try pixel(reopened, x: 70, y: 30), 0.2)
        XCTAssertEqual(reopened.page(at: 0)!.annotations.contains { $0.contents == "carried unsaved" }, carryMarkup)
    }

    func testPageDeletionNativeEditUndoBothSaveReopenRestoresAllArtwork() async throws {
        try requireHelper()
        let source = try fixture(twoPages: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let controller = MainViewController(); controller.loadViewIfNeeded()
        let delegate = UndoDelegate(); delegate.manager.groupsByEvent = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.delegate = delegate; window.contentViewController = controller
        defer { window.contentViewController = nil }
        controller.openDocument(at: source)
        let undo = try XCTUnwrap(window.undoManager)
        XCTAssertTrue(undo === delegate.manager)
        controller.pdfView.rectangleMarkup.documentUndoManager = undo
        let original = try XCTUnwrap(controller.pdfView.document)
        let restoredPage = try XCTUnwrap(original.page(at: 1))
        undo.beginUndoGrouping(); try controller.deletePages(at: IndexSet(integer: 1)); undo.endUndoGrouping()
        XCTAssertEqual(original.pageCount, 1)
        try await controller.editNativePDFLayer(registryIndex: 0, operation: .visibility(false))
        undo.undo(); XCTAssertTrue(controller.pdfView.document === original)
        undo.undo(); XCTAssertEqual(original.pageCount, 2)
        XCTAssertTrue(original.page(at: 1) === restoredPage)
        let saved = await save(controller, to: source); XCTAssertTrue(saved)
        let reopened = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(reopened.pageCount, 2)
        XCTAssertEqual(EmbeddedPDFLayers.read(reopened).map(\.visible), [true, true])
        for index in 0..<reopened.pageCount {
            let single = PDFDocument(); single.insert(try XCTUnwrap(reopened.page(at: index)?.copy() as? PDFPage), at: 0)
            XCTAssertLessThan(try pixel(single, x: 25, y: 75), 0.2, "Restored sheet must retain target artwork")
            XCTAssertLessThan(try pixel(single, x: 70, y: 30), 0.2, "Restored sheet must retain unrelated artwork")
        }
    }

    func testType3GlyphLayerDeletionFailsClosedAndPreservesSource() throws {
        try requireHelper()
        let source = try fixture(content: "BT /F 10 Tf 1 0 0 1 10 10 Tm (A) Tj ET\n", type3: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let bytes = try Data(contentsOf: source)
        XCTAssertNotNil(PDFDocument(url: source))
        XCTAssertThrowsError(try NativePDFLayerMutation.transform(source: source, registryIndex: 0, operation: .deleteContent)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Type3"))
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testControllerNativeEditPreservesUnsavedMarkupUndoAndSavedRendering() async throws {
        try await controllerRoundTrip(operation: .visibility(false))
    }
    func testControllerDeletePreservesUnsavedMarkupUndoAndSavedRendering() async throws {
        try await controllerRoundTrip(operation: .deleteContent)
    }
    private func controllerRoundTrip(operation: NativePDFLayerMutation.Operation) async throws {
        try requireHelper()
        let source = try fixture(); let original = try Data(contentsOf: source)
        let destination = source.deletingLastPathComponent().appendingPathComponent("NativeSaved-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: destination) }
        let controller = MainViewController(); controller.loadViewIfNeeded(); controller.openDocument(at: source)
        let before = try XCTUnwrap(controller.pdfView.document)
        let undo = controller.pdfView.rectangleMarkup.undo
        undo.beginUndoGrouping()
        let annotation = try XCTUnwrap(controller.pdfView.rectangleMarkup.create(on: try XCTUnwrap(before.page(at: 0)), bounds: CGRect(x: 45, y: 10, width: 10, height: 10), kind: .text, text: "unsaved retained"))
        undo.endUndoGrouping()
        controller.markMarkupChanged()
        try await controller.editNativePDFLayer(registryIndex: 0, operation: operation)
        XCTAssertFalse(controller.pdfView.document === before)
        XCTAssertGreaterThan(try pixel(try XCTUnwrap(controller.pdfView.document), x: 25, y: 75), 0.9)
        XCTAssertTrue(controller.pdfView.document?.page(at: 0)?.annotations.contains(where: { $0.contents == "unsaved retained" }) == true)
        undo.undo(); XCTAssertTrue(controller.pdfView.document === before)
        undo.undo(); XCTAssertFalse(before.page(at: 0)!.annotations.contains(annotation))
        undo.redo(); undo.redo()
        let saved = expectation(description: "saved")
        controller.persistDocument(to: destination, adoptAsPrimaryDocument: false, busyMessage: "Test", showBusyOverlay: false) { success in XCTAssertTrue(success); saved.fulfill() }
        await fulfillment(of: [saved], timeout: 20)
        let reopened = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertGreaterThan(try pixel(reopened, x: 25, y: 75), 0.9)
        XCTAssertTrue(reopened.page(at: 0)!.annotations.contains(where: { $0.contents == "unsaved retained" }))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    private func save(_ controller: MainViewController, to url: URL, adopt: Bool = false) async -> Bool {
        controller.saveErrorPresenter = { _ in .alertFirstButtonReturn }
        let done = expectation(description: "save completed")
        var result = false
        controller.persistDocument(to: url, adoptAsPrimaryDocument: adopt, busyMessage: "Test", showBusyOverlay: false) { success in
            result = success; done.fulfill()
        }
        await fulfillment(of: [done], timeout: 20)
        return result
    }
    func testControllerOverwriteUndoRedoAndExternalConflict() async throws {
        try requireHelper()
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let controller = MainViewController(); controller.loadViewIfNeeded(); controller.openDocument(at: source)
        let undo = controller.pdfView.rectangleMarkup.undo
        try await controller.editNativePDFLayer(registryIndex: 0, operation: .visibility(false))
        let first = await save(controller, to: source); XCTAssertTrue(first)
        undo.undo()
        XCTAssertLessThan(try pixel(try XCTUnwrap(controller.pdfView.document), x: 25, y: 75), 0.2)
        let second = await save(controller, to: source); XCTAssertTrue(second)
        XCTAssertLessThan(try pixel(try XCTUnwrap(PDFDocument(url: source)), x: 25, y: 75), 0.2)
        undo.redo()
        let third = await save(controller, to: source); XCTAssertTrue(third)
        XCTAssertGreaterThan(try pixel(try XCTUnwrap(PDFDocument(url: source)), x: 25, y: 75), 0.9)
        var external = try Data(contentsOf: source); external.append(Data("\n% external writer\n".utf8)); try external.write(to: source)
        let refused = await save(controller, to: source); XCTAssertFalse(refused)
        XCTAssertEqual(try Data(contentsOf: source), external)
    }
    func testControllerSaveAsRecoveryRetainsNativeContentAndUndoProvenance() async throws {
        try requireHelper()
        let source = try fixture()
        let destination = source.deletingLastPathComponent().appendingPathComponent("NativeRecovered-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: destination) }
        let controller = MainViewController(); controller.loadViewIfNeeded(); controller.openDocument(at: source)
        let undo = controller.pdfView.rectangleMarkup.undo
        try await controller.editNativePDFLayer(registryIndex: 0, operation: .deleteContent)
        try FileManager.default.removeItem(at: source)
        let recovered = await save(controller, to: destination, adopt: true)
        XCTAssertTrue(recovered)
        XCTAssertGreaterThan(try pixel(try XCTUnwrap(PDFDocument(url: destination)), x: 25, y: 75), 0.9)
        XCTAssertEqual(controller.openDocumentURL, destination)
        undo.undo()
        let restored = await save(controller, to: destination)
        XCTAssertTrue(restored)
        XCTAssertLessThan(try pixel(try XCTUnwrap(PDFDocument(url: destination)), x: 25, y: 75), 0.2)
        undo.redo()
        let deleted = await save(controller, to: destination)
        XCTAssertTrue(deleted)
        XCTAssertGreaterThan(try pixel(try XCTUnwrap(PDFDocument(url: destination)), x: 25, y: 75), 0.9)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }
    func testControllerSplitPeerTracksNativeSessionAcrossUndoRedo() async throws {
        try requireHelper()
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let controller = MainViewController(); controller.loadViewIfNeeded(); controller.openDocument(at: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { window.contentViewController = nil }
        _ = controller.tryToPerform(NSSelectorFromString("commandToggleSplitView:"), with: nil)
        let peer = try XCTUnwrap(controller.secondaryPDFView)
        let before = controller.pdfView.rectangleMarkup
        let undo = before.undo
        try await controller.editNativePDFLayer(registryIndex: 0, operation: .deleteContent)
        XCTAssertTrue(peer.rectangleMarkup === controller.pdfView.rectangleMarkup)
        XCTAssertGreaterThan(try pixel(try XCTUnwrap(peer.document), x: 25, y: 75), 0.9)
        undo.undo(); XCTAssertTrue(peer.rectangleMarkup === before)
        undo.redo(); XCTAssertTrue(peer.rectangleMarkup === controller.pdfView.rectangleMarkup)
        XCTAssertTrue(controller.hasUnsavedChanges())
    }

    func testVisibilityChangesActualPDFKitRenderingPreservesDuplicateGroupAndOriginal() throws {
        try requireHelper()
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)
        let before = try XCTUnwrap(PDFDocument(url: source))
        let hidden = try NativePDFLayerMutation.transform(source: source, registryIndex: 0, operation: .visibility(false))
        let document = try XCTUnwrap(PDFDocument(url: hidden.url))
        XCTAssertLessThan(try pixel(before, x: 25, y: 75), 0.2)
        XCTAssertGreaterThan(try pixel(document, x: 25, y: 75), 0.9)
        XCTAssertLessThan(try pixel(document, x: 70, y: 30), 0.2, "Same-name independent layer must remain visible")
        XCTAssertEqual(EmbeddedPDFLayers.read(document).map(\.visible), [false, true])
        let shown = try NativePDFLayerMutation.transform(source: hidden.url, registryIndex: 0, operation: .visibility(true))
        XCTAssertLessThan(try pixel(try XCTUnwrap(PDFDocument(url: shown.url)), x: 25, y: 75), 0.2)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testCreatorInfoIsNotAnAutomaticVisibilityOverrideButViewUsageRejects() throws {
        try requireHelper()
        let benign = try fixture(groupExtra: "/Usage << /CreatorInfo << /Creator (CAD) /Subtype /Artwork >> >>")
        let automatic = try fixture(groupExtra: "/Usage << /View << /ViewState /OFF >> >>")
        defer { try? FileManager.default.removeItem(at: benign); try? FileManager.default.removeItem(at: automatic) }
        XCTAssertEqual(EmbeddedPDFLayers.read(try XCTUnwrap(PDFDocument(url: benign))).first?.visible, true)
        XCTAssertNotNil(try NativePDFLayerMutation.transform(source: benign, registryIndex: 0, operation: .visibility(false)))
        XCTAssertNil(EmbeddedPDFLayers.read(try XCTUnwrap(PDFDocument(url: automatic))).first?.visible)
        XCTAssertThrowsError(try NativePDFLayerMutation.transform(source: automatic, registryIndex: 0, operation: .visibility(true)))
    }
    func testDeletionRemovesPaintRatherThanRevealingOrMerelyHidingIt() throws {
        try requireHelper()
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)
        let deleted = try NativePDFLayerMutation.transform(source: source, registryIndex: 0, operation: .deleteContent)
        let result = try XCTUnwrap(PDFDocument(url: deleted.url))
        XCTAssertGreaterThan(try pixel(result, x: 25, y: 75), 0.9)
        XCTAssertLessThan(try pixel(result, x: 70, y: 30), 0.2)
        // Deliberately turn the cleared group back on: removed drawing must not reappear.
        let shown = try NativePDFLayerMutation.transform(source: deleted.url, registryIndex: 0, operation: .visibility(true))
        XCTAssertGreaterThan(try pixel(try XCTUnwrap(PDFDocument(url: shown.url)), x: 25, y: 75), 0.9)
        XCTAssertEqual(EmbeddedPDFLayers.read(result).count, 2, "Empty native group is deliberately retained; never flatten unrelated layers")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testDeleteRewritesOnlyPaintingAndRetainsGraphicsState() throws {
        let input = Data("/OC /A BDC 1 0 0 rg 10 10 20 20 re f EMC 60 60 20 20 re f".utf8)
        let output = try NativePDFLayerMutation.removingPaint(input, properties: ["/A": true], xObjects: [:])
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "/OC /A BDC 1 0 0 rg 10 10 20 20 re n EMC 60 60 20 20 re f")
    }
    func testDeleteNestedBlocksNameEscapesAndStringsAreLexical() throws {
        let input = Data("/OC /A#20B BDC /Span BMC q 1 0 0 1 0 0 cm 0 0 5 5 re f Q EMC EMC /OC /C BDC 8 8 2 2 re f EMC".utf8)
        let output = try NativePDFLayerMutation.removingPaint(input, properties: ["/A B": true, "/C": false], xObjects: [:])
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "/OC /A#20B BDC /Span BMC q 1 0 0 1 0 0 cm 0 0 5 5 re n Q EMC EMC /OC /C BDC 8 8 2 2 re f EMC")
    }
    func testUnsafeTextInlineImagesUnknownPropertiesAndUnbalancedProgramsReject() {
        for content in ["/OC /A BDC BT (not EMC) Tj ET EMC", "/OC /A BDC BI /W 1 ID x EI EMC", "/OC /Unknown BDC 0 0 1 1 re f EMC", "/OC /A BDC 0 0 1 1 re f", "/OC /A BDC 0 0 m EMC 1 1 l S", "/OC << /Type /OCMD >> BDC EMC"] {
            XCTAssertThrowsError(try NativePDFLayerMutation.removingPaint(Data(content.utf8), properties: ["/A": true], xObjects: [:]), content)
        }
    }
    func testTargetedXObjectInvocationIsRemovedButUnrelatedInvocationIsPreserved() throws {
        let input = Data("q /Chosen Do Q q /Other Do Q".utf8)
        let result = try NativePDFLayerMutation.removingPaint(input, properties: [:], xObjects: ["/Chosen": true, "/Other": false])
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "q  Q q /Other Do Q")
    }
    func testUnsupportedConfigurationAndTextFailWithoutTouchingSource() throws {
        try requireHelper()
        for (content, config) in [("/OC /A BDC 0 0 1 1 re f EMC\n", "/AS [<< /Event /View /Category [/Zoom] /OCGs [5 0 R] >>]"), ("/OC /A BDC BT (keep me) Tj ET EMC\n", "")] {
            let source = try fixture(content: content, extra: config)
            defer { try? FileManager.default.removeItem(at: source) }
            let bytes = try Data(contentsOf: source)
            XCTAssertThrowsError(try NativePDFLayerMutation.transform(source: source, registryIndex: 0, operation: .deleteContent))
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }
    func testNativeTransactionPreservesEarlierUndoAndRetainsExactSessionObjects() {
        let undo = UndoManager(); undo.groupsByEvent = false
        let before = PDFDocument(), after = PDFDocument()
        var current = before, earlierEdit = true
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: before) { _ in MainActor.assumeIsolated { earlierEdit = false } }
        undo.endUndoGrouping()
        let transaction = NativePDFLayerUndoTransaction(undo: undo, before: { current = before }, after: { current = after }, changed: {})
        undo.beginUndoGrouping()
        transaction.apply(name: "PDF Layer Visibility")
        undo.endUndoGrouping()
        XCTAssertTrue(current === after)
        undo.undo(); XCTAssertTrue(current === before); XCTAssertTrue(earlierEdit)
        undo.undo(); XCTAssertFalse(earlierEdit)
        // Independent native redo should also retain its document/session state.
        let second = UndoManager(); second.groupsByEvent = false
        let redoable = NativePDFLayerUndoTransaction(undo: second, before: { current = before }, after: { current = after }, changed: {})
        second.beginUndoGrouping()
        redoable.apply(name: "Delete PDF Layer Content")
        second.endUndoGrouping()
        second.undo(); second.redo()
        XCTAssertTrue(current === after)
    }
    func testRetainedSidebarActionRejectsDocumentReplacementAndRefreshGeneration() throws {
        _ = NSApplication.shared
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        let view = MarkupPDFView(frame: .zero); view.document = document
        let session = view.rectangleMarkup; session.canEdit = { true }; session.bind(to: document)
        let panel = MarkupLayersView(); panel.session = session
        var requests: [Int] = []
        panel.onEmbeddedVisibility = { layer, _ in requests.append(layer.registryIndex) }
        panel.onEmbeddedDelete = { layer in requests.append(layer.registryIndex) }
        panel.refresh()
        let column = panel.table.tableColumns.first { $0.identifier.rawValue == "visible" }
        let old = try XCTUnwrap(panel.tableView(panel.table, viewFor: column, row: 0) as? NSButton)
        XCTAssertTrue(old.isEnabled)
        old.performClick(nil)
        XCTAssertEqual(requests, [0])
        panel.refresh()
        old.performClick(nil)
        XCTAssertEqual(requests, [0], "Old controls cannot act after presentation generation changes")
        let fresh = try XCTUnwrap(panel.tableView(panel.table, viewFor: column, row: 0) as? NSButton)
        view.document = PDFDocument()
        fresh.performClick(nil)
        XCTAssertEqual(requests, [0], "Document identity must be checked before invoking a retained action")
        XCTAssertFalse(session.undo.canUndo, "Sidebar dispatch alone must not fake markup edits")
    }
}
