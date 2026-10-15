import AppKit
import PDFKit

extension MarkupLinePattern: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let pattern = Self(rawValue: value) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown line pattern") }
        self = pattern
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Clipboard input is typed, validated JSON, never an object-instance archive.
@MainActor
enum MarkupClipboard {
    static let type = NSPasteboard.PasteboardType("com.drawbridge.markups.v1")
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumItems = 10000
    // Detached clipboard annotations have no page from which to recover rotation.
    static let snapshotRotationKey = PDFAnnotationKey(rawValue: "DrawbridgeClipboardSnapshotRotation")
    static func capture(_ annotation: PDFAnnotation) -> RectangleMarkupRecord? {
        guard var record = RectangleMarkupRecord.capture(annotation: annotation, pageIndex: 0) else { return nil }
        if record.kind == .snapshot, annotation.page == nil,
           let rotation = annotation.value(forAnnotationKey: snapshotRotationKey) as? Int {
            record.textRotation = rotation
        }
        return record
    }
    private struct Entry: Codable { let record: RectangleMarkupRecord; let contents: String? }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    static func copy(_ annotations: [PDFAnnotation], to board: NSPasteboard = .general) -> Bool {
        guard !annotations.isEmpty, annotations.count <= maximumItems else { return false }
        let records = annotations.compactMap { capture($0) }
        guard records.count == annotations.count, records.allSatisfy(\.isValid),
              let data = try? JSONEncoder().encode(Envelope(version: 1, entries: zip(records, annotations).map { Entry(record: $0.0, contents: $0.1.contents) })),
              data.count <= maximumBytes else { return false }
        var representations: [(NSPasteboard.PasteboardType, Data)] = [(type, data)]
        if records.count == 1, let record = records.first, record.kind == .snapshot {
            guard let pdf = record.snapshotData, pdf.count <= SnapshotPayload.maximumBytes,
                  let placement = try? JSONEncoder().encode(SnapshotPayload.Placement(
                    x: record.bounds.minX, y: record.bounds.minY,
                    width: record.bounds.width, height: record.bounds.height, rotation: record.textRotation)),
                  let style = record.snapshotStyle.json.data(using: .utf8),
                  placement.count < 2048, style.count < 2048 else { return false }
            representations += [(.pdf, pdf), (SnapshotPayload.clipboardType, pdf),
                                (SnapshotPayload.placementType, placement), (SnapshotPayload.styleType, style)]
        }
        board.clearContents()
        var success = true
        for (type, data) in representations {
            if !board.setData(data, forType: type) { success = false }
        }
        return success
    }
    private static func validClipboardEntry(_ entry: Entry) -> Bool {
        let record = entry.record
        return record.isValid && record.pageScale == nil && !record.pageScaleCleared &&
        (record.kind != .text || entry.contents == record.text)
    }
    private static var cachedBoardName: NSPasteboard.Name?
    private static var cachedChangeCount = -1
    private static var cachedRecords: [Entry]?

    private static func records(from board: NSPasteboard) -> [Entry]? {
        if cachedBoardName == board.name && cachedChangeCount == board.changeCount { return cachedRecords }
        cachedBoardName = board.name
        cachedChangeCount = board.changeCount
        cachedRecords = nil
        guard let data = board.data(forType: type), !data.isEmpty, data.count <= maximumBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 1, !envelope.entries.isEmpty, envelope.entries.count <= maximumItems,
              envelope.entries.allSatisfy(validClipboardEntry) else { return nil }
        cachedRecords = envelope.entries
        return cachedRecords
    }
    /// Menu validation never constructs annotations or renders snapshot previews.
    static func canPaste(from board: NSPasteboard = .general) -> Bool { records(from: board) != nil }

    static func read(from board: NSPasteboard = .general) -> [PDFAnnotation]? {
        guard let records = records(from: board) else { return nil }
        // Rebuild fresh instances for each paste; failed items reject the whole payload.
        let annotations = records.compactMap { try? $0.record.clipboardAnnotation(contents: $0.contents) }
        return annotations.count == records.count ? annotations : nil
    }
}

