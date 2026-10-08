import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

/// PDFKit legitimately reads the inherited ObjC document property off the main thread.
private final class SaveBenchmarkDocument: @unchecked Sendable {
    let document: PDFDocument
    init(document: PDFDocument) { self.document = document }
}

private final class BackgroundPDFDocumentRead: @unchecked Sendable {
    let object: NSObject
    let expected: PDFDocument
    init(view: PDFView, document: PDFDocument) { object = view; expected = document }
}

@MainActor
final class RectangleMarkupTests: XCTestCase {
    func testMarkupsListNavigationSearchBatchDeleteUndoAndSave() throws {
        _ = NSApplication.shared
        let source = try fixture(rotation: 0)
        let output = source.deletingLastPathComponent().appendingPathComponent("MarkupList-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let seed = try XCTUnwrap(PDFDocument(url: source))
        let secondPage = PDFPage(); secondPage.setBounds(CGRect(x: 0,y: 0,width: 600,height: 400), for: .mediaBox)
        seed.insert(secondPage, at: 1)
        let external = PDFAnnotation(bounds: CGRect(x: 100,y: 100,width: 80,height: 60), forType: .circle, withProperties: nil)
        external.userName = "Consultant"; external.contents = "Review this"; secondPage.addAnnotation(external)
        let locked = PDFAnnotation(bounds: CGRect(x: 200,y: 100,width: 80,height: 60), forType: .square, withProperties: nil)
        locked.setValue(64, forAnnotationKey: PDFAnnotationKey(rawValue: "/F")); locked.userName = "Reviewer"; secondPage.addAnnotation(locked)
        XCTAssertTrue(seed.write(to: source))
        let controller = MainViewController(); _ = controller.view; controller.openDocument(at: source)
        let document = try XCTUnwrap(controller.pdfView.document), page = try XCTUnwrap(document.page(at: 0))
        let session = controller.pdfView.rectangleMarkup; session.canEdit = { true }; session.undo.groupsByEvent = false
        document.page(at: 1)?.annotations.first { $0.userName == "Reviewer" }?.isReadOnly = true
        session.undo.beginUndoGrouping()
        let added = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 100,y: 110,width: 80,height: 60)))
        session.undo.endUndoGrouping()
        controller.commandToggleMarkupsList(nil); controller.refreshMarkups()
        XCTAssertTrue(controller.isMarkupsPanelVisible)
        XCTAssertFalse(controller.markupItems.contains { $0.annotation.type == "Link" })
        XCTAssertTrue(controller.markupItems.contains { $0.annotation.isReadOnly })
        let externalRow = try XCTUnwrap(controller.markupItems.firstIndex { $0.annotation.userName == "Consultant" })
        controller.markupsTable.selectRowIndexes(IndexSet(integer: externalRow), byExtendingSelection: false)
        controller.jumpToSelectedMarkup()
        XCTAssertEqual(controller.pdfView.currentPage, document.page(at: 1))
        XCTAssertEqual(session.selected?.userName, "Consultant")
        controller.markupsSearchField.stringValue = "Consultant"; controller.filterListedMarkups(nil); controller.refreshMarkups()
        XCTAssertEqual(controller.markupItems.count, 1)
        controller.markupsSearchField.stringValue = ""; controller.filterListedMarkups(nil); controller.refreshMarkups()
        let rows = IndexSet(controller.markupItems.indices.filter { controller.markupItems[$0].annotation === added || controller.markupItems[$0].annotation.userName == "Consultant" })
        XCTAssertEqual(rows.count, 2)
        controller.markupsTable.selectRowIndexes(rows, byExtendingSelection: false)
        controller.deleteListedMarkups(nil); controller.refreshMarkups()
        XCTAssertFalse(controller.markupItems.contains { $0.annotation === added || $0.annotation.userName == "Consultant" })
        session.undo.undo(); controller.refreshMarkups()
        XCTAssertTrue(controller.markupItems.contains { $0.annotation === added })
        XCTAssertTrue(controller.markupItems.contains { $0.annotation.userName == "Consultant" })
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(document), importedPlan: session.importedPlan()))
        XCTAssertEqual(PDFDocument(url: output)?.page(at: 1)?.annotations.first { $0.userName == "Consultant" }?.contents, "Review this")
    }

    func testSelectionOverlaysStayOnSelectedMarkupPage() throws {
        _ = NSApplication.shared
        let source = try fixture(rotation: 0)
        defer { try? FileManager.default.removeItem(at: source) }
        let seed = try XCTUnwrap(PDFDocument(url: source))
        let second = PDFPage(); second.setBounds(CGRect(x: 0, y: 0, width: 600, height: 400), for: .mediaBox)
        seed.insert(second, at: 1); XCTAssertTrue(seed.write(to: source))
        let controller = MainViewController(); _ = controller.view; controller.openDocument(at: source)
        let view = controller.pdfView, first = try XCTUnwrap(view.document?.page(at: 0))
        let session = view.rectangleMarkup; session.canEdit = { true }
        let text = try XCTUnwrap(session.create(on: first, bounds: CGRect(x: 100, y: 100, width: 90, height: 50), kind: .text, text: "Review"))
        controller.commandToggleMarkupsList(nil); controller.refreshMarkups()
        let row = try XCTUnwrap(controller.markupItems.firstIndex { $0.annotation === text })
        controller.markupsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        view.go(to: first); controller.updateSelectionOverlay(); session.refresh()
        let textOverlay = try XCTUnwrap(view.layer?.sublayers?.first { $0.name == "drawbridge.textSelection" } as? CAShapeLayer)
        let activeOverlay = try XCTUnwrap(view.layer?.sublayers?.first { $0.name == "drawbridge.activeMarkupSelection" } as? CAShapeLayer)
        XCTAssertFalse(textOverlay.isHidden)
        XCTAssertFalse(try XCTUnwrap(activeOverlay.path).isEmpty)
        view.go(to: try XCTUnwrap(view.document?.page(at: 1)))
        XCTAssertTrue(textOverlay.isHidden, "Page navigation must immediately hide the list selection overlay")
        XCTAssertTrue(try XCTUnwrap(activeOverlay.path).isEmpty, "The drawing selection must not project onto another page")
        controller.updateSelectionOverlay(); session.refresh()
        XCTAssertTrue(textOverlay.isHidden)
        XCTAssertTrue(try XCTUnwrap(activeOverlay.path).isEmpty)
        view.go(to: first); controller.updateSelectionOverlay(); session.refresh()
        XCTAssertFalse(textOverlay.isHidden)
        XCTAssertFalse(try XCTUnwrap(activeOverlay.path).isEmpty)
    }

    func testMarkupNavigationCentersDestinationAndTracksScrolling() async throws {
        _ = NSApplication.shared
        let controller = MainViewController()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { window.contentViewController = nil }
        let document = PDFDocument()
        for _ in 0..<4 {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 1600, height: 2400), for: .mediaBox)
            document.insert(page, at: document.pageCount)
        }
        let view = controller.pdfView
        view.document = document
        view.rectangleMarkup.bind(to: document)
        view.autoScales = false; view.scaleFactor = 1
        window.contentView?.layoutSubtreeIfNeeded()
        let targetPage = try XCTUnwrap(document.page(at: 3))
        let target = PDFAnnotation(bounds: CGRect(x: 700, y: 500, width: 120, height: 60),
                                   forType: .freeText, withProperties: nil)
        target.contents = "Destination"; targetPage.addAnnotation(target)
        controller.commandToggleMarkupsList(nil); controller.refreshMarkups()
        window.contentView?.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(controller.markupItems.firstIndex { $0.annotation === target })
        controller.markupsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        controller.jumpToSelectedMarkup()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(view.currentPage === targetPage)
        XCTAssertEqual(view.scaleFactor, 1, accuracy: 0.001)
        let documentView = try XCTUnwrap(view.documentView)
        let clip = try XCTUnwrap(documentView.enclosingScrollView?.contentView)
        let targetRect = documentView.convert(view.convert(target.bounds, from: targetPage), from: view)
        XCTAssertEqual(targetRect.midX, clip.bounds.midX, accuracy: 3)
        XCTAssertEqual(targetRect.midY, clip.bounds.midY, accuracy: 3)
        let overlay = try XCTUnwrap(view.layer?.sublayers?.first { $0.name == "drawbridge.activeMarkupSelection" } as? CAShapeLayer)
        clip.scroll(to: clip.bounds.origin.applying(CGAffineTransform(translationX: 0, y: 100)))
        try await Task.sleep(nanoseconds: 50_000_000)
        let expected = view.convert(target.bounds, from: targetPage).standardized
        let drawn = try XCTUnwrap(overlay.path).boundingBoxOfPath
        XCTAssertEqual(drawn.midX, expected.midX, accuracy: 1)
        XCTAssertEqual(drawn.midY, expected.midY, accuracy: 1)
    }

    func testMarkupAuthorPreferenceDefaultsAndOverride() {
        let suite = "DrawbridgeAuthorTest-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MarkupAuthorPreference.name(defaults: defaults, accountName: "Mac User"), "Mac User")
        defaults.set("  Alex García  ", forKey: MarkupAuthorPreference.defaultsKey)
        XCTAssertEqual(MarkupAuthorPreference.name(defaults: defaults, accountName: "Mac User"), "Alex García")
        defaults.set("   ", forKey: MarkupAuthorPreference.defaultsKey)
        XCTAssertEqual(MarkupAuthorPreference.name(defaults: defaults, accountName: "Mac User"), "Mac User")
    }

    func testEveryMarkupAuthorSurvivesSavingReopeningAndEditing() throws {
        let source = try fixture(rotation: 0)
        let output = source.deletingLastPathComponent().appendingPathComponent("Authors-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let doc = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(doc.page(at: 0))
        let session = RectangleMarkupController(); session.bind(to: doc)
        let points = [CGPoint(x: 110,y: 110), CGPoint(x: 180,y: 130), CGPoint(x: 150,y: 170)]
        for kind in [RectangleMarkupRecord.Kind.rectangle, .ellipse, .line, .arrow, .text, .polyline, .polygon] {
            let annotation = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 100,y: 100,width: 100,height: 100), kind: kind, endpoints: kind == .line || kind == .arrow ? (points[0],points[1]) : nil, text: "Author test", vertices: points))
            XCTAssertEqual(annotation.userName, MarkupAuthorPreference.currentName)
            annotation.setValue("Alex García (Design)", forAnnotationKey: PDFAnnotationKey(rawValue: "/T"))
        }
        let records = RectangleMarkupRecord.capture(doc)
        XCTAssertEqual(records.count, 7)
        XCTAssertEqual(Set(records.map(\.id)).count, 7, "Shared author must never become shared markup identity")
        let bytes = try Data(contentsOf: source)
        XCTAssertTrue(PDFRectangleWriter.write(document: doc, source: source, destination: output, pageLabels: [:], records: records))
        let saved = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(RectangleMarkupRecord.capture(saved), records)
        for annotation in try XCTUnwrap(saved.page(at: 0)).annotations where RectangleMarkupRecord.owns(annotation) {
            XCTAssertEqual(annotation.userName, "Alex García (Design)")
        }
        let editing = RectangleMarkupController(); editing.bind(to: saved)
        let polygon = try XCTUnwrap(saved.page(at: 0)?.annotations.first { $0.type == "Polygon" })
        XCTAssertTrue(RectangleMarkupRecord.owns(polygon), "Polygon replacement must retain identity")
        XCTAssertEqual(polygon.userName, "Alex García (Design)")
        editing.setBounds(polygon.bounds.offsetBy(dx: 5,dy: 5), of: polygon, on: saved.page(at: 0)!, action: "Move")
        XCTAssertTrue(PDFRectangleWriter.write(document: saved, source: output, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(saved)))
        XCTAssertEqual(PDFDocument(url: output)?.page(at: 0)?.annotations.filter(RectangleMarkupRecord.owns).count, 7)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testLegacyInternalAuthorMigratesWithoutLosingIdentity() throws {
        let source = try fixture(rotation: 0)
        let output = source.deletingLastPathComponent().appendingPathComponent("LegacyAuthor-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let doc = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(doc.page(at: 0))
        let legacy = PDFAnnotation(bounds: CGRect(x: 100,y: 110,width: 80,height: 60), forType: .square, withProperties: nil)
        let id = RectangleMarkupRecord.prefix + UUID().uuidString
        legacy.userName = id; legacy.color = .red; page.addAnnotation(legacy)
        XCTAssertTrue(RectangleMarkupRecord.owns(legacy))
        let records = RectangleMarkupRecord.capture(doc)
        XCTAssertEqual(records.first?.id, id)
        XCTAssertEqual(records.first?.author, MarkupAuthorPreference.currentName)
        XCTAssertTrue(PDFRectangleWriter.write(document: doc, source: source, destination: output, pageLabels: [:], records: records))
        let saved = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(RectangleMarkupRecord.capture(saved), records)
        XCTAssertEqual(saved.page(at: 0)?.annotations.first(where: RectangleMarkupRecord.owns)?.userName, MarkupAuthorPreference.currentName)
    }

    func testLargeRealDrawingSetsMixedMarkupSaves() async throws {
        guard let manifest = ProcessInfo.processInfo.environment["DRAWBRIDGE_LARGE_SAVE_MANIFEST"] else { throw XCTSkip("Optional real drawing-set manifest") }
        _ = NSApplication.shared
        let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        let output = URL(fileURLWithPath: manifest).deletingLastPathComponent()
        var results: [[String: Any]] = []
        for (index, path) in paths.enumerated() {
            let input = URL(fileURLWithPath: path)
            let source = output.appendingPathComponent("case-\(index + 1)-saved.pdf")
            if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.removeItem(at: source) }
            try FileManager.default.copyItem(at: input, to: source)
            let original = try Data(contentsOf: source, options: .mappedIfSafe)
            let controller = MainViewController(); _ = controller.view
            controller.openDocument(at: source)
            let document = try XCTUnwrap(controller.pdfView.document)
            let session = controller.pdfView.rectangleMarkup; session.canEdit = { true }
            let geometry = (0..<document.pageCount).map { document.page(at: $0)!.bounds(for: .cropBox) }
            let rotations = (0..<document.pageCount).map { document.page(at: $0)!.rotation }
            var timings: [Double] = []
            for pass in 0..<3 {
                let count = pass == 1 ? 100 : 6
                for offset in 0..<count {
                    let page = document.page(at: (offset * max(1, document.pageCount / count)) % document.pageCount)!
                    let crop = page.bounds(for: .cropBox)
                    let bounds = CGRect(x: crop.minX + 30 + CGFloat(offset % 4) * 50, y: crop.minY + 30 + CGFloat(pass) * 100, width: 100, height: 60)
                    let a = CGPoint(x: bounds.minX + 5, y: bounds.minY + 5), b = CGPoint(x: bounds.maxX - 5, y: bounds.maxY - 5)
                    let kinds: [RectangleMarkupRecord.Kind] = [.rectangle, .ellipse, .line, .arrow, .text, .polyline, .polygon]
                    let kind = kinds[offset % kinds.count]
                    session.fillColor = .orange
                    _ = try XCTUnwrap(session.create(on: page, bounds: bounds, kind: kind,
                        endpoints: kind == .line || kind == .arrow ? (a, b) : nil,
                        text: "SAVE QA \(pass + 1)-\(offset + 1)",
                        vertices: [a, CGPoint(x: bounds.midX, y: b.y), CGPoint(x: b.x, y: a.y)]))
                }
                let expected = RectangleMarkupRecord.capture(document)
                let start = Date()
                let saved = await withCheckedContinuation { continuation in
                    controller.persistDocument(to: source, adoptAsPrimaryDocument: false, busyMessage: "Saving PDF…", showBusyOverlay: false) { continuation.resume(returning: $0) }
                }
                let elapsed = Date().timeIntervalSince(start); timings.append(elapsed)
                print("REAL DRAWING SAVE case=\(index + 1) pages=\(document.pageCount) MiB=\(original.count / 1048576) new=\(count) seconds=\(elapsed)")
                XCTAssertTrue(saved, input.lastPathComponent)
                XCTAssertFalse(session.hasUnsavedChanges)
                XCTAssertEqual(try Data(contentsOf: source, options: .mappedIfSafe).prefix(original.count), original)
                let reopened = try XCTUnwrap(PDFDocument(url: source))
                XCTAssertEqual(RectangleMarkupRecord.capture(reopened), expected)
                XCTAssertEqual((0..<reopened.pageCount).map { reopened.page(at: $0)!.bounds(for: .cropBox) }, geometry)
                XCTAssertEqual((0..<reopened.pageCount).map { reopened.page(at: $0)!.rotation }, rotations)
            }
            results.append(["case": index + 1, "name": input.lastPathComponent, "pages": document.pageCount, "bytes": original.count, "save_seconds": timings, "output": source.path])
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
    }

    func testRepeatedSaveCoalescesBeforeMissingSourceRecovery() throws {
        _ = NSApplication.shared
        let source = try fixture(rotation: 0)
        defer { try? FileManager.default.removeItem(at: source) }
        let controller = MainViewController(); _ = controller.view
        controller.openDocument(at: source)
        controller.persistenceCoordinator.beginManualSave()
        try FileManager.default.removeItem(at: source)
        var result: Bool?
        controller.persistDocument(to: source, adoptAsPrimaryDocument: false, busyMessage: "Saving PDF…", showBusyOverlay: false) { result = $0 }
        XCTAssertEqual(result, false)
        XCTAssertTrue(controller.queuedFastEmbeddedSave)
        XCTAssertEqual(controller.openDocumentURL, source)
    }

    func testImmediateSaveAfterRealOpenThenRepeatedSaves() async throws {
        guard let root = ProcessInfo.processInfo.environment["DRAWBRIDGE_RECTANGLE_CORPUS"] else { throw XCTSkip("Optional large drawing corpus") }
        _ = NSApplication.shared
        let source = try fixture(rotation: 0)
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("architectural-mech.pdf")).write(to: source)
        let original = try Data(contentsOf: source)
        let controller = MainViewController(); _ = controller.view
        controller.openDocument(at: source)
        let document = try XCTUnwrap(controller.pdfView.document), page = try XCTUnwrap(document.page(at: 0))
        controller.pdfView.rectangleMarkup.canEdit = { true }
        for pass in 1...3 {
            for offset in 0..<6 {
                _ = try XCTUnwrap(controller.pdfView.rectangleMarkup.create(on: page, bounds: CGRect(x: 100 + offset * 20,y: 100 + pass * 20,width: 40,height: 40)))
            }
            let started = Date()
            let saved = await withCheckedContinuation { continuation in
                controller.persistDocument(to: source, adoptAsPrimaryDocument: false, busyMessage: "Saving PDF…", showBusyOverlay: false) { continuation.resume(returning: $0) }
            }
            let elapsed = Date().timeIntervalSince(started)
            print("IMMEDIATE REAL-OPEN SAVE (pass \(pass)): \(elapsed)s")
            XCTAssertTrue(saved)
            XCTAssertLessThan(elapsed, pass == 1 ? 2 : 1)
            XCTAssertEqual(try Data(contentsOf: source).prefix(original.count), original)
        }
    }

    func testCommittedStampDoesNotAdoptExternalEditsAfterSave() throws {
        let source = try fixture(rotation: 0), replacement = try fixture(rotation: 90)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: replacement) }
        let external = try Data(contentsOf: replacement)
        let document = try XCTUnwrap(PDFDocument(url: source)), session = RectangleMarkupController()
        session.bind(to: document)
        _ = try XCTUnwrap(session.create(on: document.page(at: 0)!, bounds: CGRect(x: 100,y: 100,width: 80,height: 60)))
        var committed: PDFMarkupSourceStamp?
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: source, pageLabels: [:], records: RectangleMarkupRecord.capture(document), expectedSourceStamp: session.sourceStamp, onCommitted: {
            committed = $0
            // Model a watcher replacing the PDF after the verified commit but
            // before the UI gets its save-completion callback.
            try? external.write(to: source, options: .atomic)
        }))
        session.acceptPersistedSource(at: source, stamp: try XCTUnwrap(committed))
        session.markSaved(at: source, stamp: committed)
        XCTAssertFalse(try XCTUnwrap(session.sourceStamp).matchesSource(source))
        XCTAssertFalse(PDFRectangleWriter.write(document: document, source: source, destination: source, pageLabels: [:], records: RectangleMarkupRecord.capture(document), expectedSourceStamp: session.sourceStamp))
        XCTAssertEqual(try Data(contentsOf: source), external)
    }

    func testMarkupSaveUsesFrozenNavigationWhileLiveDocumentChanges() throws {
        let source = try fixture(rotation: 90)
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        let root = PDFOutline(), child = PDFOutline()
        child.label = "At save start"; child.destination = PDFDestination(page: page, at: .zero)
        root.insertChild(child, at: 0); document.outlineRoot = root
        let link = PDFAnnotation(bounds: CGRect(x: 100,y: 100,width: 40,height: 20), forType: .link, withProperties: nil)
        link.contents = "DrawbridgeAutoSheetLink QA"; link.action = PDFActionGoTo(destination: PDFDestination(page: page, at: .zero))
        page.addAnnotation(link)
        let navigation = PDFTKBookmarkWriter.captureNavigation(in: document)
        let session = RectangleMarkupController(); session.bind(to: document)
        _ = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 120,y: 140,width: 80,height: 60)))
        child.label = "Newer unsaved navigation"; page.removeAnnotation(link)
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: source, pageLabels: [:], records: RectangleMarkupRecord.capture(document), navigationSnapshot: navigation))
        let saved = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(saved.outlineRoot?.child(at: 0)?.label, "At save start")
        XCTAssertEqual(saved.page(at: 0)?.annotations.filter { $0.contents == "DrawbridgeAutoSheetLink QA" }.count, 1)
        XCTAssertEqual(child.label, "Newer unsaved navigation")
        XCTAssertFalse(page.annotations.contains(link))
    }

    func testIdenticalAtomicSourceReplacementStillSavesMarkups() throws {
        let source = try fixture(rotation: 90)
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)
        let document = try XCTUnwrap(PDFDocument(url: source)), session = RectangleMarkupController()
        session.bind(to: document)
        let stamp = try XCTUnwrap(session.sourceStamp)
        _ = try XCTUnwrap(session.create(on: document.page(at: 0)!, bounds: CGRect(x: 100,y: 100,width: 80,height: 60)))
        try original.write(to: source, options: .atomic)
        XCTAssertNotEqual(stamp, PDFMarkupSourceStamp.read(source))
        XCTAssertTrue(stamp.matchesSource(source))
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: source, pageLabels: [:], records: RectangleMarkupRecord.capture(document), expectedSourceStamp: stamp))
        XCTAssertEqual(try Data(contentsOf: source).prefix(original.count), original)
    }

    func testSaveAsUsesFrozenOriginalAfterExternalContentChange() async throws {
        _ = NSApplication.shared
        let source = try fixture(rotation: 0), replacement = try fixture(rotation: 90)
        let copy = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".pdf")
        defer { for url in [source, replacement, copy] { try? FileManager.default.removeItem(at: url) } }
        let original = try Data(contentsOf: source), external = try Data(contentsOf: replacement)
        let controller = MainViewController(); _ = controller.view
        controller.openDocument(at: source)
        let document = try XCTUnwrap(controller.pdfView.document), session = controller.pdfView.rectangleMarkup
        session.canEdit = { true }
        _ = try XCTUnwrap(session.create(on: document.page(at: 0)!, bounds: CGRect(x: 100,y: 100,width: 80,height: 60)))
        try external.write(to: source, options: .atomic)
        var failure: PDFRectangleWriter.SaveFailure?
        XCTAssertFalse(PDFRectangleWriter.write(document: document, source: source, destination: source, pageLabels: [:], records: RectangleMarkupRecord.capture(document), expectedSourceStamp: session.sourceStamp, onFailure: { failure = $0 }))
        XCTAssertEqual(failure?.stage, "source changed since opening")
        let saved = await withCheckedContinuation { continuation in
            controller.persistDocument(to: copy, adoptAsPrimaryDocument: true, busyMessage: "Saving PDF…", showBusyOverlay: false) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(saved)
        XCTAssertEqual(try Data(contentsOf: source), external)
        XCTAssertEqual(try Data(contentsOf: copy).prefix(original.count), original)
        let reopened = try XCTUnwrap(PDFDocument(url: copy))
        XCTAssertEqual(reopened.page(at: 0)?.rotation, 0)
        XCTAssertEqual(RectangleMarkupRecord.capture(reopened).count, 1)
    }

    func testMarkupSaveFollowsRenamedFolderAfterNavigationSave() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("Original"), moved = root.appendingPathComponent("Renamed")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtureURL = try fixture(rotation: 90)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let source = folder.appendingPathComponent("Plans.pdf")
        let input = ProcessInfo.processInfo.environment["DRAWBRIDGE_RELOCATED_FIXTURE"].map(URL.init(fileURLWithPath:)) ?? fixtureURL
        try FileManager.default.copyItem(at: input, to: source)
        let controller = MainViewController(); _ = controller.view
        controller.openDocument(at: source)
        let document = try XCTUnwrap(controller.pdfView.document)
        // Navigation saving replaces the file and leaves PDFKit with an open,
        // deleted temporary backing file. Rebind the known committed source.
        XCTAssertEqual(PDFTKBookmarkWriter.writeNavigation(in: document, sourceURL: source, to: source, pageLabels: [0: "S310"]), .saved)
        controller.pdfView.rectangleMarkup.acceptPersistedSource(at: source)
        let original = try Data(contentsOf: source)
        try FileManager.default.moveItem(at: folder, to: moved)
        let relocated = moved.appendingPathComponent("Plans.pdf")
        let session = controller.pdfView.rectangleMarkup
        session.canEdit = { true }
        _ = try XCTUnwrap(session.create(on: document.page(at: 0)!, bounds: CGRect(x: 100,y: 100,width: 80,height: 60)))
        let saved = await withCheckedContinuation { continuation in
            controller.persistDocument(to: source, adoptAsPrimaryDocument: false, busyMessage: "Saving PDF…", showBusyOverlay: false) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(saved)
        XCTAssertEqual(controller.openDocumentURL?.standardizedFileURL, relocated.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try Data(contentsOf: relocated).prefix(original.count), original)
        XCTAssertEqual(RectangleMarkupRecord.capture(try XCTUnwrap(PDFDocument(url: relocated))).count, 1)
        XCTAssertFalse(session.hasUnsavedChanges)
    }

    func testRelocatedSourceRejectsChangedContents() throws {
        let source = try fixture(rotation: 180)
        let moved = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: moved) }
        let stamp = try XCTUnwrap(PDFMarkupSourceStamp.capture(source))
        try FileManager.default.moveItem(at: source, to: moved)
        XCTAssertEqual(stamp.resolvedSourceURL(preferred: source)?.standardizedFileURL, moved.standardizedFileURL)
        var bytes = try Data(contentsOf: moved)
        let range = try XCTUnwrap(bytes.range(of: Data("/Rotate 180".utf8)))
        bytes.replaceSubrange(range, with: Data("/Rotate 270".utf8))
        try bytes.write(to: moved)
        XCTAssertNil(stamp.resolvedSourceURL(preferred: source))
    }

    func testMissingOriginalRecoversMarkupsIntoNewCopyWithoutRewritingPages() async throws {
        _ = NSApplication.shared
        let source = try fixture(rotation: 180)
        if let input = ProcessInfo.processInfo.environment["DRAWBRIDGE_RELOCATED_FIXTURE"] {
            try Data(contentsOf: URL(fileURLWithPath: input)).write(to: source)
        }
        let recovered = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: recovered) }
        let original = try Data(contentsOf: source)
        let controller = MainViewController(); _ = controller.view
        controller.openDocument(at: source)
        let document = try XCTUnwrap(controller.pdfView.document)
        let session = controller.pdfView.rectangleMarkup
        session.canEdit = { true }
        _ = try XCTUnwrap(session.create(on: document.page(at: 0)!, bounds: CGRect(x: 100,y: 100,width: 80,height: 60)))
        try FileManager.default.removeItem(at: source)
        let saved = await withCheckedContinuation { continuation in
            controller.persistDocument(to: recovered, adoptAsPrimaryDocument: true, busyMessage: "Saving PDF…", showBusyOverlay: false) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(saved)
        XCTAssertEqual(try Data(contentsOf: recovered).prefix(original.count), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(RectangleMarkupRecord.capture(try XCTUnwrap(PDFDocument(url: recovered))).count, 1)
        XCTAssertEqual(controller.openDocumentURL?.standardizedFileURL, recovered.standardizedFileURL)
        XCTAssertFalse(session.hasUnsavedChanges)
    }

    func testQueuedSavePersistsEditsMadeAfterFirstSaveSnapshot() async throws {
        _ = NSApplication.shared
        let source = try fixture(rotation: 0)
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        let page = try XCTUnwrap(document.page(at: 0))
        let controller = MainViewController(); _ = controller.view
        controller.openDocumentURL = source
        controller.pdfView.setMarkupDocument(document)
        let session = controller.pdfView.rectangleMarkup
        // Model an edit arriving after capture, independent of UI lock timing.
        session.canEdit = { true }
        _ = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 100, y: 100, width: 40, height: 40)))
        let saved = await withCheckedContinuation { continuation in
            controller.persistDocument(to: source, adoptAsPrimaryDocument: false, busyMessage: "Saving PDF…", showBusyOverlay: false) {
                continuation.resume(returning: $0)
            }
            _ = session.create(on: page, bounds: CGRect(x: 200, y: 100, width: 40, height: 40))
            controller.persistDocument(to: source, adoptAsPrimaryDocument: false, busyMessage: "Saving PDF…", showBusyOverlay: false)
            XCTAssertTrue(controller.queuedFastEmbeddedSave)
        }
        XCTAssertTrue(saved)
        let deadline = Date().addingTimeInterval(5)
        while controller.isSavingDocumentOperation, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.isSavingDocumentOperation)
        XCTAssertFalse(controller.queuedFastEmbeddedSave)
        XCTAssertFalse(session.hasUnsavedChanges)
        let reopened = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(RectangleMarkupRecord.capture(reopened), RectangleMarkupRecord.capture(document))
        XCTAssertEqual(RectangleMarkupRecord.capture(reopened).count, 2)
    }

    func testPointerPreviewsDoNotRefreshToolbarUntilCommit() throws {
        _ = NSApplication.shared
        let source = try fixture(rotation: 0)
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        let page = try XCTUnwrap(document.page(at: 0))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let view = MarkupPDFView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        view.document = document
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
        let session = view.rectangleMarkup
        session.bind(to: document)
        let crop = page.bounds(for: view.displayBox)
        let start = view.convert(CGPoint(x: crop.midX - 50, y: crop.midY - 40), from: page)
        let end = view.convert(CGPoint(x: crop.midX + 50, y: crop.midY + 40), from: page)
        var toolbarRefreshes = 0
        session.onPresentationChanged = { toolbarRefreshes += 1 }
        for tool in [RectangleMarkupController.Tool.line, .arrow, .rectangle, .ellipse, .polyline, .polygon] {
            session.tool = tool
            XCTAssertTrue(session.pointerDown(at: start))
            toolbarRefreshes = 0
            for _ in 0..<100 {
                if tool == .rectangle || tool == .ellipse {
                    XCTAssertTrue(session.pointerDragged(at: end))
                } else { session.pointerMoved(at: end) }
            }
            XCTAssertEqual(toolbarRefreshes, 0, "Geometry-only previews should not redraw toolbar controls")
            if tool == .line || tool == .arrow {
                XCTAssertTrue(session.pointerDown(at: end))
                XCTAssertGreaterThan(toolbarRefreshes, 0)
                XCTAssertEqual(session.tool, .select)
            } else if tool == .rectangle || tool == .ellipse {
                XCTAssertTrue(session.pointerUp(at: end))
                XCTAssertGreaterThan(toolbarRefreshes, 0)
            }
            session.escape()
        }
    }

    func testLineAndArrowUseTwoClicksAndEscapeCancelsDraft() throws {
        _ = NSApplication.shared
        for rotation in [0, 90, 180, 270] {
            let source = try fixture(rotation: rotation)
            defer { try? FileManager.default.removeItem(at: source) }
            let document = try XCTUnwrap(PDFDocument(url: source))
            let page = try XCTUnwrap(document.page(at: 0))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            let view = MarkupPDFView(frame: window.contentView!.bounds)
            window.contentView?.addSubview(view)
            view.document = document; window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
            let session = view.rectangleMarkup
            session.bind(to: document)
            let crop = page.bounds(for: view.displayBox)
            let a = CGPoint(x: crop.midX-50, y: crop.midY-40)
            let b = CGPoint(x: crop.midX+50, y: crop.midY+40)
            let start = view.convert(a, from: page), end = view.convert(b, from: page)
            for (key, tool) in [("l", RectangleMarkupController.Tool.line), ("a", .arrow)] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
                XCTAssertTrue(session.handleToolShortcut(event)); XCTAssertEqual(session.tool, tool)
                let count = page.annotations.count
                XCTAssertTrue(session.pointerDown(at: start))
                XCTAssertTrue(session.pointerUp(at: start))
                session.pointerMoved(at: end)
                XCTAssertTrue(session.pointerDragged(at: end))
                XCTAssertTrue(session.pointerUp(at: end))
                XCTAssertEqual(page.annotations.count, count, "Releasing the mouse must not finish the draft")
                XCTAssertTrue(session.pointerDown(at: start))
                XCTAssertEqual(page.annotations.count, count, "A zero-length second click must not create a markup")
                XCTAssertTrue(session.pointerDown(at: end))
                _ = session.pointerUp(at: end)
                XCTAssertEqual(page.annotations.count, count+1)
                XCTAssertEqual(session.tool, .select)
                let annotation = try XCTUnwrap(page.annotations.last)
                XCTAssertEqual(annotation.endLineStyle, tool == .arrow ? .openArrow : .none)
                XCTAssertEqual(annotation.bounds.minX+annotation.startPoint.x, a.x, accuracy: 0.001)
                XCTAssertEqual(annotation.bounds.minY+annotation.startPoint.y, a.y, accuracy: 0.001)
                XCTAssertEqual(annotation.bounds.minX+annotation.endPoint.x, b.x, accuracy: 0.001)
                XCTAssertEqual(annotation.bounds.minY+annotation.endPoint.y, b.y, accuracy: 0.001)
            }
            session.tool = .line
            XCTAssertTrue(session.pointerDown(at: start)); _ = session.pointerUp(at: start)
            let count = page.annotations.count
            session.escape(); session.pointerMoved(at: end); _ = session.pointerUp(at: end)
            XCTAssertEqual(session.tool, .select); XCTAssertEqual(page.annotations.count, count)
        }
    }

    func testShapeHitTestingRejectsEmptyBoundingBoxSpace() throws {
        let source = try fixture(rotation:0); defer { try? FileManager.default.removeItem(at:source) }
        let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
        let s = RectangleMarkupController(); s.bind(to:doc)
        let a = CGPoint(x:100,y:100), b = CGPoint(x:300,y:300)
        let line = try XCTUnwrap(s.create(on:page,bounds:RectangleMarkupController.lineBounds(a,b,width:2),kind:.line,endpoints:(a,b)))
        XCTAssertTrue(RectangleMarkupController.hitTest(line,at:CGPoint(x:200,y:203),tolerance:4))
        XCTAssertFalse(RectangleMarkupController.hitTest(line,at:CGPoint(x:110,y:290),tolerance:4))
        let ellipse = try XCTUnwrap(s.create(on:page,bounds:CGRect(x:100,y:100,width:200,height:100),kind:.ellipse))
        XCTAssertFalse(RectangleMarkupController.hitTest(ellipse,at:CGPoint(x:102,y:198),tolerance:4))
        XCTAssertTrue(RectangleMarkupController.hitTest(ellipse,at:CGPoint(x:200,y:150),tolerance:4))
    }

    func testUnchangedSelectionAndStyleDoNotDirtyPDFOrConsumeUndo() throws {
        let source = try fixture(rotation:0); defer { try? FileManager.default.removeItem(at:source) }
        let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
        let s = RectangleMarkupController(); s.bind(to:doc)
        let annotation = try XCTUnwrap(s.create(on:page,bounds:CGRect(x:100,y:100,width:100,height:80)))
        s.undo.removeAllActions(); s.markSaved(at:source)
        var mutations = 0; s.onMutation = { _ in mutations += 1 }
        s.setBounds(annotation.bounds,of:annotation,on:page,action:"Move Markup")
        s.styleSelected(color:annotation.color,width:annotation.border!.lineWidth)
        XCTAssertFalse(s.undo.canUndo); XCTAssertFalse(s.hasUnsavedChanges); XCTAssertEqual(mutations,0)
        annotation.isReadOnly = true
        s.setBounds(annotation.bounds.offsetBy(dx:10,dy:10),of:annotation,on:page,action:"Move Markup")
        s.deleteSelected()
        XCTAssertTrue(annotation.page === page); XCTAssertFalse(s.undo.canUndo)
    }

    func testAuthoringToolbarRestoresDrawingDefaultsAfterSelection() throws {
        _ = NSApplication.shared
        let source = try fixture(rotation:0); defer { try? FileManager.default.removeItem(at:source) }
        let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
        let c = MainViewController(); _ = c.view
        c.pdfView.setMarkupDocument(doc)
        let s = c.pdfView.rectangleMarkup; s.canEdit = { true }
        _ = try XCTUnwrap(s.create(on:page,bounds:CGRect(x:100,y:100,width:100,height:80)))
        s.strokeColor = .blue; s.lineWidth = 8; s.fontSize = 36
        c.refreshRectangleToolbar()
        XCTAssertEqual(c.rectangleToolbar.colorPopup.titleOfSelectedItem,"Red")
        s.tool = .text
        XCTAssertEqual(c.rectangleToolbar.colorPopup.titleOfSelectedItem,"Blue")
        XCTAssertEqual(c.rectangleToolbar.widthPopup.titleOfSelectedItem,"8 pt")
        XCTAssertEqual(c.rectangleToolbar.fontPopup.titleOfSelectedItem,"36 pt")
    }

    func testInlineTextStylePreviewMatchesCommittedAnnotation() throws {
        let source = try fixture(rotation:0); defer { try? FileManager.default.removeItem(at:source) }
        let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
        let view = PDFView(frame:CGRect(x:0,y:0,width:800,height:600)); view.document = doc
        let s = RectangleMarkupController(); s.install(on:view); s.bind(to:doc)
        s.beginTextEditing(on:page,bounds:CGRect(x:140,y:140,width:180,height:80))
        let editor = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
        editor.string = "Visible style"
        s.styleSelected(color:.blue,width:2); s.fontSize = 36; s.refresh()
        XCTAssertEqual(editor.textColor,.blue)
        XCTAssertEqual(editor.font!.pointSize,36*view.scaleFactor,accuracy:0.01)
        s.finishTextEditing()
        let annotation = try XCTUnwrap(s.selected)
        XCTAssertEqual(RectangleMarkupRecord.markupColor(annotation).usingColorSpace(.deviceRGB),NSColor.blue.usingColorSpace(.deviceRGB))
        XCTAssertEqual(annotation.font?.pointSize,36)
    }

    func testInlineTextUndoIsIsolatedFromMarkupHistory() throws {
        let source = try fixture(rotation:0); defer { try? FileManager.default.removeItem(at:source) }
        let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
        let view = PDFView(frame:CGRect(x:0,y:0,width:800,height:600)); view.document = doc
        let s = RectangleMarkupController(); s.install(on:view); s.bind(to:doc)
        let markupUndo = s.undo; markupUndo.groupsByEvent = false
        markupUndo.beginUndoGrouping()
        let shape = try XCTUnwrap(s.create(on:page,bounds:CGRect(x:100,y:100,width:80,height:60)))
        markupUndo.endUndoGrouping()
        s.beginTextEditing(on:page,bounds:CGRect(x:140,y:140,width:180,height:80))
        let editor = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
        XCTAssertFalse(s.undo === markupUndo)
        XCTAssertTrue(editor.allowsUndo)
        s.undo.groupsByEvent = false; s.undo.beginUndoGrouping()
        editor.insertText("Draft",replacementRange:NSRange(location:0,length:0))
        s.undo.endUndoGrouping()
        XCTAssertEqual(editor.string,"Draft")
        XCTAssertTrue(editor.responds(to:#selector(MarkupInlineTextView.undo(_:))))
        editor.undo(nil); XCTAssertEqual(editor.string,""); XCTAssertTrue(shape.page === page)
        editor.redo(nil); XCTAssertEqual(editor.string,"Draft")
        s.finishTextEditing(cancel:true)
        XCTAssertTrue(s.undo === markupUndo)
        markupUndo.undo(); XCTAssertNil(shape.page)
    }

    func testCancellingTextDraftRestoresDirtyIndicatorWithoutDiscardingOtherEdits() throws {
        _ = NSApplication.shared
        let source = try fixture(rotation:0); defer { try? FileManager.default.removeItem(at:source) }
        let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
        let c = MainViewController()
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:700),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentViewController = c; c.pdfView.setMarkupDocument(doc)
        let s = c.pdfView.rectangleMarkup; s.canEdit = { true }
        for wasDirty in [false,true] {
            window.isDocumentEdited = wasDirty
            s.beginTextEditing(on:page,bounds:CGRect(x:140,y:140,width:180,height:80))
            let editor = try XCTUnwrap(c.pdfView.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
            editor.string = "Cancelled draft"; editor.textDidChange(Notification(name:NSText.didChangeNotification))
            XCTAssertTrue(window.isDocumentEdited)
            s.finishTextEditing(cancel:true)
            XCTAssertEqual(window.isDocumentEdited,wasDirty)
            XCTAssertTrue(RectangleMarkupRecord.capture(doc).isEmpty)
        }
        window.isDocumentEdited = false
        let shape = try XCTUnwrap(s.create(on:page,bounds:CGRect(x:100,y:100,width:80,height:60)))
        s.markSaved(at:source); window.isDocumentEdited = false
        s.beginTextEditing(on:page,bounds:CGRect(x:140,y:140,width:180,height:80))
        s.styleSelected(color:.blue,width:4)
        s.finishTextEditing(cancel:true)
        XCTAssertTrue(s.hasUnsavedChanges); XCTAssertTrue(window.isDocumentEdited)
        XCTAssertEqual(shape.color,.blue)
    }

    func testDocumentReplacementIsBlockedThroughoutSavingAndProcessing() {
        _ = NSApplication.shared
        let controller = MainViewController(); _ = controller.view
        XCTAssertTrue(controller.confirmDiscardUnsavedChangesIfNeeded())
        controller.isSavingDocumentOperation = true
        XCTAssertFalse(controller.confirmDiscardUnsavedChangesIfNeeded())
        controller.isSavingDocumentOperation = false
        controller.beginBusyIndicator("Checking", lockInteraction: false)
        XCTAssertFalse(controller.confirmDiscardUnsavedChangesIfNeeded())
        controller.endBusyIndicator()
        XCTAssertTrue(controller.confirmDiscardUnsavedChangesIfNeeded())
    }

    func testAllMarkupToolsSurviveFlattenReduceUnflattenAndRepeatedSave() throws {
        for rotation in [0, 90, 180, 270] {
            let source = try fixture(rotation: rotation, tinyNumber: true)
            let output = source.appendingPathExtension("workflow.pdf")
            defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
            let originalBytes = try Data(contentsOf: source)
            let doc = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(doc.page(at: 0))
            let session = RectangleMarkupController(); session.bind(to: doc)
            for kind in [RectangleMarkupRecord.Kind.rectangle, .ellipse, .text] {
                _ = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 120,y: 150,width: 100,height: 70), kind: kind, text: "Architect review\nLevel 2"))
            }
            let a = CGPoint(x: 280,y: 180), b = CGPoint(x: 390,y: 290)
            for kind in [RectangleMarkupRecord.Kind.line, .arrow] {
                _ = try XCTUnwrap(session.create(on: page, bounds: RectangleMarkupController.lineBounds(a,b,width:2), kind: kind, endpoints: (a,b)))
            }
            let points = [CGPoint(x: 300,y: 100), CGPoint(x: 400,y: 140), CGPoint(x: 350,y: 220)]
            _ = try XCTUnwrap(session.createPolyline(on: page, points: points))
            session.fillColor = .orange
            _ = try XCTUnwrap(session.createPolyline(on: page, points: points, closed: true))
            let records = RectangleMarkupRecord.capture(doc)
            XCTAssertEqual(records.count, 7)
            XCTAssertTrue(PDFRectangleWriter.write(document: doc, source: source, destination: output, pageLabels: [:], records: records))
            let flat = try PDFAnnotationFlattener.flatten(source: output, destination: output)
            XCTAssertEqual(flat.flattened, 7)
            let flattened = try XCTUnwrap(PDFDocument(url: output))
            XCTAssertTrue(RectangleMarkupRecord.capture(flattened).isEmpty)
            XCTAssertEqual(flattened.page(at: 0)?.annotations.filter { $0.type == "Link" }.count, 1)
            _ = try PDFLosslessReducer.reduce(source: output)
            XCTAssertTrue(PDFAnnotationFlattener.canUnflatten(try XCTUnwrap(PDFDocument(url: output))))
            let recovery = try PDFAnnotationFlattener.unflatten(source: output)
            XCTAssertEqual(recovery.restoredAnnotations, 7)
            let restored = try XCTUnwrap(PDFDocument(url: output))
            XCTAssertEqual(RectangleMarkupRecord.capture(restored), records)
            for _ in 0..<3 {
                XCTAssertTrue(PDFRectangleWriter.write(document: restored, source: output, destination: output, pageLabels: [:], records: records))
            }
            let final = try XCTUnwrap(PDFDocument(url: output)), finalPage = try XCTUnwrap(final.page(at: 0))
            XCTAssertEqual(RectangleMarkupRecord.capture(final), records)
            XCTAssertEqual(finalPage.rotation, rotation)
            XCTAssertEqual(finalPage.bounds(for: .mediaBox), page.bounds(for: .mediaBox))
            XCTAssertEqual(finalPage.bounds(for: .cropBox), page.bounds(for: .cropBox))
            XCTAssertEqual(final.string, doc.string)
            XCTAssertEqual(finalPage.annotations.filter { $0.type == "Link" }.count, 1)
            XCTAssertEqual(finalPage.annotations.filter { $0.contents == "Imported CAD box" }.count, 1)
            if let root = ProcessInfo.processInfo.environment["DRAWBRIDGE_WORKFLOW_QA"] {
                let folder = URL(fileURLWithPath: root)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(contentsOf: output).write(to: folder.appendingPathComponent("all-tools-\(rotation).pdf"))
                try originalBytes.write(to: folder.appendingPathComponent("original-\(rotation).pdf"))
            }
            finalPage.annotations.filter(RectangleMarkupRecord.owns).forEach(finalPage.removeAnnotation)
            page.annotations.filter(RectangleMarkupRecord.owns).forEach(page.removeAnnotation)
            XCTAssertEqual(try renderedPixels(finalPage, size: NSSize(width: 800, height: 800)),
                           try renderedPixels(page, size: NSSize(width: 800, height: 800)))
            XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        }
    }

    private struct RenderedPixels: Equatable {
        let width: Int
        let height: Int
        let bytes: Data
    }

    private func renderedPixels(_ page: PDFPage, size: NSSize) throws -> RenderedPixels {
        let bounds = page.bounds(for: .cropBox)
        let sideways = page.rotation % 180 != 0
        let pageWidth = sideways ? bounds.height : bounds.width
        let pageHeight = sideways ? bounds.width : bounds.height
        let scale = min(size.width / pageWidth, size.height / pageHeight)
        let width = Int(ceil(pageWidth * scale)), height = Int(ceil(pageHeight * scale))
        var bytes = Data(count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            // Render current annotation state into a fresh, explicit sRGB context.
            // Avoid PDFKit thumbnail caching and implicit image color profiles.
            page.draw(with: .cropBox, to: context)
            return true
        }
        XCTAssertTrue(drawn)
        // Exact dimensions and pixels: no tolerance for moved content.
        return RenderedPixels(width: width, height: height, bytes: bytes)
    }

    func testFreehandPenGesturePersistenceDeletionUndoAndCancellationAtAllRotations() throws {
        for rotation in [0, 90, 180, 270] {
            let source = try fixture(rotation: rotation)
            defer { try? FileManager.default.removeItem(at: source) }
            let doc = try XCTUnwrap(PDFDocument(url: source))
            let page = try XCTUnwrap(doc.page(at: 0))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            let view = MarkupPDFView(frame: window.contentView!.bounds)
            window.contentView?.addSubview(view); view.setMarkupDocument(doc)
            window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
            let session = view.rectangleMarkup
            session.undo.groupsByEvent = false
            session.strokeColor = .blue; session.lineWidth = 4; session.tool = .pen
            let points = [CGPoint(x: 150, y: 150), CGPoint(x: 200, y: 230), CGPoint(x: 270, y: 170)]
            session.undo.beginUndoGrouping()
            XCTAssertTrue(session.pointerDown(at: view.convert(points[0], from: page)))
            XCTAssertTrue(session.pointerDragged(at: view.convert(points[1], from: page)))
            XCTAssertTrue(session.pointerUp(at: view.convert(points[2], from: page)))
            session.undo.endUndoGrouping()
            let ink = try XCTUnwrap(page.annotations.first(where: { RectangleMarkupRecord.owns($0) }))
            XCTAssertEqual(ink.type, "Ink"); XCTAssertEqual(ink.border?.lineWidth, 4)
            XCTAssertEqual(RectangleMarkupRecord.vertices(ink).count, 3)
            XCTAssertEqual(session.tool, .pen)
            let records = RectangleMarkupRecord.capture(doc)
            let output = source.deletingLastPathComponent().appendingPathComponent("Pen-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: output) }
            XCTAssertTrue(PDFRectangleWriter.write(document: doc, source: source, destination: output, pageLabels: [:], records: records))
            let reopened = try XCTUnwrap(PDFDocument(url: output))
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened), records)
            XCTAssertEqual(reopened.page(at: 0)?.rotation, rotation)
            session.tool = .select
            XCTAssertTrue(session.pointerDown(at: view.convert(points[1], from: page)))
            _ = session.pointerUp(at: view.convert(points[1], from: page))
            view.documentView?.needsDisplay = false
            session.undo.beginUndoGrouping(); session.deleteSelected(); session.undo.endUndoGrouping()
            XCTAssertTrue(RectangleMarkupRecord.capture(doc).isEmpty)
            session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.capture(doc), records)
            session.undo.redo(); XCTAssertTrue(RectangleMarkupRecord.capture(doc).isEmpty)
            session.tool = .pen
            _ = session.pointerDown(at: view.convert(points[0], from: page))
            _ = session.pointerDragged(at: view.convert(points[1], from: page))
            session.escape()
            _ = session.pointerUp(at: view.convert(points[2], from: page))
            XCTAssertTrue(RectangleMarkupRecord.capture(doc).isEmpty)
            XCTAssertEqual(page.annotations.count, 2) // imported CAD box and link
        }
    }

    func testFreehandPenDenseFractionalStrokeSaves() throws {
        let source = try fixture(rotation: 0); defer { try? FileManager.default.removeItem(at: source) }
        let doc = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(doc.page(at: 0))
        let session = RectangleMarkupController(); session.bind(to: doc)
        let points = (0..<250).map { CGPoint(x: 100.123456789 + Double($0) * 0.53123456789, y: 200 + sin(Double($0) / 10) * 30.123456789) }
        _ = try XCTUnwrap(session.createPolyline(on: page, points: points))
        let out = source.deletingLastPathComponent().appendingPathComponent("DensePen-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertTrue(PDFRectangleWriter.write(document: doc, source: source, destination: out, pageLabels: [:], records: RectangleMarkupRecord.capture(doc)))
    }

    func testPenSaveOnMinimalPDFWithoutExistingAnnotations() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("MinimalPen-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(base64Encoded: "JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCA2MTIgNzkyXSAvUmVzb3VyY2VzIDw8IC9Gb250IDw8IC9GMSA1IDAgUiA+PiA+PiAvQ29udGVudHMgNCAwIFIgPj4KZW5kb2JqCjQgMCBvYmoKPDwgL0xlbmd0aCA5NiA+PgpzdHJlYW0KQlQgL0YxIDI0IFRmIDYwIDcyMCBUZCAoRHJhd2JyaWRnZSB2NS4yIFVzYWJpbGl0eSBUZXN0KSBUaiBFVAowLjggMC44IDAuOCBSRyA1MCA4MCA1MDAgNjAwIHJlIFMKZW5kc3RyZWFtCmVuZG9iago1IDAgb2JqCjw8IC9UeXBlIC9Gb250IC9TdWJ0eXBlIC9UeXBlMSAvQmFzZUZvbnQgL0hlbHZldGljYSA+PgplbmRvYmoKeHJlZgowIDYKMDAwMDAwMDAwMCA2NTUzNSBmIAowMDAwMDAwMDA5IDAwMDAwIG4gCjAwMDAwMDAwNTggMDAwMDAgbiAKMDAwMDAwMDExNSAwMDAwMCBuIAowMDAwMDAwMjQxIDAwMDAwIG4gCjAwMDAwMDAzODYgMDAwMDAgbiAKdHJhaWxlcgo8PCAvU2l6ZSA2IC9Sb290IDEgMCBSID4+CnN0YXJ0eHJlZgo0NTYKJSVFT0YK")!.write(to: source)
        let doc = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(doc.page(at: 0))
        let session = RectangleMarkupController(); session.bind(to: doc)
        _ = try XCTUnwrap(session.createPolyline(on: page, points: [CGPoint(x: 150, y: 150), CGPoint(x: 200, y: 220)]))
        XCTAssertTrue(PDFRectangleWriter.write(document: doc, source: source, destination: source, pageLabels: [:], records: RectangleMarkupRecord.capture(doc)))
    }

    func testProductionPenWorkflowRepeatedBackgroundSaves() async throws {
        let source = try fixture(rotation: 0); defer { try? FileManager.default.removeItem(at: source) }
        let doc = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(doc.page(at: 0))
        let controller = MainViewController(); _ = controller.view
        controller.openDocumentURL = source; controller.pdfView.setMarkupDocument(doc)
        let session = controller.pdfView.rectangleMarkup
        session.rememberSource(source)
        for iteration in 0..<5 {
            let points = (0..<60).map { CGPoint(x: 120 + Double($0) * 2.345678901, y: 130 + Double(iteration) * 20 + sin(Double($0)/10) * 10) }
            _ = try XCTUnwrap(session.createPolyline(on: page, points: points))
            let saved = await withCheckedContinuation { continuation in
                controller.persistDocument(to: source, adoptAsPrimaryDocument: false, busyMessage: "Saving PDF…", showBusyOverlay: false) { continuation.resume(returning: $0) }
            }
            XCTAssertTrue(saved)
            let reopened = try XCTUnwrap(PDFDocument(url: source))
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened), RectangleMarkupRecord.capture(doc))
        }
    }

    private func fixture(rotation: Int, signed: Bool = false, tinyNumber: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RectangleBase-\(UUID().uuidString).pdf")
        let drawing = "q 0.2 0.4 0.7 rg 110 90 200 100 re f Q\nBT /F1 18 Tf 80 260 Td (ORIGINAL CONTENT) Tj ET\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /P (A1.00) >>] >> \(tinyNumber ? "/DrawbridgePrecisionProbe -0.0000000000000099" : "") >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [10 20 610 420] /CropBox [40 50 560 380] /Rotate \(rotation) /Resources << /Font << /F1 6 0 R >> >> /Contents 4 0 R /Annots [5 0 R << /Type /Annot /Subtype /Square /Rect [410 100 450 140] /C [0 0 0] /F 4 /Contents (Imported CAD box) >>] >>",
            "<< /Length \(drawing.utf8.count) >>\nstream\n\(drawing)endstream",
            signed ? "<< /FT /Sig /Type /Annot /Subtype /Widget /Rect [50 60 70 80] >>" : "<< /Type /Annot /Subtype /Link /Rect [50 60 70 80] /Border [0 0 0] /A << /S /GoTo /D [3 0 R /Fit] >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]
        var data = Data("%PDF-1.7\n".utf8); var offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = data.count; data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try data.write(to: url); return url
    }

    func testIncrementalSaveOfCompressedObjectPDFReopensInAppleReader() throws {
        guard let executable = PDFTKBookmarkWriter.executableURL() else { throw XCTSkip("qpdf required") }
        let fixture = try fixture(rotation: 90)
        let source = fixture.deletingLastPathComponent().appendingPathComponent("Compressed-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: fixture); try? FileManager.default.removeItem(at: source) }
        XCTAssertTrue(PDFTKBookmarkWriter.run(executable, arguments: ["--object-streams=generate", fixture.path, source.path]))
        let original = try Data(contentsOf: source)
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        let session = RectangleMarkupController(); session.bind(to: document)
        _ = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 120,y: 150,width: 100,height: 70), kind: .text, text: "Café — 检查尺寸"))
        let records = RectangleMarkupRecord.capture(document)
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: source, pageLabels: [:], records: records))
        let firstSave = try Data(contentsOf: source)
        XCTAssertEqual(firstSave.prefix(original.count), original)
        let reopened = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(RectangleMarkupRecord.capture(reopened), records)
        XCTAssertEqual(reopened.page(at: 0)?.rotation, 90)
        XCTAssertEqual(reopened.string, document.string)
        XCTAssertTrue(PDFRectangleWriter.write(document: reopened, source: source, destination: source, pageLabels: [:], records: records))
        XCTAssertEqual(try Data(contentsOf: source), firstSave, "Saving unchanged markups must not grow the PDF")
    }

    func testAnnotationOnlySavePreservesGeometryTextLinksAndImportedDirectAnnotations() throws {
        guard PDFTKBookmarkWriter.executableURL() != nil else { throw XCTSkip("qpdf required") }
        for rotation in [0,90,180,270] {
            let source = try fixture(rotation: rotation)
            defer { try? FileManager.default.removeItem(at: source) }
            let original = try Data(contentsOf: source)
            let doc = try XCTUnwrap(PDFDocument(url: source)); let page = try XCTUnwrap(doc.page(at:0))
            let session = RectangleMarkupController(); session.bind(to:doc)
            let rect = try XCTUnwrap(session.create(on:page,bounds:CGRect(x:350,y:210,width:130,height:90)))
            let records = RectangleMarkupRecord.capture(doc)
            XCTAssertEqual(records.count,1)
            let output = source.deletingLastPathComponent().appendingPathComponent("RectangleSaved-\(rotation)-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at:output) }
            XCTAssertTrue(MainViewController.writePDFDocument(doc,to:output,pageLabels:[0:"A1.00"],navigationSourceURL:source,rectangleRecords:records))
            XCTAssertEqual(try Data(contentsOf:source),original)
            XCTAssertEqual(try Data(contentsOf: output).prefix(original.count), original)
            let reopened = try XCTUnwrap(PDFDocument(url:output)); let writtenPage = try XCTUnwrap(reopened.page(at:0))
            XCTAssertEqual(writtenPage.rotation,rotation)
            XCTAssertEqual(writtenPage.bounds(for:.mediaBox),page.bounds(for:.mediaBox))
            XCTAssertEqual(writtenPage.bounds(for:.cropBox),page.bounds(for:.cropBox))
            XCTAssertEqual(reopened.string,doc.string)
            XCTAssertEqual(writtenPage.annotations.filter { $0.type == "Link" }.count,1)
            XCTAssertEqual(writtenPage.annotations.filter { $0.contents == "Imported CAD box" }.count,1)
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened),records)
            let firstSize = try Data(contentsOf:output).count
            // Repeated saves replace our annotations, never accumulate another rectangle.
            for _ in 0..<3 { XCTAssertTrue(MainViewController.writePDFDocument(reopened,to:output,pageLabels:[0:"A1.00"],navigationSourceURL:output,rectangleRecords:records)) }
            XCTAssertLessThanOrEqual(try Data(contentsOf:output).count,firstSize + 2000)
            let again = try XCTUnwrap(PDFDocument(url:output)); XCTAssertEqual(RectangleMarkupRecord.capture(again).count,1)
            // Deleting the last owned rectangle must still use annotation-only persistence.
            XCTAssertTrue(MainViewController.writePDFDocument(again,to:output,pageLabels:[0:"A1.00"],navigationSourceURL:output,rectangleRecords:[]))
            let deleted = try XCTUnwrap(PDFDocument(url:output))
            XCTAssertTrue(RectangleMarkupRecord.capture(deleted).isEmpty)
            XCTAssertEqual(deleted.page(at:0)?.annotations.count,2)
            XCTAssertEqual(rect.bounds,CGRect(x:350,y:210,width:130,height:90))
            if let directory = ProcessInfo.processInfo.environment["DRAWBRIDGE_RECTANGLE_QA"] {
                let folder = URL(fileURLWithPath:directory); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try original.write(to:folder.appendingPathComponent("before-\(rotation).pdf"))
                XCTAssertTrue(MainViewController.writePDFDocument(doc,to:folder.appendingPathComponent("after-\(rotation).pdf"),pageLabels:[0:"A1.00"],navigationSourceURL:source,rectangleRecords:records))
            }
        }
    }

    func testAllShapesSaveAtEveryRotationWithEndpointUndo() throws {
        guard PDFTKBookmarkWriter.executableURL() != nil else { throw XCTSkip("qpdf required") }
        for rotation in [0,90,180,270] {
            let source = try fixture(rotation:rotation)
            defer { try? FileManager.default.removeItem(at:source) }
            let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
            let session = RectangleMarkupController(); session.bind(to:doc); session.undo.groupsByEvent = false
            func transaction(_ body: () -> Void) { session.undo.beginUndoGrouping(); body(); session.undo.endUndoGrouping() }
            var arrow: PDFAnnotation?
            transaction {
                _ = session.create(on:page,bounds:CGRect(x:330,y:220,width:140,height:80),kind:.ellipse)
                let a = CGPoint(x:90,y:200), b = CGPoint(x:250,y:200)
                _ = session.create(on:page,bounds:RectangleMarkupController.lineBounds(a,b,width:2),kind:.line,endpoints:(a,b))
                let c = CGPoint(x:280,y:320), d = CGPoint(x:200,y:100)
                arrow = session.create(on:page,bounds:RectangleMarkupController.lineBounds(c,d,width:2),kind:.arrow,endpoints:(c,d))
            }
            let annotation = try XCTUnwrap(arrow), initial = RectangleMarkupRecord.capture(doc)
            let a = CGPoint(x:320,y:320), b = CGPoint(x:220,y:100)
            transaction { session.setGeometry(RectangleMarkupController.lineBounds(a,b,width:2),endpoints:(a,b),of:annotation,on:page,action:"Move Arrow") }
            session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.capture(doc),initial)
            session.undo.redo(); XCTAssertEqual(RectangleMarkupRecord.capture(doc).last?.start,a)
            transaction { session.styleSelected(color:.blue,width:4) }
            session.undo.undo(); XCTAssertEqual(annotation.border?.lineWidth,2)
            let records = RectangleMarkupRecord.capture(doc)
            XCTAssertTrue(records.allSatisfy(\.isValid))
            let output = source.deletingLastPathComponent().appendingPathComponent("Shapes-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at:output) }
            XCTAssertTrue(PDFRectangleWriter.write(document:doc,source:source,destination:output,pageLabels:[:],records:records))
            let reopened = try XCTUnwrap(PDFDocument(url:output)), written = try XCTUnwrap(reopened.page(at:0))
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened),records)
            XCTAssertEqual(written.rotation,rotation); XCTAssertEqual(written.bounds(for:.cropBox),page.bounds(for:.cropBox))
            XCTAssertEqual(reopened.string,doc.string); XCTAssertEqual(written.annotations.filter { !RectangleMarkupRecord.owns($0) }.count,2)
            if let directory = ProcessInfo.processInfo.environment["DRAWBRIDGE_SHAPE_QA"] {
                let folder = URL(fileURLWithPath:directory); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try Data(contentsOf:source).write(to:folder.appendingPathComponent("before-\(rotation).pdf"))
                try Data(contentsOf:output).write(to:folder.appendingPathComponent("after-\(rotation).pdf"))
            }
            XCTAssertTrue(PDFRectangleWriter.write(document:reopened,source:output,destination:output,pageLabels:[:],records:[]))
            XCTAssertEqual(PDFDocument(url:output)?.page(at:0)?.annotations.count,2)
        }
    }

    func testPDFKitBackgroundDocumentGetterDoesNotEnterMainActor() async throws {
        let source = try fixture(rotation:0); defer { try? FileManager.default.removeItem(at:source) }
        let document = try XCTUnwrap(PDFDocument(url:source))
        let view = MarkupPDFView(frame:.zero)
        view.setMarkupDocument(document)
        let reader = BackgroundPDFDocumentRead(view:view,document:document)
        let completed = expectation(description:"PDFKit background document getter")
        DispatchQueue(label:"PDFKit.PDFDocument.formFillingQueue.regression").async {
            for _ in 0..<100 {
                let value = reader.object.value(forKey:"document") as AnyObject?
                XCTAssertTrue(value === reader.expected)
            }
            completed.fulfill()
        }
        await fulfillment(of:[completed],timeout:5)
        XCTAssertNotNil(view.rectangleMarkup.create(on:document.page(at:0)!,bounds:CGRect(x:100,y:100,width:80,height:60)))
        view.setMarkupDocument(nil)
        XCTAssertNil(view.rectangleMarkup.selected)
    }

    func testBluebeamToolShortcutsRespectModifiersAndBusyState() throws {
        _ = NSApplication.shared
        func key(_ text: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:0)!
        }
        let session = RectangleMarkupController()
        for (text,flags,tool) in [("e",NSEvent.ModifierFlags(),RectangleMarkupController.Tool.ellipse),("r",[],.rectangle),("l",[],.line),("v",[],.select),("a",[],.arrow),("t",[],.text),("N",[.shift],.polyline),("P",[.shift],.polygon)] {
            XCTAssertTrue(session.handleToolShortcut(key(text,flags))); XCTAssertEqual(session.tool,tool)
        }
        for event in [key("n"),key("l",[.command]),key("r",[.option]),key("e",[.shift]),key("n",[.shift,.control]),key("a",[.command]),key("t",[.shift]),key("v",[.command])] { XCTAssertFalse(session.handleToolShortcut(event)) }
        XCTAssertTrue(session.handleToolShortcut(key("A",[.capsLock])))
        XCTAssertEqual(session.tool,.arrow)
        session.tool = .polygon
        session.canEdit = { false }; XCTAssertFalse(session.handleToolShortcut(key("e"))); XCTAssertEqual(session.tool,.polygon)
    }

    func testPolylineSaveMoveResizeUndoAndImportedContentAtEveryRotation() throws {
        guard PDFTKBookmarkWriter.executableURL() != nil else { throw XCTSkip("qpdf required") }
        for rotation in [0,90,180,270] {
            let source = try fixture(rotation:rotation); defer { try? FileManager.default.removeItem(at:source) }
            let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
            let session = RectangleMarkupController(); session.bind(to:doc); session.undo.groupsByEvent = false
            func transaction(_ body: () -> Void) { session.undo.beginUndoGrouping(); body(); session.undo.endUndoGrouping() }
            var annotation: PDFAnnotation?
            let points = [CGPoint(x:100,y:100),CGPoint(x:150,y:210),CGPoint(x:280,y:180),CGPoint(x:380,y:280)]
            transaction { annotation = session.createPolyline(on:page,points:points) }
            let polyline = try XCTUnwrap(annotation), initial = RectangleMarkupRecord.capture(doc)
            XCTAssertEqual(initial.first?.vertices,points); XCTAssertEqual(initial.first?.kind,.polyline)
            transaction { session.setBounds(polyline.bounds.offsetBy(dx:10,dy:20),of:polyline,on:page,action:"Move Polyline") }
            XCTAssertEqual(RectangleMarkupRecord.vertices(polyline),points.map { CGPoint(x:$0.x+10,y:$0.y+20) })
            session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.capture(doc),initial)
            transaction { session.setBounds(polyline.bounds.insetBy(dx:-8,dy:-8),of:polyline,on:page,action:"Resize Polyline") }
            session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.capture(doc),initial)
            transaction { session.styleSelected(color:.blue,width:4) }
            let records = RectangleMarkupRecord.capture(doc)
            let output = source.deletingLastPathComponent().appendingPathComponent("Polyline-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at:output) }
            XCTAssertTrue(PDFRectangleWriter.write(document:doc,source:source,destination:output,pageLabels:[:],records:records))
            let reopened = try XCTUnwrap(PDFDocument(url:output))
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened),records)
            XCTAssertEqual(reopened.page(at:0)?.rotation,rotation); XCTAssertEqual(reopened.string,doc.string)
            XCTAssertEqual(reopened.page(at:0)?.annotations.filter { !RectangleMarkupRecord.owns($0) }.count,2)
            if let root = ProcessInfo.processInfo.environment["DRAWBRIDGE_POLYLINE_QA"] {
                let folder = URL(fileURLWithPath:root); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try Data(contentsOf:source).write(to:folder.appendingPathComponent("before-\(rotation).pdf"))
                try Data(contentsOf:output).write(to:folder.appendingPathComponent("after-\(rotation).pdf"))
            }
            transaction { session.deleteSelected() }; session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.capture(doc),records)
            XCTAssertNil(session.createPolyline(on:page,points:[CGPoint(x:10,y:20)]))
        }
    }

    func testInlineTextCreationEditingCancellationAndDocumentSwitch() throws {
        let source = try fixture(rotation:0); defer { try? FileManager.default.removeItem(at:source) }
        let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
        let view = PDFView(frame:CGRect(x:0,y:0,width:800,height:600)); view.document = doc
        let session = RectangleMarkupController(); session.install(on:view); session.bind(to:doc)
        session.beginTextEditing(on:page,bounds:CGRect(x:140,y:140,width:180,height:80))
        let editor = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
        editor.string = "erlN\nInline text"; session.finishTextEditing()
        XCTAssertEqual(RectangleMarkupRecord.capture(doc).first?.text,"erlN\nInline text")
        let annotation = try XCTUnwrap(page.annotations.first(where:RectangleMarkupRecord.owns))
        session.beginTextEditing(on:page,bounds:annotation.bounds,annotation:annotation)
        XCTAssertFalse(annotation.shouldDisplay)
        let edit = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
        edit.string = "Cancelled"; session.finishTextEditing(cancel:true)
        XCTAssertTrue(annotation.shouldDisplay); XCTAssertEqual(annotation.contents,"erlN\nInline text")
        session.beginTextEditing(on:page,bounds:annotation.bounds,annotation:annotation)
        let last = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
        last.string = "Committed before switching"
        session.bind(to:nil)
        XCTAssertEqual(annotation.contents,"Committed before switching"); XCTAssertTrue(annotation.shouldDisplay)
        XCTAssertFalse(session.isEditingText)
        XCTAssertEqual(doc.string,"ORIGINAL CONTENT")
    }

    func testTypingMarksDraftDirtyWithoutReindexingPDFUntilCommit() throws {
        let source = try fixture(rotation: 0)
        defer { try? FileManager.default.removeItem(at: source) }
        let doc = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(doc.page(at: 0))
        let view = PDFView(frame: CGRect(x: 0,y: 0,width: 800,height: 600)); view.document = doc
        let session = RectangleMarkupController(); session.install(on: view); session.bind(to: doc)
        var drafts = 0, mutations = 0
        session.onDraftChanged = { drafts += 1 }
        session.onMutation = { _ in mutations += 1 }
        session.beginTextEditing(on: page, bounds: CGRect(x: 140,y: 140,width: 180,height: 80))
        let editor = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
        for n in 1...50 {
            editor.string = "Architect note \(n)"
            editor.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        }
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertEqual(drafts, 50)
        XCTAssertEqual(mutations, 0)
        XCTAssertTrue(RectangleMarkupRecord.capture(doc).isEmpty)
        session.finishTextEditing()
        XCTAssertEqual(mutations, 1)
        XCTAssertEqual(RectangleMarkupRecord.capture(doc).first?.text, "Architect note 50")
    }

    func testPathSelectionAndNodeEditingAtEveryRotation() throws {
        for rotation in [0,90,180,270] {
            let source = try fixture(rotation:rotation); defer { try? FileManager.default.removeItem(at:source) }
            let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
            let session = RectangleMarkupController(); session.bind(to:doc)
            session.undo.groupsByEvent = false
            let points = [CGPoint(x:140,y:140),CGPoint(x:220,y:260),CGPoint(x:300,y:140)]
            session.undo.beginUndoGrouping()
            let polygon = try XCTUnwrap(session.createPolyline(on:page,points:points,closed:true))
            session.undo.endUndoGrouping()
            XCTAssertFalse(RectangleMarkupController.hitTest(polygon,at:CGPoint(x:145,y:250),tolerance:2),"Empty bounding-box space must not select")
            XCTAssertTrue(RectangleMarkupController.hitTest(polygon,at:CGPoint(x:220,y:180),tolerance:2))
            session.undo.beginUndoGrouping(); session.fillSelected(nil); session.undo.endUndoGrouping()
            XCTAssertFalse(RectangleMarkupController.hitTest(polygon,at:CGPoint(x:220,y:180),tolerance:2),"Unfilled interior must not select")
            XCTAssertTrue(RectangleMarkupController.hitTest(polygon,at:CGPoint(x:180,y:200),tolerance:2))
            session.undo.removeAllActions()
            let oldBounds = polygon.bounds
            let target = CGPoint(x:240,y:270)
            session.undo.beginUndoGrouping()
            var edited = points; edited[1] = target
            session.setVertexPositions(edited,of:polygon,on:page)
            session.undo.endUndoGrouping()
            for (actual,expected) in zip(RectangleMarkupRecord.vertices(polygon),edited) {
                XCTAssertEqual(actual.x,expected.x,accuracy:0.001); XCTAssertEqual(actual.y,expected.y,accuracy:0.001)
            }
            session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.vertices(polygon),points); XCTAssertEqual(polygon.bounds,oldBounds)
            session.undo.redo()
            session.undo.beginUndoGrouping()
            let line = try XCTUnwrap(session.createPolyline(on:page,points:points))
            session.undo.endUndoGrouping()
            XCTAssertFalse(RectangleMarkupController.hitTest(line,at:CGPoint(x:220,y:140),tolerance:2),"Open path has no closing edge")
            let records = RectangleMarkupRecord.capture(doc)
            let output = source.deletingLastPathComponent().appendingPathComponent("Nodes-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at:output) }
            XCTAssertTrue(PDFRectangleWriter.write(document:doc,source:source,destination:output,pageLabels:[:],records:records))
            let reopened = try XCTUnwrap(PDFDocument(url:output))
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened),records)
            XCTAssertEqual(reopened.page(at:0)?.rotation,rotation)
            XCTAssertEqual(reopened.page(at:0)?.bounds(for:.cropBox),page.bounds(for:.cropBox))
            if let root = ProcessInfo.processInfo.environment["DRAWBRIDGE_NODE_QA"] {
                let folder = URL(fileURLWithPath:root); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try Data(contentsOf:source).write(to:folder.appendingPathComponent("before-\(rotation).pdf"))
                try Data(contentsOf:output).write(to:folder.appendingPathComponent("after-\(rotation).pdf"))
            }
        }
    }

    func testPolygonDrawUsesCropOriginWithoutMovingBasePage() throws {
        let source = try fixture(rotation:0); defer { try? FileManager.default.removeItem(at:source) }
        let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
        let session = RectangleMarkupController(); session.bind(to:doc); session.fillColor = .blue
        let points = [CGPoint(x:140,y:150),CGPoint(x:200,y:150),CGPoint(x:200,y:210),CGPoint(x:140,y:210)]
        let annotation = try XCTUnwrap(session.createPolyline(on:page,points:points,closed:true))
        let context = try XCTUnwrap(CGContext(data:nil,width:520,height:330,bitsPerComponent:8,bytesPerRow:520*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        annotation.draw(with:.cropBox,in:context)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
        XCTAssertEqual(bytes[((330-1-130)*520+130)*4+2],255,"Fill belongs at page coordinates minus crop origin")
        XCTAssertEqual(bytes[((330-1-190)*520+190)*4+3],0,"Unadjusted coordinates must not receive the polygon")
        XCTAssertEqual(page.bounds(for:.cropBox),CGRect(x:40,y:50,width:520,height:330))
    }

    func testPolygonFillUndoGeometryAndSaveAtEveryRotation() throws {
        guard PDFTKBookmarkWriter.executableURL() != nil else { throw XCTSkip("qpdf required") }
        for rotation in [0,90,180,270] {
            let source = try fixture(rotation:rotation); defer { try? FileManager.default.removeItem(at:source) }
            let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
            let session = RectangleMarkupController(); session.bind(to:doc); session.undo.groupsByEvent = false; session.fillColor = .orange
            func transaction(_ body: () -> Void) { session.undo.beginUndoGrouping(); body(); session.undo.endUndoGrouping() }
            var polygon: PDFAnnotation?
            let points = [CGPoint(x:120,y:100),CGPoint(x:140,y:220),CGPoint(x:300,y:240),CGPoint(x:280,y:120)]
            transaction { polygon = session.createPolyline(on:page,points:points,closed:true) }
            let annotation = try XCTUnwrap(polygon), initial = RectangleMarkupRecord.capture(doc)
            XCTAssertEqual(initial.first?.kind,.polygon); XCTAssertNotNil(initial.first?.fill)
            transaction { session.fillSelected(nil) }; XCTAssertNil(RectangleMarkupRecord.capture(doc).first?.fill)
            session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.capture(doc),initial)
            transaction { session.fillSelected(.blue) }
            transaction { session.setBounds(annotation.bounds.offsetBy(dx:10,dy:20),of:annotation,on:page,action:"Move Polygon") }
            session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.vertices(annotation),points)
            let records = RectangleMarkupRecord.capture(doc)
            XCTAssertEqual(records.first?.fill,[0,0,1])
            let output = source.deletingLastPathComponent().appendingPathComponent("Polygon-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at:output) }
            XCTAssertTrue(PDFRectangleWriter.write(document:doc,source:source,destination:output,pageLabels:[:],records:records))
            let reopened = try XCTUnwrap(PDFDocument(url:output))
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened),records)
            session.bind(to:reopened)
            let loaded = try XCTUnwrap(reopened.page(at:0)?.annotations.first(where:RectangleMarkupRecord.owns))
            XCTAssertTrue(loaded is DrawbridgePolygonAnnotation)
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened),records)
            XCTAssertEqual(reopened.page(at:0)?.rotation,rotation); XCTAssertEqual(reopened.string,doc.string)
            if let root = ProcessInfo.processInfo.environment["DRAWBRIDGE_POLYGON_QA"] {
                let folder = URL(fileURLWithPath:root); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try Data(contentsOf:source).write(to:folder.appendingPathComponent("before-\(rotation).pdf"))
                try Data(contentsOf:output).write(to:folder.appendingPathComponent("after-\(rotation).pdf"))
            }
            XCTAssertNil(session.createPolyline(on:reopened.page(at:0)!,points:Array(points.prefix(2)),closed:true))
            XCTAssertTrue(records.first!.isValid)
            let plain = RectangleMarkupController(); plain.bind(to:doc); plain.undo.groupsByEvent = false
            plain.undo.beginUndoGrouping(); _ = plain.createPolyline(on:page,points:points); plain.undo.endUndoGrouping()
            XCTAssertNil(RectangleMarkupRecord.capture(doc).last?.fill,"Polylines must remain unfilled")
        }
    }

    func testShallowTextBoxRetainsVisibleGlyphAppearanceAfterSave() throws {
        let source = try fixture(rotation:0); defer { try? FileManager.default.removeItem(at:source) }
        let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
        let session = RectangleMarkupController(); session.bind(to:doc)
        _ = session.create(on:page,bounds:CGRect(x:120,y:60,width:194,height:20.53),kind:.text,text:"Preview verified")
        let record = try XCTUnwrap(RectangleMarkupRecord.capture(doc).first)
        XCTAssertTrue(TextMarkupAppearance.drawing(record).contains("f\n"), "A shallow box must contain painted glyphs")
        let output = source.appendingPathExtension("saved.pdf")
        defer { try? FileManager.default.removeItem(at:output) }
        XCTAssertTrue(PDFRectangleWriter.write(document:doc,source:source,destination:output,pageLabels:[:],records:[record]))
        let reopened = try XCTUnwrap(PDFDocument(url:output)), savedPage = try XCTUnwrap(reopened.page(at:0))
        let original = try renderedPixels(page, size: NSSize(width:1040, height:660))
        let saved = try renderedPixels(savedPage, size: NSSize(width:1040, height:660))
        savedPage.annotations.filter { RectangleMarkupRecord.owns($0) }.forEach { savedPage.removeAnnotation($0) }
        let withoutMarkup = try renderedPixels(savedPage, size: NSSize(width:1040, height:660))
        XCTAssertNotEqual(saved,withoutMarkup, "Saved text must render visible pixels")
        page.annotations.filter { RectangleMarkupRecord.owns($0) }.forEach { page.removeAnnotation($0) }
        XCTAssertEqual(withoutMarkup,try renderedPixels(page, size: NSSize(width:1040, height:660)))
        XCTAssertEqual(original.width, saved.width)
    }

    func testTextSaveUnicodeMultilineAndEditingAtEveryRotation() throws {
        guard PDFTKBookmarkWriter.executableURL() != nil else { throw XCTSkip("qpdf required") }
        for rotation in [0,90,180,270] {
            let source = try fixture(rotation:rotation); defer { try? FileManager.default.removeItem(at:source) }
            let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
            let session = RectangleMarkupController(); session.bind(to:doc); session.undo.groupsByEvent = false
            session.fontSize = 18
            func transaction(_ body: () -> Void) { session.undo.beginUndoGrouping(); body(); session.undo.endUndoGrouping() }
            var text: PDFAnnotation?
            transaction { text = session.create(on:page,bounds:CGRect(x:310,y:180,width:230,height:170),kind:.text,text:"REVIEW WALL\nCafé — façade\n检查尺寸") }
            let annotation = try XCTUnwrap(text), initial = RectangleMarkupRecord.capture(doc)
            transaction { session.editSelectedText("Revised note\nSecond line",size:24) }
            session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.capture(doc),initial)
            session.undo.redo(); XCTAssertEqual(annotation.contents,"Revised note\nSecond line")
            session.undo.undo()
            transaction { session.styleSelected(color:.blue,width:2) }
            let records = RectangleMarkupRecord.capture(doc)
            XCTAssertEqual(text?.color.alphaComponent,0, "Text boxes must not fill their background")
            XCTAssertEqual(records.first?.kind,.text); XCTAssertEqual(records.first?.blue,1)
            let output = source.deletingLastPathComponent().appendingPathComponent("Text-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at:output) }
            XCTAssertTrue(PDFRectangleWriter.write(document:doc,source:source,destination:output,pageLabels:[:],records:records))
            let reopened = try XCTUnwrap(PDFDocument(url:output))
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened),records)
            XCTAssertEqual(reopened.page(at:0)?.rotation,rotation); XCTAssertEqual(reopened.string,doc.string)
            if let root = ProcessInfo.processInfo.environment["DRAWBRIDGE_TEXT_QA"] {
                let folder = URL(fileURLWithPath:root); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try Data(contentsOf:source).write(to:folder.appendingPathComponent("before-\(rotation).pdf"))
                try Data(contentsOf:output).write(to:folder.appendingPathComponent("after-\(rotation).pdf"))
            }
            transaction { session.deleteSelected() }; session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.capture(doc),records)
        }
    }

    func testRectangleUndoRedoAndOwnershipIsolation() throws {
        let source = try fixture(rotation:90); defer { try? FileManager.default.removeItem(at:source) }
        let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
        let imported = page.annotations; let originalBounds = imported.map(\.bounds)
        let session = RectangleMarkupController(); session.bind(to:doc)
        session.undo.groupsByEvent = false
        func transaction(_ body: () -> Void) { session.undo.beginUndoGrouping(); body(); session.undo.endUndoGrouping() }
        var rectangle: PDFAnnotation?
        transaction { rectangle = session.create(on:page,bounds:CGRect(x:100,y:150,width:80,height:60)) }
        let annotation = try XCTUnwrap(rectangle)
        XCTAssertTrue(session.hasUnsavedChanges)
        transaction { session.setBounds(CGRect(x:150,y:180,width:110,height:70),of:annotation,on:page,action:"Move Rectangle") }
        session.undo.undo(); XCTAssertEqual(annotation.bounds,CGRect(x:100,y:150,width:80,height:60))
        session.undo.redo(); XCTAssertEqual(annotation.bounds,CGRect(x:150,y:180,width:110,height:70))
        transaction { session.styleSelected(color:.blue,width:4) }
        XCTAssertEqual(annotation.border?.lineWidth,4)
        session.undo.undo(); XCTAssertEqual(annotation.border?.lineWidth,2)
        transaction { session.deleteSelected() }; XCTAssertFalse(page.annotations.contains { $0 === annotation })
        session.undo.undo(); XCTAssertTrue(page.annotations.contains { $0 === annotation })
        XCTAssertEqual(imported.map(\.bounds),originalBounds); XCTAssertEqual(page.rotation,90)
        XCTAssertFalse(imported.contains { RectangleMarkupRecord.owns($0) })
        session.bind(to:nil); XCTAssertFalse(session.undo.canUndo); XCTAssertNil(session.selected)
    }

    func testBlockedWriterLeavesOriginalBytesUntouched() throws {
        let source = try fixture(rotation:270,signed:true); defer { try? FileManager.default.removeItem(at:source) }
        let original = try Data(contentsOf:source); let doc = try XCTUnwrap(PDFDocument(url:source))
        let record = RectangleMarkupRecord(id:RectangleMarkupRecord.prefix + "test",pageIndex:0,bounds:CGRect(x:100,y:100,width:60,height:40),red:1,green:0,blue:0,lineWidth:2)
        XCTAssertFalse(MainViewController.writePDFDocument(doc,to:source,pageLabels:[:],navigationSourceURL:source,rectangleRecords:[record]))
        XCTAssertEqual(try Data(contentsOf:source),original)
        let invalid = RectangleMarkupRecord(id:record.id,pageIndex:0,bounds:CGRect(x:0,y:0,width:0,height:5),red:1,green:0,blue:0,lineWidth:2)
        XCTAssertFalse(PDFRectangleWriter.write(document:doc,source:source,destination:source,pageLabels:[:],records:[invalid]))
        XCTAssertEqual(try Data(contentsOf:source),original)
    }

    func testDeletedLastRectangleStaysDirtyAcrossDocumentSwitch() throws {
        let source = try fixture(rotation:0); defer { try? FileManager.default.removeItem(at:source) }
        let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
        let session = RectangleMarkupController(); session.bind(to:doc)
        _ = session.create(on:page,bounds:CGRect(x:100,y:100,width:60,height:40))
        session.deleteSelected(); XCTAssertTrue(RectangleMarkupRecord.capture(doc).isEmpty)
        session.bind(to:PDFDocument()); session.bind(to:doc)
        XCTAssertTrue(session.hasUnsavedChanges)
        session.markSaved(at:source); session.bind(to:nil); session.bind(to:doc)
        XCTAssertFalse(session.hasUnsavedChanges)
    }

    func testChangedSourceIsNotOverwritten() throws {
        let source = try fixture(rotation:0); defer { try? FileManager.default.removeItem(at:source) }
        let doc = try XCTUnwrap(PDFDocument(url:source))
        let stamp = try XCTUnwrap(PDFMarkupSourceStamp.read(source))
        var updated = try Data(contentsOf:source); updated.append(Data("\n% external change\n".utf8)); try updated.write(to:source)
        XCTAssertFalse(PDFRectangleWriter.write(document:doc,source:source,destination:source,pageLabels:[:],records:[],expectedSourceStamp:stamp))
        XCTAssertEqual(try Data(contentsOf:source),updated)
    }

    func testCopiedMarkupIdentifiersAreRepairedAndEveryMarkupIsSaved() throws {
        let source = try fixture(rotation: 90)
        let output = source.deletingLastPathComponent().appendingPathComponent("DuplicateMarkup-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let doc = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(doc.page(at: 0))
        let session = RectangleMarkupController(); session.bind(to: doc)
        let first = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 100,y: 110,width: 80,height: 60)))
        let second = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 250,y: 180,width: 90,height: 70)))
        second.setValue(try XCTUnwrap(RectangleMarkupRecord.identity(first)), forAnnotationKey: RectangleMarkupRecord.identityKey)
        let original = try Data(contentsOf: source)
        let records = RectangleMarkupRecord.capture(doc)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.id)).count, 2)
        XCTAssertEqual(RectangleMarkupRecord.capture(doc), records, "Repair must be stable across captures")
        XCTAssertTrue(PDFRectangleWriter.write(document: doc, source: source, destination: output, pageLabels: [:], records: records))
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(RectangleMarkupRecord.capture(reopened), records)
        XCTAssertEqual(reopened.page(at: 0)?.rotation, 90)
        XCTAssertEqual(reopened.page(at: 0)?.bounds(for: .cropBox), page.bounds(for: .cropBox))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testFastGraphVerificationDetectsContentChangesAndHandlesRenumberedCycles() throws {
        func graph(_ root: String, _ page: String, _ stream: String, bytes: String = "original", rotation: Int = 90) -> [String: Any] {
            ["qpdf": [["maxobjectid": 30], [
                "trailer": ["value": ["/Root": root]],
                "obj:\(root)": ["value": ["/Pages": page]],
                "obj:\(page)": ["value": ["/Parent": root, "/Contents": stream, "/Rotate": rotation, "/MediaBox": [0,0,600,400]]],
                "obj:\(stream)": ["stream": ["dict": ["/Length": bytes.count], "data": bytes]]
            ]]]
        }
        let original = graph("1 0 R", "2 0 R", "3 0 R")
        XCTAssertTrue(try PDFLosslessReducer.semanticGraphsMatch(original, graph("20 0 R", "21 0 R", "22 0 R")))
        XCTAssertFalse(try PDFLosslessReducer.semanticGraphsMatch(original, graph("20 0 R", "21 0 R", "22 0 R", bytes: "changed")))
        XCTAssertFalse(try PDFLosslessReducer.semanticGraphsMatch(original, graph("20 0 R", "21 0 R", "22 0 R", rotation: 0)))
    }

    func testFastGraphVerificationHandlesDeepAnnotationChains() throws {
        var objects: [String: Any] = ["trailer": ["value": ["/Root": "1 0 R"]]]
        for index in 1...10000 {
            objects["obj:\(index) 0 R"] = ["value": ["/Next": "\(index == 10000 ? 1 : index + 1) 0 R", "/Value": index]]
        }
        let original: [String: Any] = ["qpdf": [["maxobjectid": 10000], objects]]
        XCTAssertTrue(try PDFLosslessReducer.semanticGraphsMatch(original, original))
        objects["obj:10000 0 R"] = ["value": ["/Next": "1 0 R", "/Value": -1]]
        XCTAssertFalse(try PDFLosslessReducer.semanticGraphsMatch(original, ["qpdf": [["maxobjectid": 10000], objects]]))
    }

    func testFastGraphVerificationAcceptsCanonicalJSONNumbersWithoutRoundingTolerance() throws {
        let number = try JSONSerialization.jsonObject(with: Data("0.001157407".utf8), options: .fragmentsAllowed)
        let roundTrip = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: number, options: .fragmentsAllowed), options: .fragmentsAllowed)
        func graph(_ value: Any) -> [String: Any] {
            ["qpdf": [["maxobjectid": 1], ["trailer": ["value": ["/Root": "1 0 R"]], "obj:1 0 R": ["value": ["/Matrix": [value]]]]]]
        }
        XCTAssertTrue(try PDFLosslessReducer.semanticGraphsMatch(graph(number), graph(roundTrip)))
        XCTAssertFalse(try PDFLosslessReducer.semanticGraphsMatch(graph(number), graph(0.001157408)))
        XCTAssertFalse(try PDFLosslessReducer.semanticGraphsMatch(graph(true), graph(1)))
    }

    func testCompactStreamVerificationDetectsChangedBytes() throws {
        func compact(_ bytes: Data) throws -> [String: Any] {
            let json = "{\"qpdf\":[{}, {\"trailer\":{\"value\":{\"/Root\":\"1 0 R\"}},\"obj:1 0 R\":{\"stream\":{\"dict\":{},\n          \"data\": \"" + bytes.base64EncodedString() + "\"}}}]}"
            return try XCTUnwrap(JSONSerialization.jsonObject(with: PDFRectangleWriter.compactStreamJSON(Data(json.utf8))) as? [String: Any])
        }
        let source = try compact(Data([0, 1, 2, 255]))
        XCTAssertTrue(try PDFLosslessReducer.semanticGraphsMatch(source, compact(Data([0, 1, 2, 255]))))
        XCTAssertFalse(try PDFLosslessReducer.semanticGraphsMatch(source, compact(Data([0, 1, 3, 255]))))
        XCTAssertThrowsError(try PDFRectangleWriter.compactStreamJSON(Data("{\n          \"data\": \"invalid!\"}".utf8)))
    }

    func testArchitecturalCorpusPreservation() throws {
        guard let root = ProcessInfo.processInfo.environment["DRAWBRIDGE_RECTANGLE_CORPUS"] else { throw XCTSkip("Optional architectural corpus") }
        for name in ["architectural-mech", "civil-marked"] {
            let source = URL(fileURLWithPath: root).appendingPathComponent(name + ".pdf")
            let doc = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(doc.page(at: 0))
            let crop = page.bounds(for: .cropBox)
            let record = RectangleMarkupRecord(id: RectangleMarkupRecord.prefix + name, pageIndex: 0, bounds: CGRect(x: crop.midX, y: crop.midY, width: 80, height: 60), red: 1, green: 0, blue: 0, lineWidth: 2)
            let records = RectangleMarkupRecord.capture(doc) + [record]
            let destination = URL(fileURLWithPath: root).appendingPathComponent(name + "-rectangle.pdf")
            let start = Date()
            XCTAssertTrue(PDFRectangleWriter.write(document: doc, source: source, destination: destination, pageLabels: [:], records: records))
            print("Rectangle corpus \(name): \(Date().timeIntervalSince(start))s")
            let reopened = try XCTUnwrap(PDFDocument(url: destination))
            XCTAssertEqual(reopened.pageCount, doc.pageCount)
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened), records)
            for n in 0..<doc.pageCount {
                XCTAssertEqual(reopened.page(at:n)?.rotation, doc.page(at:n)?.rotation)
                XCTAssertEqual(reopened.page(at:n)?.bounds(for:.cropBox), doc.page(at:n)?.bounds(for:.cropBox))
            }
        }
    }

    func testApplicationMarkupSaveCompletionLatency() async throws {
        _ = NSApplication.shared
        let controller = MainViewController(); _ = controller.view
        var fixtureSource = try fixture(rotation: 0)
        if let directory = ProcessInfo.processInfo.environment["DRAWBRIDGE_SAVE_DESTINATION_DIRECTORY"] {
            let destination = URL(fileURLWithPath: directory).appendingPathComponent("Drawbridge-save-test-\(UUID().uuidString).pdf")
            try FileManager.default.moveItem(at: fixtureSource, to: destination)
            fixtureSource = destination
        }
        let source = fixtureSource
        defer { try? FileManager.default.removeItem(at: source) }
        if let root = ProcessInfo.processInfo.environment["DRAWBRIDGE_RECTANGLE_CORPUS"] {
            let corpus = URL(fileURLWithPath: root).appendingPathComponent("architectural-mech.pdf")
            try Data(contentsOf: corpus).write(to: source)
        }
        let doc = try XCTUnwrap(PDFDocument(url: source))
        controller.openDocumentURL = source
        if ProcessInfo.processInfo.environment["DRAWBRIDGE_SAVE_PREPARE_ON_OPEN"] == "1" {
            let prepared = await Task.detached { PDFRectangleWriter.prepareInspection(source: source) }.value
            if !prepared { print("OPEN INSPECTION: source metadata changed; save will prepare safely on demand") }
        }
        controller.pdfView.setMarkupDocument(doc)
        let page = try XCTUnwrap(doc.page(at: 0))
        let originalCount = RectangleMarkupRecord.capture(doc).count
        let originalSize = try Data(contentsOf: source).count
        let additionsPerPass = ProcessInfo.processInfo.environment["DRAWBRIDGE_SAVE_SIX_MARKUPS"] == "1" ? 6 : 1
        for pass in 1...3 {
            for addition in 0..<additionsPerPass {
                _ = try XCTUnwrap(controller.pdfView.rectangleMarkup.create(on: page, bounds: CGRect(x: 100 + pass * 10 + addition,y: 100,width: 80,height: 60)))
            }
            let expected = RectangleMarkupRecord.capture(doc)
            for record in expected { XCTAssertTrue(record.isValid, "Invalid captured markup: \(record)") }
            let start = Date()
            let saved = await withCheckedContinuation { continuation in
                controller.persistDocument(to: source, adoptAsPrimaryDocument: false, busyMessage: "Saving PDF…") { saved in
                    continuation.resume(returning: saved)
                }
            }
            XCTAssertTrue(saved)
            XCTAssertFalse(controller.isSavingDocumentOperation)
            XCTAssertFalse(controller.pdfView.rectangleMarkup.hasUnsavedChanges)
            let limit = Double(ProcessInfo.processInfo.environment["DRAWBRIDGE_SAVE_LATENCY_LIMIT"] ?? "3") ?? 3
            let firstLimit = Double(ProcessInfo.processInfo.environment["DRAWBRIDGE_SAVE_INITIAL_LATENCY_LIMIT"] ?? "") ?? limit
            XCTAssertLessThan(Date().timeIntervalSince(start), pass == 1 ? firstLimit : limit)
            print("APPLICATION SAVE COMPLETION (pass \(pass)): \(Date().timeIntervalSince(start))s")
            let reopened = try XCTUnwrap(PDFDocument(url: source))
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened), expected)
            XCTAssertEqual(expected.count, originalCount + pass * additionsPerPass)
            XCTAssertLessThan(try Data(contentsOf: source).count, originalSize + 200_000)
        }
        if let root = ProcessInfo.processInfo.environment["DRAWBRIDGE_RECTANGLE_CORPUS"] {
            try Data(contentsOf: source).write(to: URL(fileURLWithPath: root).appendingPathComponent("six-markup-saved.pdf"))
        }
    }

    func testVerifiedInspectionCacheRejectsExternallyReplacedPDF() throws {
        let source = try fixture(rotation: 0), replacement = try fixture(rotation: 90)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: replacement) }
        let first = try XCTUnwrap(PDFDocument(url: source))
        let session = RectangleMarkupController()
        session.bind(to: first)
        _ = try XCTUnwrap(session.create(on: first.page(at: 0)!, bounds: CGRect(x: 100,y: 100,width: 60,height: 40)))
        XCTAssertTrue(PDFRectangleWriter.write(document: first, source: source, destination: source, pageLabels: [:], records: RectangleMarkupRecord.capture(first)))
        // A prior successful save cached this URL. Replace its bytes externally
        // before the next save; the old object graph must never be reused.
        try Data(contentsOf: replacement).write(to: source)
        let second = try XCTUnwrap(PDFDocument(url: source))
        session.bind(to: second)
        let page = try XCTUnwrap(second.page(at: 0))
        _ = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 120,y: 120,width: 60,height: 40)))
        let expected = RectangleMarkupRecord.capture(second)
        XCTAssertTrue(PDFRectangleWriter.write(document: second, source: source, destination: source, pageLabels: [:], records: expected))
        let reopened = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(reopened.page(at: 0)?.rotation, 90)
        XCTAssertEqual(reopened.page(at: 0)?.bounds(for: .cropBox), page.bounds(for: .cropBox))
        XCTAssertEqual(RectangleMarkupRecord.capture(reopened), expected)
        XCTAssertEqual(reopened.string, second.string)
    }

    func testMetadataOnlyChangesPermitSaveButContentChangesStillReject() throws {
        let source = try fixture(rotation: 180)
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source)), session = RectangleMarkupController()
        session.bind(to: document)
        let stamp = try XCTUnwrap(session.sourceStamp)
        _ = try XCTUnwrap(session.create(on: document.page(at: 0)!, bounds: CGRect(x: 120,y: 150,width: 80,height: 60)))
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        XCTAssertTrue(stamp.matchesSource(source))
        let bytes = try Data(contentsOf: source)
        let location = try XCTUnwrap(bytes.range(of: Data("/Rotate 180".utf8)))
        let handle = try FileHandle(forWritingTo: source)
        try handle.seek(toOffset: UInt64(location.lowerBound)); try handle.write(contentsOf: Data("/Rotate 270".utf8)); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: attrs[.modificationDate]!], ofItemAtPath: source.path)
        XCTAssertFalse(stamp.matchesSource(source))
        XCTAssertFalse(PDFRectangleWriter.write(document: document, source: source, destination: source, pageLabels: [:], records: RectangleMarkupRecord.capture(document), expectedSourceStamp: stamp))
        try bytes.write(to: source)
        let reopened = try XCTUnwrap(PDFDocument(url: source))
        session.bind(to: reopened)
        _ = try XCTUnwrap(session.create(on: reopened.page(at: 0)!, bounds: CGRect(x: 120,y: 150,width: 80,height: 60)))
        let cleanStamp = try XCTUnwrap(session.sourceStamp)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: source, pageLabels: [:], records: RectangleMarkupRecord.capture(reopened), expectedSourceStamp: cleanStamp))
    }

    func testInspectionCacheRejectsSameSizeInPlaceEditWithRestoredModificationDate() throws {
        let source = try fixture(rotation: 180)
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source)), session = RectangleMarkupController()
        session.bind(to: document)
        _ = try XCTUnwrap(session.create(on: document.page(at: 0)!, bounds: CGRect(x: 120,y: 150,width: 80,height: 60)))
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: source, pageLabels: [:], records: RectangleMarkupRecord.capture(document)))
        // Alter the original page dictionary without replacing the inode or
        // changing the file size, then restore mtime as some external editors do.
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let sourceStamp = try XCTUnwrap(PDFMarkupSourceStamp.read(source))
        let bytes = try Data(contentsOf: source)
        let old = Data("/Rotate 180".utf8), new = Data("/Rotate 270".utf8)
        let location = try XCTUnwrap(bytes.range(of: old, options: .backwards))
        let handle = try FileHandle(forWritingTo: source)
        try handle.seek(toOffset: UInt64(location.lowerBound)); try handle.write(contentsOf: new); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: source.path)
        XCTAssertEqual(try Data(contentsOf: source).count, bytes.count)
        XCTAssertNotEqual(PDFMarkupSourceStamp.read(source), sourceStamp)
        XCTAssertFalse(PDFRectangleWriter.write(document: document, source: source, destination: source, pageLabels: [:], records: RectangleMarkupRecord.capture(document), expectedSourceStamp: sourceStamp))
        let changedDocument = try XCTUnwrap(PDFDocument(data: Data(contentsOf: source))); session.bind(to: changedDocument)
        _ = try XCTUnwrap(session.create(on: changedDocument.page(at: 0)!, bounds: CGRect(x: 230,y: 180,width: 60,height: 40)))
        XCTAssertTrue(PDFRectangleWriter.write(document: changedDocument, source: source, destination: source, pageLabels: [:], records: RectangleMarkupRecord.capture(changedDocument)))
        XCTAssertEqual(PDFDocument(data: try Data(contentsOf: source))?.page(at: 0)?.rotation, 270)
    }

    func testSmallSaveReusesHundredsOfExistingTextAppearances() throws {
        let source = try fixture(rotation: 0)
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        var records = (0..<200).map { index -> RectangleMarkupRecord in
            var record = RectangleMarkupRecord(id: RectangleMarkupRecord.prefix + "existing-\(index)", pageIndex: 0, bounds: CGRect(x: 100,y: 100,width: 120,height: 50), red: 1, green: 0, blue: 0, lineWidth: 2)
            record.kind = .text; record.text = "Review wall \(index)"
            return record
        }
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: source, pageLabels: [:], records: records))
        let original = try Data(contentsOf: source)
        let reopened = try XCTUnwrap(PDFDocument(url: source))
        for index in 0..<6 {
            records.append(RectangleMarkupRecord(id: RectangleMarkupRecord.prefix + "new-\(index)", pageIndex: 0, bounds: CGRect(x: 250,y: 180,width: 80,height: 60), red: 1, green: 0, blue: 0, lineWidth: 2))
        }
        let start = Date()
        XCTAssertTrue(PDFRectangleWriter.write(document: reopened, source: source, destination: source, pageLabels: [:], records: records))
        print("SIX NEW MARKUPS WITH 200 EXISTING TEXT MARKUPS: \(Date().timeIntervalSince(start))s")
        let saved = try Data(contentsOf: source)
        XCTAssertEqual(saved.prefix(original.count), original)
        // Rebuilding the 200 text appearances would append hundreds of KB.
        XCTAssertLessThan(saved.count - original.count, 20_000)
        func trailerSize(_ bytes: Data) throws -> Int {
            let text = String(decoding: bytes, as: UTF8.self) as NSString
            let regex = try NSRegularExpression(pattern: "/Size ([0-9]+)")
            let last = try XCTUnwrap(regex.matches(in: text as String, range: NSRange(location: 0,length: text.length)).last)
            return try XCTUnwrap(Int(text.substring(with: last.range(at: 1))))
        }
        XCTAssertLessThanOrEqual(try trailerSize(saved) - trailerSize(original), 14, "Unchanged markups must not allocate new object IDs")
        XCTAssertEqual(RectangleMarkupRecord.capture(try XCTUnwrap(PDFDocument(url: source))), records)
    }

    func testSaveCompletionAdvancesSourceVersionWithoutDiscardingNewerEdits() throws {
        let source = try fixture(rotation: 0)
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source)), session = RectangleMarkupController()
        session.bind(to: document)
        let page = try XCTUnwrap(document.page(at: 0))
        _ = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 120,y: 150,width: 80,height: 60)))
        let stamp = try XCTUnwrap(session.sourceStamp), snapshot = RectangleMarkupRecord.capture(document)
        _ = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 230,y: 180,width: 60,height: 40)))
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: source, pageLabels: [:], records: snapshot, expectedSourceStamp: stamp))
        session.acceptPersistedSource(at: source)
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertNotEqual(session.sourceStamp, stamp)
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: source, pageLabels: [:], records: RectangleMarkupRecord.capture(document), expectedSourceStamp: session.sourceStamp))
        XCTAssertEqual(RectangleMarkupRecord.capture(try XCTUnwrap(PDFDocument(url: source))).count, 2)
    }

    func testIncrementalMutationBoundaryRejectsDrawingAndImportedMarkupChanges() throws {
        let page: [String: Any] = ["/Type": "/Page", "/Contents": "4 0 R", "/Resources": ["/Font": "6 0 R"], "/Rotate": 0, "/MediaBox": [0,0,600,400], "/Annots": ["5 0 R"]]
        let objects: [String: Any] = ["trailer": ["value": ["/Root": "1 0 R"]], "obj:1 0 R": ["value": ["/Type": "/Catalog", "/Pages": "2 0 R"]], "obj:3 0 R": ["value": page], "obj:4 0 R": ["stream": ["dict": [:], "data": "original"]], "obj:5 0 R": ["value": ["/Subtype": "/Square", "/Contents": "u:Consultant"]]]
        func graph(_ table: [String: Any]) -> [String: Any] { ["pages": [["object": "3 0 R"]], "qpdf": [["maxobjectid": 6], table]] }
        let baseline = graph(objects)
        for (field, value) in [("/Rotate", 90 as Any), ("/Contents", "7 0 R" as Any), ("/Resources", [String: Any]() as Any), ("/MediaBox", [0,0,400,600] as Any), ("/Annots", [Any]() as Any)] {
            var modified = objects, changedPage = page; changedPage[field] = value
            modified["obj:3 0 R"] = ["value": changedPage]
            XCTAssertFalse(try PDFRectangleWriter.preservesOriginalObjects(baseline: baseline, updated: graph(modified), changed: ["obj:3 0 R"]), field)
        }
        for key in ["obj:4 0 R", "obj:5 0 R"] {
            var modified = objects; modified[key] = ["value": ["/Contents": "u:Changed"]]
            XCTAssertFalse(try PDFRectangleWriter.preservesOriginalObjects(baseline: baseline, updated: graph(modified), changed: [key]))
        }
    }

    func testBackgroundMarkupSaveLatency() async throws {
        let source = try fixture(rotation: 0)
        let output = source.deletingLastPathComponent().appendingPathComponent("BackgroundMarkup-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let doc = try XCTUnwrap(PDFDocument(url: source))
        let box = SaveBenchmarkDocument(document: doc)
        let record = RectangleMarkupRecord(id: RectangleMarkupRecord.prefix + UUID().uuidString, pageIndex: 0, bounds: CGRect(x: 100,y: 100,width: 80,height: 60), red: 1,green: 0,blue: 0,lineWidth: 2)
        let start = Date()
        let success = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: PDFRectangleWriter.write(document: box.document, source: source, destination: output, pageLabels: [:], records: [record]))
            }
        }
        XCTAssertTrue(success)
        print("BACKGROUND MARKUP SAVE: \(Date().timeIntervalSince(start))s")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testActiveToolHighlightTracksEveryToolAndDisabledState() throws {
        _ = NSApplication.shared
        let controller = MainViewController()
        _ = controller.view
        controller.pdfView.rectangleMarkup.canEdit = { true }
        let buttons = [controller.rectangleToolbar.selectButton, controller.rectangleToolbar.rectangleButton,
                       controller.rectangleToolbar.ellipseButton, controller.rectangleToolbar.lineButton,
                       controller.rectangleToolbar.arrowButton, controller.rectangleToolbar.polygonButton,
                       controller.rectangleToolbar.polylineButton, controller.rectangleToolbar.textButton]
        let tools: [RectangleMarkupController.Tool] = [.select,.rectangle,.ellipse,.line,.arrow,.polygon,.polyline,.text]
        for (index, tool) in tools.enumerated() {
            controller.pdfView.rectangleMarkup.tool = tool
            XCTAssertEqual(buttons.enumerated().filter { $0.element.showsActiveTool }.map { $0.offset }, [index])
        }
        controller.pdfView.rectangleMarkup.canEdit = { false }
        controller.refreshRectangleToolbar()
        XCTAssertFalse(buttons.contains { $0.showsActiveTool })
    }

    func testMarkupControlsAreInstalledSeparatelyAndDisabledWithoutPDF() throws {
        _ = NSApplication.shared
        let controller = MainViewController()
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1400,height:900),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.contentViewController = controller; window.toolbar = controller.makeToolbar(); window.layoutIfNeeded()
        let item = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier == .drawbridgeMarkupControls })
        XCTAssertTrue(item.view === controller.rectangleToolbar)
        XCTAssertFalse(controller.rectangleToolbar.rectangleButton.isEnabled)
        XCTAssertFalse(controller.rectangleToolbar.deleteButton.isEnabled)
        XCTAssertFalse(controller.rectangleToolbar.ellipseButton.isEnabled)
        XCTAssertFalse(controller.rectangleToolbar.lineButton.isEnabled)
        XCTAssertFalse(controller.rectangleToolbar.arrowButton.isEnabled)
        XCTAssertFalse(controller.rectangleToolbar.arrangedSubviews.contains { ($0 as? NSTextField)?.stringValue == "Markup" })
        XCTAssertTrue(window.toolbar?.items.contains { $0.itemIdentifier == .drawbridgePrimaryControls } == true)
    }
}
