import AppKit
import PDFKit
import CryptoKit

private final class OriginalDrawingBase: @unchecked Sendable {
    let url: URL
    let digest: String
    private let directory: URL
    init(bytes: Data) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgeDrawingBase-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent("base.pdf")
        try bytes.write(to: url, options: .atomic)
        digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

@MainActor final class OriginalDrawingLayerCoordinator {
    private final class State {
        let base: OriginalDrawingBase
        let pages: [ObjectIdentifier]
        var generation = UUID()
        var task: Task<Void, Never>?
        var pending = false
        var prepared: (key: String, data: Data)?
        var presentation: PDFDocument?
        init(_ base: OriginalDrawingBase, document: PDFDocument) { self.base = base; pages = (0..<document.pageCount).compactMap(document.page(at:)).map(ObjectIdentifier.init) }
    }
    private weak var editor: MainViewController?
    private let states = NSMapTable<PDFDocument, State>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    init(editor: MainViewController) { self.editor = editor }

    private func state(for document: PDFDocument) async throws -> State {
        guard let editor else { throw CancellationError() }
        if editor.sharedReview?.review(for:document) == nil, editor.pageStructureState?.document === document,
           editor.pageStructureState?.plan(for:document) != nil {
            throw NativePDFLayerMutation.Failure.unsupported("save page order changes before changing original drawing layers")
        }
        if let state = states.object(forKey: document) {
            guard state.pages == (0..<document.pageCount).compactMap(document.page(at:)).map(ObjectIdentifier.init) else {
                throw NativePDFLayerMutation.Failure.unsupported("reopen the PDF after changing page order before changing original drawing layers")
            }
            return state
        }
        let bytes = editor.sharedReview?.review(for: document)?.basePDF
        let source = editor.currentPDFWorkingSource(fallback: editor.openDocumentURL)
        let expectedStamp = bytes == nil ? editor.currentPDFWorkingStamp : nil
        let base = try await Task.detached(priority: .userInitiated) {
            if bytes == nil, let source, let expectedStamp, !expectedStamp.matchesSource(source) {
                throw NativePDFLayerMutation.Failure.unsupported("the source PDF changed outside Drawbridge; reopen it before changing drawing layers")
            }
            let before = bytes == nil ? source.flatMap(PDFMarkupSourceStamp.read) : nil
            guard let data = try bytes ?? source.map({ try Data(contentsOf: $0) }) else { throw CancellationError() }
            if bytes == nil, let source, before == nil || PDFMarkupSourceStamp.read(source) != before {
                throw NativePDFLayerMutation.Failure.unsupported("the source PDF changed while reading drawing layers")
            }
            return try OriginalDrawingBase(bytes: data)
        }.value
        if let existing = states.object(forKey: document) { return existing }
        let state = State(base, document: document); states.setObject(state, forKey: document); return state
    }
    private func records(_ document: PDFDocument) -> [RectangleMarkupRecord] {
        (0..<document.pageCount).flatMap { index in
            (document.page(at: index)?.annotations ?? []).compactMap { annotation in
                guard NativeDrawingAssignment.read(annotation) != nil else { return nil }
                return RectangleMarkupRecord.capture(annotation: annotation, pageIndex: index)
            }
        }.sorted { $0.id < $1.id }
    }
    private func visibility() -> [Int: Bool] {
        guard let session = editor?.pdfView.rectangleMarkup, let state = session.layerState else { return [:] }
        return Dictionary(uniqueKeysWithValues: state.pdfVisibility.compactMap { index, visible in
            guard state.pdfLayers.indices.contains(index) else { return nil }
            return (state.pdfLayers[index].registryIndex, visible)
        })
    }
    private func key(_ records: [RectangleMarkupRecord], _ visibility: [Int: Bool]) -> String {
        let paths = records.compactMap { record -> String? in
            guard let drawing = record.nativeDrawing else { return nil }
            return "\(record.pageIndex):\(drawing.path):\(record.pdfLayerIndex.map(String.init) ?? "none"):\(drawing.originalLayers):\(drawing.fingerprint ?? "")"
        }.sorted().joined(separator: "|")
        return paths + "|" + visibility.keys.sorted().map { "\($0):\(visibility[$0]!)" }.joined(separator: "|")
    }
    nonisolated private static func render(base: OriginalDrawingBase, records: [RectangleMarkupRecord], visibility: [Int: Bool]) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgeDrawingPreview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("preview.pdf")
        guard let source = PDFDocument(url: base.url) else { throw NativePDFLayerMutation.Failure.invalid }
        let labels = Dictionary(uniqueKeysWithValues: (0..<source.pageCount).compactMap { index in source.page(at: index)?.label.map { (index, $0) } })
        guard PDFRectangleWriter.write(document: source, source: base.url, destination: output, pageLabels: labels, records: records) else {
            throw NativePDFLayerMutation.Failure.unsupported("the drawing-layer edit could not be verified")
        }
        var current = output
        var retained: [NativePDFLayerMutation.Output] = []
        for index in visibility.keys.sorted() {
            let next = try NativePDFLayerMutation.transform(source: current, registryIndex: index, operation: .visibility(visibility[index]!))
            retained.append(next); current = next.url
        }
        if let native = PDFDocument(url: current) {
            let hidden = EmbeddedPDFLayers.read(native).enumerated().compactMap { $0.element.visible == false ? $0.offset : nil }
            if let filtered = try NativeDrawingLayerPatch.displayCopy(source: current, hiddenIndices: hidden) {
                retained.append(filtered); current = filtered.url
            }
        }
        return try withExtendedLifetime(retained) { try Data(contentsOf: current) }
    }
    private func install(_ bytes: Data, state: State, document: PDFDocument) throws {
        guard let editor, editor.pdfView.document === document,
              state.pages == (0..<document.pageCount).compactMap(document.page(at:)).map(ObjectIdentifier.init), let presentation = PDFDocument(data: bytes), presentation.pageCount == document.pageCount else { throw CancellationError() }
        state.presentation = presentation
        if let review = editor.sharedReview?.review(for: document) { try review.installDerivedLayerPresentation(bytes) }
        else { restore(document: document) }
        for view in [editor.pdfView, editor.secondaryPDFView].compactMap({ $0 }) {
            guard view.rectangleMarkup === editor.pdfView.rectangleMarkup else { continue }
            for page in view.visiblePages { view.refreshAnnotationRendering(on: page, importedAppearanceChanged: true, reason: .snapshotPresenceChanged) }
        }
    }
    func restore(document: PDFDocument) {
        guard let editor, let presentation = states.object(forKey: document)?.presentation else { return }
        for view in [editor.pdfView, editor.secondaryPDFView].compactMap({ $0 }) where view.rectangleMarkup === editor.pdfView.rectangleMarkup {
            guard let target = view.document, !view.reviewLayerPresentation.isInstalled(in: target) else { continue }
            view.reviewLayerPresentation.install(presentation, for: target, box: view.displayBox)
        }
    }
    func assign(page: PDFPage, selection: PDFLineworkIndex.NativeSelection, layer: Int?) async throws {
        guard let editor, let document = page.document, editor.pdfView.document === document,
              editor.pdfView.rectangleMarkup.canEdit(), layer == nil || (editor.pdfView.rectangleMarkup.layerState?.pdfLayers.indices.contains(layer!) == true) else { throw CancellationError() }
        let session = editor.pdfView.rectangleMarkup, index = document.index(for: page)
        let existing = page.annotations.first { NativeDrawingAssignment.read($0)?.path == selection.path }
        guard existing?.isReadOnly != true else { throw NativePDFLayerMutation.Failure.unsupported("this drawing-layer assignment belongs to another reviewer") }
        let state = try await state(for: document), generation = state.generation
        let before = records(document), flags = visibility(), base = state.base
        let inspection = try await Task.detached(priority: .userInitiated) {
            try NativeDrawingLayerPatch.inspect(source: base.url, page: index, path: selection.path, target: layer)
        }.value
        let old = existing.flatMap(NativeDrawingAssignment.read)
        if let fingerprint = old?.fingerprint, fingerprint != inspection.fingerprint { throw NativePDFLayerMutation.Failure.unsupported("the selected drawing path changed outside Drawbridge") }
        let assignment = NativeDrawingAssignment(path: selection.path, originalLayers: old?.originalLayers ?? inspection.layers, fingerprint: old?.fingerprint ?? inspection.fingerprint)
        let seed = base.digest + "|\(index)|\(selection.path)"
        let id = existing.flatMap(RectangleMarkupRecord.identity) ?? RectangleMarkupRecord.prefix + "drawing-" + SHA256.hash(data: Data(seed.utf8)).map { String(format:"%02x",$0) }.joined()
        let box = selection.bounds.insetBy(dx: -1, dy: -1)
        var record = RectangleMarkupRecord(id: id, pageIndex: index, bounds: box, red: 0, green: 0, blue: 0, lineWidth: 1)
        record.nativeDrawing = assignment; record.pdfLayerIndex = layer; record.strokeOpacity = 0
        let proposed = before.filter { $0.id != id } + [record]
        let rendered = try await Task.detached(priority: .userInitiated) { try Self.render(base: base, records: proposed, visibility: flags) }.value
        guard editor.pdfView.document === document, document.index(for:page) == index,
              state.pages == (0..<document.pageCount).compactMap(document.page(at:)).map(ObjectIdentifier.init), state.generation == generation, records(document) == before, visibility() == flags,
              session.canEdit(), existing?.isReadOnly != true else { throw CancellationError() }
        state.prepared = (key(proposed, flags), rendered)
        try session.commitNativeDrawingAssignment(record, on: page)
    }
    func setVisible(_ layer: EmbeddedPDFLayers.Layer, visible: Bool, document: PDFDocument) async throws {
        guard let editor, editor.pdfView.document === document,
              let sessionState = editor.pdfView.rectangleMarkup.layerState,
              let ordinal = sessionState.pdfLayers.firstIndex(where: { $0.registryIndex == layer.registryIndex }) else { throw CancellationError() }
        let state = try await state(for: document), base = state.base
        for _ in 0..<4 {
            let generation = state.generation, current = records(document), beforeFlags = visibility()
            var flags = beforeFlags; flags[layer.registryIndex] = visible
            let rendered = try await Task.detached(priority: .userInitiated) { try Self.render(base: base, records: current, visibility: flags) }.value
            guard editor.pdfView.document === document else { throw CancellationError() }
            // A remote layer assignment may arrive while qpdf is rendering.
            // Rebase the requested visibility on that assignment rather than
            // dropping the user's checkbox action or displaying an older base.
            guard state.generation == generation, records(document) == current, visibility() == beforeFlags else { continue }
            sessionState.pdfVisibility[ordinal] = visible
            try install(rendered, state: state, document: document)
            editor.pdfView.rectangleMarkup.applyLayerVisibility()
            editor.rectangleToolbar.propertiesController.layersView.refresh()
            return
        }
        throw NativePDFLayerMutation.Failure.unsupported("drawing layers changed repeatedly while updating the view; try the visibility change again")
    }
    func schedule(on page: PDFPage) {
        guard let document = page.document, let editor, editor.pdfView.document === document else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let state = try await self.state(for: document)
                state.pending = true
                if let prepared = state.prepared, prepared.key == self.key(self.records(document), self.visibility()) {
                    state.prepared = nil; state.pending = false
                    try self.install(prepared.data, state: state, document: document); return
                }
                state.generation = UUID()
                guard state.task == nil else { return }
                state.task = Task { @MainActor [weak self] in
                    defer { state.task = nil }
                    while let self, state.pending, self.editor?.pdfView.document === document {
                        state.pending = false
                        let generation = state.generation, records = self.records(document), flags = self.visibility(), base = state.base
                        do {
                            let rendered = try await Task.detached(priority: .userInitiated) { try Self.render(base: base, records: records, visibility: flags) }.value
                            if state.generation == generation { try self.install(rendered, state: state, document: document) }
                        } catch { self.editor?.runAlert(title: "Drawing Layer Not Changed", informativeText: error.localizedDescription, style: .warning) }
                    }
                }
            } catch { editor.runAlert(title: "Drawing Layer Not Changed", informativeText: error.localizedDescription, style: .warning) }
        }
    }
}