extension RectangleMarkupRecord {
    @MainActor func clipboardAnnotation(contents: String?, rotation: Int? = nil) throws -> PDFAnnotation {
        guard isValid else { throw CocoaError(.fileReadCorruptFile) }
        let annotation: PDFAnnotation
        if kind == .snapshot {
            annotation = try SnapshotStampFactory.make(payload: SnapshotPayload(data: snapshotData!), bounds: bounds, rotation: rotation ?? textRotation, style: snapshotStyle)
            annotation.setValue(snapshotData!.base64EncodedString(), forAnnotationKey: SnapshotPayload.key)
            annotation.setValue(snapshotStyle.json, forAnnotationKey: SnapshotStyle.key)
            annotation.setValue(rotation ?? textRotation, forAnnotationKey: MarkupClipboard.snapshotRotationKey)
        } else {
            let type: PDFAnnotationSubtype = kind == .polygon ? PDFAnnotationSubtype(rawValue: "/Polygon") : kind == .polyline ? .ink : kind == .text ? .freeText : kind == .ellipse ? .circle : (kind == .line || kind == .arrow ? .line : .square)
            if kind == .polygon { annotation = DrawbridgePolygonAnnotation(bounds: bounds, forType: type, withProperties: nil) }
            else if measurement != nil { annotation = DrawbridgeMeasuredPathAnnotation(bounds: bounds, forType: type, withProperties: nil) }
            else if kind == .rectangle || kind == .ellipse { annotation = DrawbridgeShapeAnnotation(bounds: bounds, forType: type, withProperties: nil) }
            else { annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil) }
            let color = NSColor(deviceRed: red, green: green, blue: blue, alpha: 1)
            if kind == .text {
                annotation.alignment = .left
                RectangleMarkupRecord.setTextColor(color, on: annotation)
                RectangleMarkupRecord.setTextFontSize(fontSize, on: annotation)
            } else { annotation.color = color }
            let border = PDFBorder(); border.lineWidth = kind == .text ? 0 : lineWidth; annotation.border = border
            MarkupStyle.apply(pattern: linePattern, opacity: strokeOpacity, to: annotation)
            if [.rectangle, .ellipse, .polygon].contains(kind) {
                let color = fill.map { NSColor(deviceRed: $0[0], green: $0[1], blue: $0[2], alpha: fillOpacity) }
                RectangleMarkupRecord.setPolygonFill(color, on: annotation)
                annotation.setValue(fillOpacity, forAnnotationKey: MarkupStyle.fillOpacityKey)
                DraftingHatch.apply(hatch, to: annotation)
            }
            if let start, let end {
                annotation.startPoint = CGPoint(x: start.x - bounds.minX, y: start.y - bounds.minY)
                annotation.endPoint = CGPoint(x: end.x - bounds.minX, y: end.y - bounds.minY)
                annotation.endLineStyle = kind == .arrow ? .openArrow : .none
            }
            if !vertices.isEmpty { Self.setVertices(vertices, on: annotation) }
            if let inkTool { annotation.setValue(inkTool, forAnnotationKey: Self.inkToolKey) }
        }
        annotation.contents = contents
        annotation.setValue(author, forAnnotationKey: PDFAnnotationKey(rawValue: "/T"))
        annotation.setValue(Self.prefix + UUID().uuidString, forAnnotationKey: Self.identityKey)
        if let measurement {
            annotation.setValue(MeasurementMetadata.json(measurement), forAnnotationKey: MeasurementMetadata.measurementKey)
            MeasurementMetadata.updateLabel(annotation)
        }
        if let layerID { annotation.setValue(layerID, forAnnotationKey: MarkupLayers.membershipKey) }
        // The destination's layer catalog owns visibility/locks; do not import a foreign catalog.
        annotation.shouldDisplay = true; annotation.shouldPrint = true
        return annotation
    }
}

extension RectangleMarkupController {
    @discardableResult
    func pasteMarkups(_ items: [PDFAnnotation], on page: PDFPage, center: CGPoint, inPlace: Bool = false) -> [PDFAnnotation] {
        guard canEdit(), !activeLayerIsLocked, !isCapturingSnapshot, page.document === view?.document,
              !items.isEmpty, items.count <= MarkupClipboard.maximumItems,
              center.x.isFinite, center.y.isFinite else { return [] }
        var records = items.compactMap { MarkupClipboard.capture($0) }
        guard records.count == items.count, records.allSatisfy(\.isValid),
              !records.contains(where: { $0.pageScale != nil || $0.pageScaleCleared }),
              items.allSatisfy({ !$0.isReadOnly && !layerIsLocked($0) }),
              !records.contains(where: { $0.measurement != nil }) || MeasurementMetadata.supportedPage(page) else { return [] }
        // Preserve resized dimensions, adapting only their page-space orientation.
        // This must precede the group union and crop-box placement constraints.
        for index in records.indices where records[index].kind == .snapshot {
            if records[index].textRotation % 180 != ((page.rotation % 360 + 360) % 360) % 180 {
                let bounds = records[index].bounds
                records[index].bounds = CGRect(x: bounds.midX - bounds.height / 2,
                                               y: bounds.midY - bounds.width / 2,
                                               width: bounds.height, height: bounds.width)
            }
        }
        let union = records.reduce(CGRect.null) { $0.union($1.bounds) }
        let crop = page.bounds(for: view?.displayBox ?? .cropBox)
        var dx = inPlace ? 0 : center.x - union.midX, dy = inPlace ? 0 : center.y - union.midY
        if !inPlace {
            if union.width <= crop.width { dx = min(max(dx, crop.minX - union.minX), crop.maxX - union.maxX) }
            if union.height <= crop.height { dy = min(max(dy, crop.minY - union.minY), crop.maxY - union.maxY) }
        }
        var copies: [PDFAnnotation] = []
        for index in records.indices {
            // Vertices/endpoints are absolute in the DTO; capture before changing bounds.
            records[index].vertices = records[index].vertices.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            if let start = records[index].start { records[index].start = CGPoint(x: start.x + dx, y: start.y + dy) }
            if let end = records[index].end { records[index].end = CGPoint(x: end.x + dx, y: end.y + dy) }
            records[index].bounds = records[index].bounds.offsetBy(dx: dx, dy: dy)
            guard let annotation = try? records[index].clipboardAnnotation(contents: items[index].contents, rotation: page.rotation) else { return [] }
            // Preserve known source layers; unknown cross-document layers go to the active layer.
            if !layerCatalog.layers.contains(where: { $0.id == records[index].layerID }) {
                annotation.removeValue(forAnnotationKey: MarkupLayers.membershipKey)
                assignNewMarkupLayer(annotation)
            }
            copies.append(annotation)
        }
        tool = .select
        undo.beginUndoGrouping()
        restoreClipboardPresence(true, items: copies, page: page, selection: copies)
        undo.endUndoGrouping()
        return copies
    }
    private func restoreClipboardPresence(_ exists: Bool, items: [PDFAnnotation], page: PDFPage, selection: [PDFAnnotation]) {
        let previous = selectedItems
        undo.registerUndo(withTarget: self) { $0.restoreClipboardPresence(!exists, items: items, page: page, selection: previous) }
        undo.setActionName("Paste Markups")
        for item in items {
            (item as? DrawbridgeSnapshotAnnotation)?.isRetired = !exists
            item.shouldDisplay = exists
            if exists { page.addAnnotation(item) } else { page.removeAnnotation(item) }
        }
        applyLayerVisibility(); setSelectedItems(selection); changed(page)
    }
}
