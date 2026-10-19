import AppKit
import PDFKit
import Darwin

/// Only annotations created by this new authoring path are editable. Imported CAD
/// squares and consultant annotations never match this ownership marker.
struct PDFMarkupSourceStamp: Sendable, Equatable {
    let size: Int
    let modified: Date
    let device: UInt64
    let inode: UInt64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    private var baseline: PDFMarkupSourceBaseline? = nil
    private var sourceBookmark: Data? = nil
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.size == rhs.size && lhs.modified == rhs.modified && lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.modifiedNanoseconds == rhs.modifiedNanoseconds && lhs.changedSeconds == rhs.changedSeconds && lhs.changedNanoseconds == rhs.changedNanoseconds
    }
    func matchesSource(_ url: URL) -> Bool {
        guard let current = Self.read(url) else { return false }
        if current == self { return true }
        guard size == current.size else { return false }
        // File providers can replace an unchanged file with a new inode or
        // timestamps. Accept any identity change only on exact byte equality.
        return baseline?.matches(url) == true && Self.read(url) == current
    }
    static func capture(_ url: URL) -> Self? {
        guard var stamp = read(url) else { return nil }
        stamp.baseline = PDFMarkupSourceBaseline(source: url)
        stamp.sourceBookmark = try? url.bookmarkData(options: .minimalBookmark)
        guard read(url) == stamp else { return nil }
        return stamp
    }
    /// Follow a renamed file/folder only when it is still the verified source.
    /// Never substitute PDFKit's temporary backing URL for a missing original.
    func resolvedSourceURL(preferred url: URL) -> URL? {
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let sourceBookmark else { return nil }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: sourceBookmark,
                options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale),
              matchesSource(resolved) else { return nil }
        return resolved
    }
    var recoverySourceURL: URL? { baseline?.url }
    static func read(_ url: URL) -> Self? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Self(size: Int(info.st_size), modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)),
                    device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino),
                    modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                    changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }
}

/// APFS clones share unchanged storage and cost no full PDF serialization.
private final class PDFMarkupSourceBaseline: @unchecked Sendable {
    let url: URL
    init?(source: URL) {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgeSource-\(UUID().uuidString).pdf")
        if clonefile(source.path, url.path, 0) != 0 {
            // Snapshot data only: copying permission/provider attributes can
            // fail even when the readable PDF bytes are perfectly valid.
            guard copyfile(source.path, url.path, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_EXCL)) == 0 else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        }
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func matches(_ source: URL) -> Bool {
        guard let original = try? Data(contentsOf: url, options: .mappedIfSafe),
              let current = try? Data(contentsOf: source, options: .mappedIfSafe) else { return false }
        return original == current
    }
}

struct RectangleMarkupRecord: Codable, Sendable, Equatable {
    static let prefix = "DrawbridgeRectangleV1:"
    enum Kind: String, Codable, Sendable { case rectangle, ellipse, line, arrow, text, polyline, polygon, snapshot }
    static let inkToolKey = PDFAnnotationKey(rawValue: "DrawbridgeInkTool")
    var inkTool: String? = nil
    var linePattern: MarkupLinePattern = .solid
    var strokeOpacity: Double = 1
    var fillOpacity: Double = 1
    var hatch: DraftingHatch? = nil
    var layerID: String? = nil
    var layerCatalog: String? = nil
    var snapshotStyle = SnapshotStyle()
    var snapshotData: Data? = nil
    var measurement: DrawingMeasurement? = nil
    var pageScale: DrawingScale? = nil
    var pageScaleCleared: Bool = false
    var author: String = ""
    var kind: Kind = .rectangle
    var text: String = ""
    var fontSize: Double = 18
    var textRotation: Int = 0
    var fill: [Double]? = nil
    var vertices: [CGPoint] = []
    var start: CGPoint? = nil
    var end: CGPoint? = nil
    let id: String
    let pageIndex: Int
    var bounds: CGRect
    var red: Double
    var green: Double
    var blue: Double
    var lineWidth: Double

    static let identityKey = PDFAnnotationKey(rawValue: "/NM")
    static func identity(_ annotation: PDFAnnotation) -> String? {
        if let name = annotation.value(forAnnotationKey: identityKey) as? String, name.hasPrefix(prefix) { return name }
        // Compatibility with releases that put the internal ID in the author field.
        return annotation.userName.flatMap { $0.hasPrefix(prefix) ? $0 : nil }
    }
    static func owns(_ annotation: PDFAnnotation) -> Bool {
        ["Square", "Circle", "Line", "FreeText", "Ink", "Polygon", "Stamp"].contains(annotation.type ?? "") && identity(annotation) != nil
    }

    static let fillKey = PDFAnnotationKey(rawValue:"DrawbridgePolygonFill")
    static func polygonFill(_ annotation: PDFAnnotation) -> NSColor? {
        guard let values = annotation.value(forAnnotationKey:fillKey) as? [Double], values.count == 3 else { return nil }
        return NSColor(deviceRed:values[0],green:values[1],blue:values[2],alpha:MarkupStyle.fillOpacity(annotation))
    }
    static func setPolygonFill(_ color: NSColor?, on annotation: PDFAnnotation) {
        let rgb = color?.usingColorSpace(.deviceRGB)
        annotation.setValue(rgb.map { Double($0.alphaComponent) } ?? 1, forAnnotationKey: MarkupStyle.fillOpacityKey)
        annotation.setValue(rgb.map { [Double($0.redComponent),Double($0.greenComponent),Double($0.blueComponent)] } ?? [],forAnnotationKey:fillKey)
    }
    static let verticesKey = PDFAnnotationKey(rawValue: "DrawbridgePolylineVertices")
    static func vertices(_ annotation: PDFAnnotation) -> [CGPoint] {
        guard let values = annotation.value(forAnnotationKey:verticesKey) as? [Double], values.count % 2 == 0 else { return [] }
        return stride(from:0,to:values.count,by:2).map { CGPoint(x:values[$0],y:values[$0+1]) }
    }
    static func setVertices(_ points: [CGPoint], on annotation: PDFAnnotation) {
        annotation.setValue(points.flatMap { [Double($0.x),Double($0.y)] },forAnnotationKey:verticesKey)
        guard annotation.type == "Ink" else { return }
        for path in annotation.paths ?? [] { annotation.remove(path) }
        let path = NSBezierPath()
        for (i,p) in points.enumerated() {
            let local = CGPoint(x:p.x-annotation.bounds.minX,y:p.y-annotation.bounds.minY)
            if i == 0 { path.move(to:local) } else { path.line(to:local) }
        }
        annotation.add(path)
    }

    static let textColorKey = PDFAnnotationKey(rawValue: "DrawbridgeTextColor")
    static let textFontSizeKey = PDFAnnotationKey(rawValue: "DrawbridgeTextFontSize")
    static func textFontSize(_ annotation: PDFAnnotation) -> CGFloat {
        if let size = annotation.value(forAnnotationKey: textFontSizeKey) as? NSNumber,
           size.doubleValue.isFinite, (6...144).contains(size.doubleValue) { return CGFloat(size.doubleValue) }
        return annotation.font?.pointSize ?? 18
    }
    static func markupColor(_ annotation: PDFAnnotation) -> NSColor {
        if annotation.type == "FreeText" {
            if let values = annotation.value(forAnnotationKey: textColorKey) as? [Double], values.count == 3 {
                return NSColor(deviceRed: values[0], green: values[1], blue: values[2], alpha: 1)
            }
            return annotation.fontColor ?? .black
        }
        return annotation.color
    }
    static func setTextColor(_ color: NSColor, on annotation: PDFAnnotation) {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return }
        let size = textFontSize(annotation)
        annotation.setValue([Double(rgb.redComponent),Double(rgb.greenComponent),Double(rgb.blueComponent)], forAnnotationKey: textColorKey)
        annotation.fontColor = color
        annotation.color = .clear
        setTextFontSize(size, on: annotation)
    }
    static func setTextFontSize(_ size: CGFloat, on annotation: PDFAnnotation) {
        annotation.setValue(Double(size), forAnnotationKey: textFontSizeKey)
        annotation.font = NSFont(name: "Helvetica", size: size)
        guard let rgb = markupColor(annotation).usingColorSpace(.deviceRGB) else { return }
        // PDFKit's font setter truncates fractional sizes in /DA. Preserve the
        // exact size using the standard PDF default-appearance declaration.
        annotation.setValue("/Helvetica \(size) Tf \(rgb.redComponent) \(rgb.greenComponent) \(rgb.blueComponent) rg", forAnnotationKey: .defaultAppearance)
    }

    static func capture(_ document: PDFDocument) -> [Self] {
        // PDF editors may preserve /NM when duplicating a markup. Give each owned
        // annotation its own identity without changing its appearance or geometry.
        var seen = Set<String>()
        return (0..<document.pageCount).flatMap { index in
            document.page(at: index)?.annotations.compactMap { annotation -> Self? in
                guard owns(annotation), var id = identity(annotation) else { return nil }
                if !seen.insert(id).inserted {
                    id = prefix + UUID().uuidString
                    annotation.setValue(id, forAnnotationKey: PDFAnnotationKey(rawValue: "/NM"))
                    seen.insert(id)
                }
                return capture(annotation: annotation, pageIndex: index)
            } ?? []
        }
    }

    static func capture(annotation: PDFAnnotation, pageIndex index: Int) -> Self? {
                guard owns(annotation), let id = identity(annotation), let rgb = markupColor(annotation).usingColorSpace(.deviceRGB) else { return nil }
                var record = Self(id: id, pageIndex: index, bounds: annotation.bounds,
                            red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent),
                            lineWidth: Double(annotation.border?.lineWidth ?? 2))
                record.layerID = MarkupLayers.id(annotation)
                record.layerCatalog = annotation.value(forAnnotationKey: MarkupLayers.catalogKey) as? String
                record.inkTool = annotation.type == "Ink" ? annotation.value(forAnnotationKey: inkToolKey) as? String : nil
                record.linePattern = MarkupStyle.pattern(annotation)
                record.strokeOpacity = MarkupStyle.strokeOpacity(annotation)
                record.fillOpacity = MarkupStyle.fillOpacity(annotation)
                record.hatch = DraftingHatch.read(annotation)
                if ["Square", "Circle", "Polygon"].contains(annotation.type ?? ""), let rgb = polygonFill(annotation)?.usingColorSpace(.deviceRGB) { record.fill = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)] }
                record.measurement = MeasurementMetadata.measurement(annotation)
                record.pageScale = MeasurementMetadata.isPageScaleMetadata(annotation) ? (annotation.page.flatMap { MeasurementMetadata.scale(on: $0) } ?? MeasurementMetadata.pageScale(annotation)) : nil
                record.pageScaleCleared = record.pageScale == nil && annotation.value(forAnnotationKey: MeasurementMetadata.clearedScaleKey) as? Bool == true
                if record.measurement != nil { record.textRotation = (((annotation.page?.rotation ?? 0) % 360) + 360) % 360 }
                let author = annotation.userName ?? ""
                record.author = author.hasPrefix(prefix) ? MarkupAuthorPreference.currentName : author
                if annotation.type == "FreeText" {
                    record.kind = .text; record.text = annotation.contents ?? ""; record.fontSize = Double(textFontSize(annotation))
                    record.lineWidth = 2
                    record.textRotation = (((annotation.page?.rotation ?? 0) % 360) + 360) % 360
                }
                if annotation.type == "Ink" || annotation.type == "Polygon" {
                    record.kind = annotation.type == "Polygon" ? .polygon : .polyline; record.vertices = vertices(annotation)
                }
                if annotation.type == "Stamp" { record.lineWidth = 2; record.kind = .snapshot; record.snapshotStyle = SnapshotStyle.read(annotation); record.snapshotData = SnapshotPayload.read(annotation)?.data; record.textRotation = (((annotation.page?.rotation ?? 0) % 360) + 360) % 360 }
                if annotation.type == "Circle" { record.kind = .ellipse }
                if annotation.type == "Line" {
                    record.kind = annotation.endLineStyle == .openArrow ? .arrow : .line
                    record.start = CGPoint(x: annotation.bounds.minX + annotation.startPoint.x, y: annotation.bounds.minY + annotation.startPoint.y)
                    record.end = CGPoint(x: annotation.bounds.minX + annotation.endPoint.x, y: annotation.bounds.minY + annotation.endPoint.y)
                }
                return record
    }

    var isValid: Bool {
        id.hasPrefix(Self.prefix) && pageIndex >= 0 &&
        (hatch == nil || (hatch!.isValid && [.rectangle, .ellipse, .polygon].contains(kind))) &&
        (inkTool == nil || (kind == .polyline && ["pen", "polyline"].contains(inkTool!))) &&
        (kind != .snapshot || (snapshotStyle.isValid && snapshotData != nil && SnapshotPayload(data: snapshotData!).page != nil)) &&
        (pageScale == nil || (kind == .rectangle && pageScale!.isValid && measurement == nil)) &&
        (!pageScaleCleared || (kind == .rectangle && pageScale == nil && measurement == nil)) &&
        (measurement == nil || (measurement!.valid(points: vertices) && (kind == .polygon || kind == .polyline) && (measurement!.closed == (kind == .polygon)))) &&
        [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy { $0.isFinite } &&
        bounds.width >= 2 && bounds.height >= 2 &&
        [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } &&
        (kind != .text || (!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && text.utf8.count <= 100000 && fontSize.isFinite && (6...144).contains(fontSize))) &&
        (fill == nil || ([.rectangle, .ellipse, .polygon].contains(kind) && fill!.count == 3 && fill!.allSatisfy { $0.isFinite && (0...1).contains($0) })) &&
        (!(kind == .polyline || kind == .polygon) || (vertices.count >= (kind == .polygon ? 3 : 2) && vertices.count <= 10000 && vertices.allSatisfy { $0.x.isFinite && $0.y.isFinite && bounds.contains($0) })) &&
        lineWidth.isFinite && (0.25...72).contains(lineWidth) && strokeOpacity.isFinite && (0...1).contains(strokeOpacity) && fillOpacity.isFinite && (0...1).contains(fillOpacity) &&
        (!(kind == .line || kind == .arrow) || (start != nil && end != nil && [start!.x,start!.y,end!.x,end!.y].allSatisfy { $0.isFinite } && bounds.contains(start!) && bounds.contains(end!) && hypot(start!.x-end!.x,start!.y-end!.y) >= 2))
    }
}

/// New annotation interaction state; deliberately independent of legacy ToolMode.
@MainActor
final class RectangleMarkupController {
    enum Tool: String { case select, pen, rectangle, ellipse, line, arrow, text, polyline, polygon, area, perimeter, calibrate, snapshotBox, snapshotPolygon }
    enum Corner: CaseIterable { case lowerLeft, lowerRight, upperLeft, upperRight }
    private enum Gesture {
        case create(PDFPage, CGPoint)
        case vertex(PDFPage, PDFAnnotation, Int)
        case edit(PDFPage, PDFAnnotation, CGRect, CGPoint, Corner?)
    }
    let defaultPreferences: UserDefaults
    private var appearanceBeforeSavedTool: SavedMarkupAppearance?
    init(defaults: UserDefaults = .standard) { defaultPreferences = defaults }
    weak var view: PDFView?
    private weak var boundDocument: PDFDocument?
    let layerStates = NSMapTable<PDFDocument, MarkupLayerState>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private let fallbackUndo = UndoManager()
    // Set when a split first hosts independent documents. Same-document panes
    // continue sharing their existing session and undo history.
    var documentUndoManager: UndoManager?
    var undo: UndoManager { inlineText?.editor.undoManager ?? documentUndoManager ?? view?.window?.undoManager ?? fallbackUndo }
    var selected: PDFAnnotation? { didSet { additionalSelection = [] } }
    private var additionalSelection: [PDFAnnotation] = []
    var selectedItems: [PDFAnnotation] { (selected.map { [$0] } ?? []) + additionalSelection }
    private var groupMove: (page: PDFPage, start: CGPoint, originals: [(PDFAnnotation, CGRect)], offset: CGPoint)?
    private var selectionWindow: (page: PDFPage, start: CGPoint, end: CGPoint, additive: Bool, original: [PDFAnnotation])?

    func setSelectedItems(_ items: [PDFAnnotation]) {
        var seen = Set<ObjectIdentifier>()
        let valid = items.filter { $0.page?.document === boundDocument && !$0.isReadOnly && !layerIsLocked($0) && $0.shouldDisplay && layerIsVisible($0) && seen.insert(ObjectIdentifier($0)).inserted }
        selected = valid.first
        additionalSelection = Array(valid.dropFirst())
        refresh()
    }

    func selectWindow(on page: PDFPage, from start: CGPoint, to end: CGPoint, extending original: [PDFAnnotation] = []) {
        let region = Self.rect(start, end)
        let crossing = end.x < start.x
        let hits = page.annotations.filter {
            (RectangleMarkupRecord.owns($0) || ImportedMarkupState.selectable($0)) &&
            Self.windowSelects($0, in: region, crossing: crossing)
        }
        setSelectedItems(original + hits)
    }

    private var gesture: Gesture?
    private var pendingLine: (page: PDFPage, start: CGPoint)?
    private var preview: (PDFPage, CGRect)?
    private var polylinePage: PDFPage?
    private var polylinePoints: [CGPoint] = []
    private var penConstraintAnchor: Int?
    private var polylineHover: CGPoint?
    private var previewEndpoints: (CGPoint, CGPoint)?
    private var previewVertices: [CGPoint]?
    private final class DocumentState: NSObject {
        let dirty: Bool; let stamp: PDFMarkupSourceStamp?
        init(dirty: Bool, stamp: PDFMarkupSourceStamp?) { self.dirty = dirty; self.stamp = stamp }
    }
    private let documentStates = NSMapTable<PDFDocument, DocumentState>.weakToStrongObjects()
    private let importedStates = NSMapTable<PDFDocument, ImportedMarkupState>.weakToStrongObjects()
    var importedState: ImportedMarkupState? { boundDocument.flatMap { importedStates.object(forKey: $0) } }
    var openingMarkupSourceStamp: PDFMarkupSourceStamp? {
        guard let document = boundDocument else { return nil }
        return readerSnapshots.object(forKey: document)?.stamp ?? importedState?.openingStamp ?? sourceStamp
    }
    func importedPlan() -> ImportedMarkupPlan? {
        guard let document = boundDocument else { return nil }
        return importedState?.plan(document: document, stamp: readerSnapshots.object(forKey: document)?.stamp ?? sourceStamp)
    }
    private let readerSnapshots = NSMapTable<PDFDocument, DocumentState>.weakToStrongObjects()
    func retainReaderSnapshot(_ stamp: PDFMarkupSourceStamp, for document: PDFDocument) {
        // PDFKit may lazily load a page long after the next save replaced the
        // source. Keep its immutable backing file for the document's lifetime.
        if readerSnapshots.object(forKey: document) == nil {
            readerSnapshots.setObject(DocumentState(dirty: false, stamp: stamp), forKey: document)
        }
    }
    private(set) var hasUnsavedChanges = false
    private(set) var sourceStamp: PDFMarkupSourceStamp?
    func rememberSource(_ url: URL?) {
        guard !hasUnsavedChanges || sourceStamp == nil else { return }
        sourceStamp = url.flatMap(PDFMarkupSourceStamp.capture)
    }
    var onMutation: ((PDFPage) -> Void)?
    var onDraftChanged: (() -> Void)?
    var onDraftBegan: (() -> Void)?
    var onDraftEnded: (() -> Void)?
    var onPresentationChanged: (() -> Void)?
    var onClickAway: (() -> Void)?
    var onMeasurementNeedsScale: (() -> Void)?
    var onCalibrationCompleted: ((PDFPage, CGPoint, CGPoint) -> Void)?
    var onSnapshotError: ((Error) -> Void)?
    var onSnapshotCaptureChanged: (() -> Void)?
    private(set) var isCapturingSnapshot = false
    private var snapshotCaptureID: UUID?
    var onInvalidMeasurement: (() -> Void)?
    var canEdit: () -> Bool = { true }
    var tool: Tool = .select {
        didSet {
            finishTextEditing(); cancelGesture()
            if oldValue != tool {
                if let original = appearanceBeforeSavedTool, SavedMarkupAppearance.load(oldValue, from: defaultPreferences) != nil { applyDefaults(original) }
                appearanceBeforeSavedTool = nil
                if tool != .select && tool != .calibrate { appearanceBeforeSavedTool = currentAppearance }
                if let saved = SavedMarkupAppearance.load(tool, from: defaultPreferences), tool != .select {
                    applyDefaults(saved)
                }
            }
            if tool != .select { selected = nil; onClickAway?() }; refresh(); (view as? MarkupPDFView)?.markupToolCursorChanged() }
    }
    private var inlineText: (page:PDFPage, bounds:CGRect, annotation:PDFAnnotation?, editor:MarkupInlineTextView, wasDirty:Bool)?
    var isEditingText: Bool { inlineText != nil }
    var fontSize: CGFloat = 18
    var fillColor: NSColor? = .orange
    var hatchStyle: DraftingHatch? = nil
    var linePattern: MarkupLinePattern = .solid
    var strokeOpacity: Double = 1
    var strokeColor: NSColor = .red
    var lineWidth: CGFloat = 2
    private let overlay = CAShapeLayer()

    static func shortcutTool(for event: NSEvent) -> Tool? {
        let modifiers = event.modifierFlags.intersection([.shift,.command,.option,.control])
        switch (event.charactersIgnoringModifiers?.lowercased(),modifiers) {
        case ("g", []): return .snapshotBox
        case ("g", [.shift]): return .snapshotBox
        case ("v", []): return .select
        case ("p", []): return .pen
        case ("a", []): return .arrow
        case ("t", []): return .text
        case ("e", []): return .ellipse
        case ("r", []): return .rectangle
        case ("l", []): return .line
        case ("n", [.shift]): return .polyline
        case ("p", [.shift]): return .polygon
        case ("a", [.shift]): return .area
        case ("l", [.shift]): return .perimeter
        default: return nil
        }
    }
    func handleToolShortcut(_ event: NSEvent) -> Bool {
        guard canEdit(), let tool = Self.shortcutTool(for:event) else { return false }
        self.tool = tool
        return true
    }

    private let preparedDocuments = NSHashTable<PDFDocument>.weakObjects()

    /// Restore owned annotations before PDFView creates layers for imported AP
    /// streams. Otherwise PDFKit can retain the expensive original Stamp layer
    /// even after replacing the annotation with its bounded editing preview.
    func prepareForDisplay(_ document: PDFDocument?) {
        guard let document, !preparedDocuments.contains(document) else { return }
        preparedDocuments.add(document)
        if importedStates.object(forKey: document) == nil { importedStates.setObject(ImportedMarkupState(document: document), forKey: document) }
        do {
            for index in 0..<document.pageCount {
                guard let page = document.page(at:index) else { continue }
                var replacedAppearance = false
                let originalOrder = page.annotations
                var replacements: [ObjectIdentifier: PDFAnnotation] = [:]
                for original in originalOrder where RectangleMarkupRecord.owns(original) {
                    if MarkupLayers.isMetadata(original) || MeasurementMetadata.isPageScaleMetadata(original) { continue }
                    if original.type == "Stamp", !(original is DrawbridgeSnapshotAnnotation), let payload = SnapshotPayload.read(original),
                       let replacement = try? SnapshotStampFactory.make(payload: payload, bounds: original.bounds, rotation: page.rotation, style: SnapshotStyle.read(original)) {
                        for key in [SnapshotPayload.key, SnapshotStyle.key, RectangleMarkupRecord.identityKey, MarkupLayers.membershipKey] {
                            if let value = original.value(forAnnotationKey: key) { replacement.setValue(value, forAnnotationKey: key) }
                        }
                        replacement.userName = original.userName
                        replacement.contents = original.contents
                        replacement.shouldDisplay = original.shouldDisplay
                        replacement.shouldPrint = original.shouldPrint
                        replacement.isReadOnly = original.isReadOnly
                        // Retire the imported AP before removal; PDFKit otherwise
                        // keeps its opaque image underneath later replacements.
                        original.shouldDisplay = false
                        page.removeAnnotation(original)
                        page.addAnnotation(replacement)
                        replacements[ObjectIdentifier(original)] = replacement
                        replacedAppearance = true
                        continue
                    }
                    if original.type == "FreeText" {
                        let size = RectangleMarkupRecord.textFontSize(original)
                        if size != original.font?.pointSize { RectangleMarkupRecord.setTextFontSize(size, on: original) }
                        continue
                    }
                    let measuredPath = original.type == "Ink" && MeasurementMetadata.measurement(original) != nil
                    let closedShape = ["Square", "Circle"].contains(original.type ?? "")
                    guard (closedShape && !(original is DrawbridgeShapeAnnotation)) || (original.type == "Polygon" && !(original is DrawbridgePolygonAnnotation)) || (measuredPath && !(original is DrawbridgeMeasuredPathAnnotation)) else { continue }
                    let polygon: PDFAnnotation = closedShape ? DrawbridgeShapeAnnotation(bounds: original.bounds, forType: original.type == "Circle" ? .circle : .square, withProperties: nil) : measuredPath ? DrawbridgeMeasuredPathAnnotation(bounds: original.bounds, forType: .ink, withProperties: nil) : DrawbridgePolygonAnnotation(bounds:original.bounds,forType:PDFAnnotationSubtype(rawValue:"/Polygon"),withProperties:nil)
                    if let measurement = MeasurementMetadata.measurement(original) { polygon.setValue(MeasurementMetadata.json(measurement), forAnnotationKey: MeasurementMetadata.measurementKey) }
                    polygon.setValue(original.userName ?? "",forAnnotationKey:PDFAnnotationKey(rawValue:"/T")); polygon.setValue(RectangleMarkupRecord.identity(original) ?? "", forAnnotationKey: RectangleMarkupRecord.identityKey); polygon.contents = original.contents; polygon.color = original.color; polygon.border = original.border
                    MarkupStyle.apply(pattern: MarkupStyle.pattern(original), opacity: MarkupStyle.strokeOpacity(original), to: polygon)
                    if let id = MarkupLayers.id(original) { polygon.setValue(id, forAnnotationKey: MarkupLayers.membershipKey) }
                    polygon.shouldDisplay = original.shouldDisplay; polygon.shouldPrint = original.shouldPrint; polygon.isReadOnly = original.isReadOnly
                    RectangleMarkupRecord.setVertices(RectangleMarkupRecord.vertices(original),on:polygon)
                    if measuredPath { MeasurementMetadata.updateLabel(polygon) }
                    RectangleMarkupRecord.setPolygonFill(RectangleMarkupRecord.polygonFill(original),on:polygon)
                    original.shouldDisplay = false
                    page.removeAnnotation(original); page.addAnnotation(polygon)
                    replacements[ObjectIdentifier(original)] = polygon
                    replacedAppearance = true
                }
                if replacedAppearance {
                    page.annotations.forEach(page.removeAnnotation)
                    originalOrder.map { replacements[ObjectIdentifier($0)] ?? $0 }.forEach(page.addAnnotation)
                }
                if replacedAppearance && view?.document === document { (view as? MarkupPDFView)?.refreshAnnotationRendering(on: page, importedAppearanceChanged: true) }
            }
        }
    }

    func bind(to document: PDFDocument?) {
        guard boundDocument !== document else { return }
        cancelSnapshotCapture()
        finishTextEditing()
        if let previous = boundDocument {
            documentStates.setObject(DocumentState(dirty: hasUnsavedChanges, stamp: sourceStamp), forKey: previous)
        }
        cancelGesture()
        undo.removeAllActions(withTarget: self)
        fallbackUndo.removeAllActions()
        boundDocument = document
        if let document, importedStates.object(forKey: document) == nil { importedStates.setObject(ImportedMarkupState(document: document), forKey: document) }
        prepareForDisplay(document)
        selected = nil; hasUnsavedChanges = false; tool = .select
        sourceStamp = document?.documentURL.flatMap(PDFMarkupSourceStamp.capture)
        if let document, let state = documentStates.object(forKey: document) {
            hasUnsavedChanges = state.dirty; sourceStamp = state.stamp
        }
        applyLayerVisibility()
        refresh()
    }

    func install(on view: PDFView) {
        self.view = view
        view.wantsLayer = true
        overlay.strokeColor = NSColor.systemBlue.cgColor
        overlay.fillColor = NSColor.clear.cgColor
        overlay.lineWidth = 2
        overlay.name = "drawbridge.activeMarkupSelection"
        overlay.zPosition = 2000
        view.layer?.addSublayer(overlay)
    }

    func markSaved(at url: URL, stamp: PDFMarkupSourceStamp? = nil) {
        hasUnsavedChanges = false
        if let stamp { sourceStamp = stamp } else { rememberSource(url) }
    }
    /// A save can finish after another markup was added. Advance the known file
    /// version without marking those newer edits clean.
    func acceptPersistedSource(at url: URL, stamp: PDFMarkupSourceStamp? = nil) { sourceStamp = stamp ?? PDFMarkupSourceStamp.capture(url) }

    func pointerDown(at location: CGPoint, clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard !isCapturingSnapshot else { return true }
        finishTextEditing()
        guard let view else { return false }
        guard let page = view.page(for: location, nearest: false) else {
            if tool == .select { deselectForClickAway() }
            return false
        }
        guard canEdit() else {
            if tool == .select { deselectForClickAway() }
            return false
        }
        bind(to: view.document)
        let point = view.convert(location, to: page)
        if tool == .pen {
            selected = nil
            view.setCurrentSelection(nil, animate: false)
            polylinePage = page
            polylinePoints = [Self.clamped(point, to: page.bounds(for: view.displayBox))]
            polylineHover = nil
            refresh(presentationChanged: false)
            return true
        }
        if tool == .line || tool == .arrow || tool == .calibrate {
            view.setCurrentSelection(nil, animate: false)
            let candidate = modifiers.contains(.shift) && pendingLine != nil ? MeasurementGeometry.constrained(point, from: pendingLine!.start) : point
            let endpoint = Self.clamped(candidate, to: page.bounds(for: view.displayBox))
            if let draft = pendingLine {
                guard draft.page === page else { return true }
                guard hypot(draft.start.x-endpoint.x, draft.start.y-endpoint.y) >= 2 else { return true }
                if tool == .calibrate {
                    tool = .select
                    onCalibrationCompleted?(page, draft.start, endpoint)
                    return true
                }
                let kind: RectangleMarkupRecord.Kind = tool == .arrow ? .arrow : .line
                if create(on: page, bounds: Self.lineBounds(draft.start, endpoint, width: lineWidth), kind: kind, endpoints: (draft.start, endpoint)) != nil {
                    tool = .select
                }
            } else {
                pendingLine = (page, endpoint)
                previewEndpoints = (endpoint, endpoint)
                preview = (page, Self.lineBounds(endpoint, endpoint, width: lineWidth))
            }
            refresh(); return true
        }
        if tool == .polyline || tool == .polygon || tool == .area || tool == .perimeter || tool == .snapshotPolygon || (tool == .snapshotBox && polylinePage != nil) {
            guard polylinePage == nil || polylinePage === page else { return true }
            view.setCurrentSelection(nil, animate:false)
            if tool == .area || tool == .perimeter || tool == .snapshotPolygon || tool == .snapshotBox {
                if tool != .snapshotPolygon && tool != .snapshotBox { guard MeasurementMetadata.scale(on: page) != nil, MeasurementMetadata.supportedPage(page) else { onMeasurementNeedsScale?(); return true } }
                if (tool != .perimeter || modifiers.contains(.control)), polylinePoints.count >= 3, let first = polylinePoints.first, hypot(first.x-point.x, first.y-point.y) <= 8 / max(view.scaleFactor, 0.01) {
                    _ = finishPolyline(closed: true); return true
                }
                guard polylinePoints.count < 512 else { onInvalidMeasurement?(); return true }
            }
            polylinePage = page
            let candidate = modifiers.contains(.shift) && !polylinePoints.isEmpty ? MeasurementGeometry.constrained(point, from: polylinePoints.last!) : point
            let p = Self.clamped(candidate,to:page.bounds(for:view.displayBox))
            if let last = polylinePoints.last, hypot(last.x-p.x,last.y-p.y) < 0.5 {
                // A duplicate endpoint is not a new segment or a completion click.
                if tool == .perimeter { return true }
            } else { polylinePoints.append(p) }
            polylineHover = p
            if tool == .perimeter, polylinePoints.count >= 2, !modifiers.contains(.control) {
                // Shift only constrains geometry. Control explicitly keeps the
                // dimension string open; release it for the final endpoint click.
                _ = finishPolyline(closed: false)
            } else if clickCount >= 2 { finishPolyline() } else { refresh() }
            return true
        }
        if clickCount >= 2, let hit = page.annotations.reversed().first(where:{ RectangleMarkupRecord.owns($0) && $0.type == "FreeText" && !$0.isReadOnly && !layerIsLocked($0) && $0.bounds.contains(point) }) {
            selected = hit; beginTextEditing(on:page,bounds:hit.bounds,annotation:hit); return true
        }
        if tool != .select {
            selected = nil; onClickAway?()
            view.setCurrentSelection(nil, animate: false)
            gesture = .create(page, point); preview = (page, CGRect(origin: point, size: .zero)); refresh()
            return true
        }
        if modifiers.contains(.shift) {
            if let hit = page.annotations.reversed().first(where: { (RectangleMarkupRecord.owns($0) || ImportedMarkupState.selectable($0)) && !$0.isReadOnly && !layerIsLocked($0) && layerIsVisible($0) && $0.shouldDisplay && Self.hitTest($0, at: point, tolerance: 8 / max(view.scaleFactor, 0.01)) }) {
                let items = selectedItems
                setSelectedItems(items.contains(where: { $0 === hit }) ? items.filter { $0 !== hit } : items + [hit])
                return true
            }
        }
        if selectedItems.count > 1, selectedItems.contains(where: { $0.page === page && Self.hitTest($0, at: point, tolerance: 8 / max(view.scaleFactor, 0.01)) }) {
            groupMove = (page, point, selectedItems.filter { $0.page === page }.map { ($0, $0.bounds) }, .zero)
            return true
        }
        if let selected, selected.page === page, RectangleMarkupRecord.owns(selected), !selected.isReadOnly, !layerIsLocked(selected) {
            let vertices = RectangleMarkupRecord.vertices(selected)
            if let index = vertices.indices.first(where: { i in
                let p = view.convert(vertices[i],from:page)
                return hypot(location.x-p.x,location.y-p.y) <= 8
            }) {
                gesture = .vertex(page,selected,index); previewVertices = vertices
                preview = (page,selected.bounds); refresh(); return true
            }
            let corners: [Corner] = !vertices.isEmpty || selected.type == "Stamp" ? [] : selected.type == "Line" ? [.lowerLeft, .upperRight] : Corner.allCases
            let corner = corners.first { corner in
                let p = view.convert(handlePoint(corner, annotation: selected), from: page)
                return hypot(location.x - p.x, location.y - p.y) <= 8
            }
            if corner != nil || Self.hitTest(selected,at:point,tolerance:8 / max(view.scaleFactor,0.01)) {
                gesture = .edit(page, selected, selected.bounds, point, corner)
                preview = (page, selected.bounds); refresh(); return true
            }
        }
        if let hit = page.annotations.reversed().first(where: { (RectangleMarkupRecord.owns($0) || ImportedMarkupState.selectable($0)) && !$0.isReadOnly && !layerIsLocked($0) && $0.shouldDisplay && Self.hitTest($0,at:point,tolerance:8 / max(view.scaleFactor,0.01)) }) {
            selected = hit; view.setCurrentSelection(nil, animate: false)
            gesture = .edit(page, hit, hit.bounds, point, nil); preview = (page, hit.bounds); refresh(); return true
        }
        if page.annotations.contains(where: { $0.type == "Link" && $0.bounds.contains(point) && $0.shouldDisplay }) { deselectForClickAway(); return false }
        guard view is MarkupPDFView else { deselectForClickAway(); return false }
        let original = modifiers.contains(.shift) ? selectedItems : []
        deselectForClickAway()
        setSelectedItems(original)
        selectionWindow = (page, location, location, modifiers.contains(.shift), original)
        view.setCurrentSelection(nil, animate: false)
        return true
    }

    private func deselectForClickAway() {
        cancelGesture()
        selected = nil
        refresh()
        onClickAway?()
    }

    func pointerMoved(at location: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        if let draft = pendingLine, let view {
            guard view.page(for: location, nearest: false) === draft.page else { return }
            let point = view.convert(location, to: draft.page)
            let end = Self.clamped(modifiers.contains(.shift) ? MeasurementGeometry.constrained(point, from: draft.start) : point, to: draft.page.bounds(for: view.displayBox))
            previewEndpoints = (draft.start, end)
            preview = (draft.page, Self.lineBounds(draft.start, end, width: lineWidth))
            refresh(presentationChanged: false); return
        }
        guard let view, let page = polylinePage else { return }
        guard view.page(for: location, nearest: false) === page else { return }
        let point = view.convert(location,to:page)
        polylineHover = Self.clamped(modifiers.contains(.shift) && !polylinePoints.isEmpty ? MeasurementGeometry.constrained(point, from: polylinePoints.last!) : point,to:page.bounds(for:view.displayBox)); refresh(presentationChanged: false)
    }
    @discardableResult
    func finishPolyline(closed: Bool? = nil) -> Bool {
        guard let page = polylinePage else { return false }
        let points = polylinePoints
        let isClosed = closed ?? (tool == .polygon || tool == .area)
        if tool == .snapshotPolygon || tool == .snapshotBox {
            guard points.count >= 3 else { return false }
            captureSnapshot(page: page, points: points)
        } else if tool == .area || tool == .perimeter {
            guard let scale = MeasurementMetadata.scale(on: page),
                  createMeasurement(on: page, points: points, kind: tool == .area ? .area : .perimeter, closed: isClosed, scale: scale) != nil else { onInvalidMeasurement?(); return false }
        } else { _ = createPolyline(on: page, points: points, closed: isClosed) }
        polylinePage = nil; polylinePoints = []; polylineHover = nil
        refresh(); return true
    }
    @discardableResult
    func createPolyline(on page: PDFPage, points: [CGPoint], closed: Bool = false) -> PDFAnnotation? {
        guard points.count >= (closed ? 3 : 2), points.count <= 10000, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              zip(points,points.dropFirst()).contains(where: { hypot($0.0.x-$0.1.x,$0.0.y-$0.1.y) >= 2 }) else { return nil }
        let bounds = Self.polylineBounds(points,width:lineWidth)
        return create(on:page,bounds:bounds,kind:closed ? .polygon : .polyline,vertices:points)
    }
    @discardableResult
    func createMeasurement(on page: PDFPage, points: [CGPoint], kind: DrawingMeasurement.Kind, closed: Bool, scale: DrawingScale) -> PDFAnnotation? {
        let measurement = DrawingMeasurement(kind: kind, scale: scale, closed: closed)
        guard measurement.valid(points: points), MeasurementMetadata.supportedPage(page) else { return nil }
        let padding: CGFloat = closed ? 8 : 24
        let bounds = Self.polylineBounds(points, width: lineWidth).insetBy(dx: -padding, dy: -padding)
        return create(on: page, bounds: bounds, kind: closed ? .polygon : .polyline, vertices: points, measurement: measurement)
    }
    /// Scale markers travel with each PDF page; settings survive save, deletion,
    /// page reordering and reopening without an external sidecar file.
    func applyDrawingScale(_ scale: DrawingScale?, to pages: [PDFPage]) {
        guard canEdit(), scale == nil || scale!.isValid, !pages.isEmpty,
              Set(pages.map(ObjectIdentifier.init)).count == pages.count,
              pages.allSatisfy({ $0.document === boundDocument && MeasurementMetadata.supportedPage($0) }) else { return }
        let changedPages = pages.filter { page in
            if MeasurementMetadata.scale(on: page) != scale { return true }
            guard let scale else { return false }
            return page.annotations.compactMap(MeasurementMetadata.measurement).contains { $0.scale != scale }
        }
        guard !changedPages.isEmpty else { return }
        restoreDrawingScales(changedPages.map { ($0, scale) })
    }
    private func restoreDrawingScales(_ updates: [(PDFPage, DrawingScale?)], measurements: [(PDFAnnotation, DrawingMeasurement)]? = nil) {
        guard canEdit(), updates.allSatisfy({ $0.0.document === boundDocument }) else { return }
        let previous = updates.map { ($0.0, MeasurementMetadata.scale(on: $0.0)) }
        let previousMeasurements = updates.flatMap { page, _ in page.annotations.compactMap { a -> (PDFAnnotation, DrawingMeasurement)? in MeasurementMetadata.measurement(a).map { (a,$0) } } }
        undo.registerUndo(withTarget: self) { target in
            target.restoreDrawingScales(previous, measurements: previousMeasurements)
        }
        undo.setActionName("Set Page Scales")
        for (page, scale) in updates {
            for carrier in page.annotations where MeasurementMetadata.isPageScaleMetadata(carrier) { page.removeAnnotation(carrier) }
            do {
                let origin = page.bounds(for: .mediaBox).origin
                let marker = PDFAnnotation(bounds: CGRect(origin: origin, size: CGSize(width: 2,height: 2)), forType: .square, withProperties: nil)
                marker.setValue(RectangleMarkupRecord.prefix + UUID().uuidString, forAnnotationKey: RectangleMarkupRecord.identityKey)
                if let scale { marker.setValue(MeasurementMetadata.json(scale), forAnnotationKey: MeasurementMetadata.pageScaleKey) }
                else { marker.setValue(true, forAnnotationKey: MeasurementMetadata.clearedScaleKey) }
                marker.setValue(true, forAnnotationKey: MeasurementMetadata.pendingScaleKey)
                marker.color = .clear; marker.shouldDisplay = false; marker.shouldPrint = false; marker.isReadOnly = true
                page.addAnnotation(marker)
                for annotation in page.annotations {
                    if let scale, var measurement = MeasurementMetadata.measurement(annotation) {
                        measurement.scale = scale
                        annotation.setValue(MeasurementMetadata.json(measurement), forAnnotationKey: MeasurementMetadata.measurementKey)
                        MeasurementMetadata.updateLabel(annotation)
                    }
                }
            }
        }
        // Restore heterogeneous per-measurement scales before publishing any page.
        // Capturing inverse state above keeps repeated undo/redo cycles exact.
        for (annotation, measurement) in measurements ?? [] {
            annotation.setValue(MeasurementMetadata.json(measurement), forAnnotationKey: MeasurementMetadata.measurementKey)
            MeasurementMetadata.updateLabel(annotation)
        }
        for (page, _) in updates { changed(page) }
    }
    static func polylineBounds(_ points: [CGPoint], width: CGFloat) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x:xs.min() ?? 0,y:ys.min() ?? 0,width:(xs.max() ?? 0)-(xs.min() ?? 0),height:(ys.max() ?? 0)-(ys.min() ?? 0)).insetBy(dx:-max(6,width*4),dy:-max(6,width*4))
    }

    @discardableResult
    func pointerDragged(at location: CGPoint, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        if var move = groupMove, let view {
            var end = view.convert(location, to: move.page)
            if modifiers.contains(.shift) { end = MeasurementGeometry.constrained(end, from: move.start) }
            let union = move.originals.reduce(CGRect.null) { $0.union($1.1) }
            let crop = move.page.bounds(for: view.displayBox)
            move.offset = CGPoint(x: min(max(end.x-move.start.x, crop.minX-union.minX), crop.maxX-union.maxX), y: min(max(end.y-move.start.y, crop.minY-union.minY), crop.maxY-union.maxY))
            groupMove = move; refresh(presentationChanged: false); return true
        }
        if var window = selectionWindow {
            window.end = location; selectionWindow = window
            refresh(presentationChanged: false); return true
        }
        if tool == .pen, let view, let page = polylinePage {
            var point = view.convert(location, to: page)
            if modifiers.contains(.shift), !polylinePoints.isEmpty {
                let index = penConstraintAnchor ?? (polylinePoints.count-1)
                penConstraintAnchor = index
                point = MeasurementGeometry.constrained(point, from: polylinePoints[index])
                polylinePoints.removeSubrange((index+1)..<polylinePoints.count)
            } else { penConstraintAnchor = nil }
            point = Self.clamped(point, to: page.bounds(for: view.displayBox))
            if let last = polylinePoints.last, hypot(last.x-point.x, last.y-point.y) >= 0.25 / max(view.scaleFactor, 0.01), polylinePoints.count < 10000 {
                polylinePoints.append(point)
            }
            refresh(presentationChanged: false)
            return true
        }
        if pendingLine != nil { pointerMoved(at: location, modifiers: modifiers); return true }
        guard let view, let gesture else { return false }
        switch gesture {
        case .vertex(let page, let annotation, let index):
            var points = RectangleMarkupRecord.vertices(annotation)
            guard points.indices.contains(index) else { return false }
            let candidate = view.convert(location,to:page)
            let anchor = points[index == 0 ? 1 : index-1]
            points[index] = Self.clamped(modifiers.contains(.shift) ? MeasurementGeometry.constrained(candidate, from: anchor) : candidate,to:page.bounds(for:view.displayBox))
            previewVertices = points
            preview = (page,Self.polylineBounds(points,width:annotation.border?.lineWidth ?? 2))
        case .create(let page, let start):
            var end = Self.clamped(view.convert(location, to: page), to: page.bounds(for: view.displayBox))
            if modifiers.contains(.shift) {
                if tool == .rectangle || tool == .ellipse {
                    let crop = page.bounds(for: view.displayBox)
                    let dx = end.x-start.x, dy = end.y-start.y
                    let roomX = dx >= 0 ? crop.maxX-start.x : start.x-crop.minX
                    let roomY = dy >= 0 ? crop.maxY-start.y : start.y-crop.minY
                    let side = min(max(abs(dx),abs(dy)), roomX, roomY)
                    end = CGPoint(x: start.x + (dx >= 0 ? side : -side), y: start.y + (dy >= 0 ? side : -side))
                } else if tool == .line || tool == .arrow { end = MeasurementGeometry.constrained(end, from: start) }
            }
            if tool == .line || tool == .arrow {
                previewEndpoints = (start,end); preview = (page, Self.lineBounds(start,end,width:lineWidth))
            } else { preview = (page, Self.rect(start, end)) }
        case .edit(let page, let annotation, let original, let start, let corner):
            var end = view.convert(location, to: page)
            if modifiers.contains(.shift), corner == nil { end = MeasurementGeometry.constrained(end, from: start) }
            let crop = page.bounds(for: view.displayBox)
            if annotation.type == "Line" && RectangleMarkupRecord.owns(annotation) {
                var a = handlePoint(.lowerLeft, annotation: annotation), b = handlePoint(.upperRight, annotation: annotation)
                if let corner {
                    if corner == .lowerLeft { a = Self.clamped(modifiers.contains(.shift) ? MeasurementGeometry.constrained(end, from: b) : end,to:crop) } else { b = Self.clamped(modifiers.contains(.shift) ? MeasurementGeometry.constrained(end, from: a) : end,to:crop) }
                } else {
                    let dx = min(max(end.x-start.x,crop.minX-original.minX),crop.maxX-original.maxX)
                    let dy = min(max(end.y-start.y,crop.minY-original.minY),crop.maxY-original.maxY)
                    a.x += dx; a.y += dy; b.x += dx; b.y += dy
                }
                previewEndpoints = (a,b); preview = (page,Self.lineBounds(a,b,width:annotation.border?.lineWidth ?? 2))
            } else if let corner {
                let opposite: Corner
                switch corner {
                case .lowerLeft: opposite = .upperRight
                case .lowerRight: opposite = .upperLeft
                case .upperLeft: opposite = .lowerRight
                case .upperRight: opposite = .lowerLeft
                }
                preview = (page, Self.rect(Self.cornerPoint(opposite, in: original), Self.clamped(end, to: crop)))
            } else {
                let dx = min(max(end.x - start.x, crop.minX - original.minX), crop.maxX - original.maxX)
                let dy = min(max(end.y - start.y, crop.minY - original.minY), crop.maxY - original.maxY)
                preview = (page, original.offsetBy(dx: dx, dy: dy))
            }
        }
        refresh(presentationChanged: false); return true
    }

    func pointerUp(at location: CGPoint, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        if let move = groupMove {
            _ = pointerDragged(at: location, modifiers: modifiers)
            let offset = groupMove?.offset ?? .zero
            groupMove = nil
            undo.beginUndoGrouping()
            for (annotation, original) in move.originals { setGeometry(original.offsetBy(dx: offset.x, dy: offset.y), endpoints: nil, of: annotation, on: move.page, action: "Move Markups") }
            undo.endUndoGrouping()
            setSelectedItems(move.originals.map { $0.0 }); return true
        }
        if let window = selectionWindow, let view {
            selectionWindow = nil
            if hypot(location.x-window.start.x, location.y-window.start.y) >= 3 {
                let a = view.convert(window.start, to: window.page), b = view.convert(location, to: window.page)
                // Direction is measured in screen space even on rotated pages.
                let region = Self.rect(a, b)
                let crossing = location.x < window.start.x
                let hits = window.page.annotations.filter { (RectangleMarkupRecord.owns($0) || ImportedMarkupState.selectable($0)) && Self.windowSelects($0, in: region, crossing: crossing) }
                setSelectedItems(window.original + hits)
            } else { setSelectedItems(window.original) }
            refresh(); return true
        }
        if tool == .pen, let page = polylinePage {
            _ = pointerDragged(at: location, modifiers: modifiers)
            let points = polylinePoints
            polylinePage = nil; polylinePoints = []; polylineHover = nil; penConstraintAnchor = nil
            _ = createPolyline(on: page, points: points)
            selected = nil
            refresh()
            return true
        }
        if pendingLine != nil { return true }
        if tool == .polyline || tool == .polygon || tool == .area || tool == .perimeter || tool == .snapshotPolygon || (tool == .snapshotBox && polylinePage != nil) { return true }
        guard let gesture else { return false }
        _ = pointerDragged(at: location, modifiers: modifiers)
        let candidate = preview?.1
        let endpoints = previewEndpoints
        let vertices = previewVertices
        self.gesture = nil; preview = nil; previewEndpoints = nil; previewVertices = nil
        if tool == .snapshotBox, case .create(let page, let start) = gesture,
           let candidate, max(candidate.width, candidate.height) * (view?.scaleFactor ?? 1) < 4 {
            selected = nil
            polylinePage = page; polylinePoints = [start]; polylineHover = start
            refresh(); return true
        }
        guard canEdit(), let candidate, candidate.width >= 2, candidate.height >= 2 else { refresh(); return true }
        switch gesture {
        case .vertex(let page, let annotation, _):
            if let vertices { setVertexPositions(vertices,of:annotation,on:page) }
        case .create(let page, _):
            if tool == .snapshotBox {
                captureSnapshot(page: page, points: [CGPoint(x:candidate.minX,y:candidate.minY),CGPoint(x:candidate.maxX,y:candidate.minY),CGPoint(x:candidate.maxX,y:candidate.maxY),CGPoint(x:candidate.minX,y:candidate.maxY)])
                refresh(); return true
            }
            let kind: RectangleMarkupRecord.Kind
            switch tool { case .ellipse: kind = .ellipse; case .line: kind = .line; case .arrow: kind = .arrow; case .text: kind = .text; default: kind = .rectangle }
            if let endpoints, hypot(endpoints.0.x-endpoints.1.x,endpoints.0.y-endpoints.1.y) < 2 { return true }
            if kind == .text {
                beginTextEditing(on:page,bounds:candidate)
            } else { _ = create(on: page, bounds: candidate, kind: kind, endpoints: endpoints) }
        case .edit(let page, let annotation, let original, _, let corner):
            if candidate != original || endpoints != nil { setGeometry(candidate, endpoints: endpoints, of: annotation, on: page, action: corner == nil ? "Move Markup" : "Resize Markup") }
        }
        refresh(); return true
    }

    private func setSnapshotCaptureBusy(_ busy: Bool) {
        isCapturingSnapshot = busy
        (view as? MarkupPDFView)?.setSnapshotCaptureBusy(busy)
        onSnapshotCaptureChanged?()
    }
    func cancelSnapshotCapture() {
        guard isCapturingSnapshot else { return }
        snapshotCaptureID = nil
        setSnapshotCaptureBusy(false)
    }
    private func captureSnapshot(page: PDFPage, points: [CGPoint]) {
        guard !isCapturingSnapshot, canEdit(), page.document === boundDocument else { return }
        let captureID = UUID()
        let style = SavedMarkupAppearance.load(.snapshotBox, from: defaultPreferences)?.snapshot ?? SnapshotStyle()
        snapshotCaptureID = captureID
        setSnapshotCaptureBusy(true)
        // Give AppKit a frame to show the indicator before PDFKit renders. Keep
        // the live document and its annotations on the main thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.snapshotCaptureID == captureID else { return }
            guard page.document === self.boundDocument else { self.cancelSnapshotCapture(); return }
            do {
                var payload = try SnapshotPayload.capture(page: page, points: points)
                payload.style = style
                payload.copy()
                self.snapshotCaptureID = nil
                self.setSnapshotCaptureBusy(false)
                self.tool = .select
            } catch {
                self.snapshotCaptureID = nil
                self.setSnapshotCaptureBusy(false)
                self.onSnapshotError?(error)
            }
        }
    }
    @discardableResult
    func pasteSnapshot(_ payload: SnapshotPayload, on page: PDFPage, center: CGPoint, inPlace: Bool = false) -> PDFAnnotation? {
        guard !isCapturingSnapshot, canEdit(), !activeLayerIsLocked, page.document === boundDocument, let size = payload.size else { return nil }
        guard MeasurementMetadata.supportedPage(page) else { onSnapshotError?(SnapshotError.unsupportedPageUnits); return nil }
        let rotated = page.rotation % 180 != 0
        let paperSize = rotated ? CGSize(width:size.height,height:size.width) : size
        let crop = page.bounds(for: view?.displayBox ?? .cropBox)
        let minX = paperSize.width <= crop.width ? min(max(center.x-paperSize.width/2,crop.minX),crop.maxX-paperSize.width) : crop.midX-paperSize.width/2
        let minY = paperSize.height <= crop.height ? min(max(center.y-paperSize.height/2,crop.minY),crop.maxY-paperSize.height) : crop.midY-paperSize.height/2
        var rect = CGRect(x:minX,y:minY,width:paperSize.width,height:paperSize.height)
        if inPlace, let placement = payload.placement,
           [placement.x, placement.y, placement.width, placement.height].allSatisfy({ $0.isFinite && abs($0) < 1e7 }), placement.width > 0, placement.height > 0 {
            let c = CGPoint(x: placement.x + placement.width/2, y: placement.y + placement.height/2)
            rect = CGRect(x: c.x-paperSize.width/2, y: c.y-paperSize.height/2, width: paperSize.width, height: paperSize.height)
        }
        let annotation: PDFAnnotation
        do { annotation = try SnapshotStampFactory.make(payload: payload, bounds: rect, rotation: page.rotation, style: payload.style) }
        catch { onSnapshotError?(error); return nil }
        annotation.setValue(payload.style.json, forAnnotationKey: SnapshotStyle.key)
        annotation.setValue(payload.data.base64EncodedString(), forAnnotationKey: SnapshotPayload.key)
        annotation.setValue(RectangleMarkupRecord.prefix + UUID().uuidString, forAnnotationKey: RectangleMarkupRecord.identityKey)
        annotation.userName = MarkupAuthorPreference.currentName; annotation.contents = "Snapshot"
        annotation.shouldDisplay = true; annotation.shouldPrint = true
        assignNewMarkupLayer(annotation)
        tool = .select
        setPresence(true, annotation: annotation, page: page, action: "Paste Snapshot")
        return annotation
    }

    func styleSelectedSnapshot(_ style: SnapshotStyle) {
        guard canEdit(), style.isValid, let old = selected, RectangleMarkupRecord.owns(old), !old.isReadOnly, !layerIsLocked(old),
              let page = old.page, let payload = SnapshotPayload.read(old), SnapshotStyle.read(old) != style else { return }
        do {
            let replacement = try SnapshotStampFactory.make(payload: payload, bounds: old.bounds, rotation: page.rotation, style: style)
            replacement.setValue(payload.data.base64EncodedString(), forAnnotationKey: SnapshotPayload.key)
            replacement.setValue(style.json, forAnnotationKey: SnapshotStyle.key)
            guard let identity = old.value(forAnnotationKey: RectangleMarkupRecord.identityKey) else { return }
            replacement.setValue(identity, forAnnotationKey: RectangleMarkupRecord.identityKey)
            if let id = MarkupLayers.id(old) { replacement.setValue(id, forAnnotationKey: MarkupLayers.membershipKey) }
            replacement.userName = old.userName; replacement.contents = old.contents
            replacement.shouldDisplay = old.shouldDisplay; replacement.shouldPrint = old.shouldPrint
            replaceSnapshot(old, with: replacement, on: page)
        } catch { onSnapshotError?(error) }
    }
    private func replaceSnapshot(_ old: PDFAnnotation, with replacement: PDFAnnotation, on page: PDFPage) {
        guard canEdit(), page.document === boundDocument else { return }
        undo.registerUndo(withTarget: self) { target in target.replaceSnapshot(replacement, with: old, on: page) }
        undo.setActionName("Change Snapshot Appearance")
        // PDFKit may render a removed annotation while retiring its cache.
        (old as? DrawbridgeSnapshotAnnotation)?.isRetired = true
        old.shouldDisplay = false
        page.removeAnnotation(old)
        (replacement as? DrawbridgeSnapshotAnnotation)?.isRetired = false
        replacement.shouldDisplay = true
        page.addAnnotation(replacement); selected = replacement
        applyLayerVisibility()
        changed(page, importedAppearanceChanged: true)
    }

    @discardableResult
    func create(on page: PDFPage, bounds: CGRect, kind: RectangleMarkupRecord.Kind = .rectangle, endpoints: (CGPoint,CGPoint)? = nil, text: String = "", vertices: [CGPoint] = [], measurement: DrawingMeasurement? = nil) -> PDFAnnotation? {
        guard canEdit(), !activeLayerIsLocked, bounds.width >= 2, bounds.height >= 2,
              page.document === boundDocument, [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy({ $0.isFinite }) else { return nil }
        if kind == .text && (text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || text.utf8.count > 100000) { return nil }
        if (kind == .polyline || kind == .polygon) && (vertices.count < (kind == .polygon ? 3 : 2) || vertices.count > 10000 || !vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && bounds.contains($0) })) { return nil }
        if let measurement {
            guard (kind == .polygon || kind == .polyline), measurement.closed == (kind == .polygon),
                  measurement.valid(points: vertices), MeasurementMetadata.supportedPage(page) else { return nil }
        }
        let type: PDFAnnotationSubtype = kind == .polygon ? PDFAnnotationSubtype(rawValue:"/Polygon") : kind == .polyline ? .ink : kind == .text ? .freeText : kind == .ellipse ? .circle : (kind == .line || kind == .arrow ? .line : .square)
        if type == .line {
            guard let (a,b) = endpoints, [a.x,a.y,b.x,b.y].allSatisfy({ $0.isFinite }), bounds.contains(a), bounds.contains(b), hypot(a.x-b.x,a.y-b.y) >= 2 else { return nil }
        }
        let annotation: PDFAnnotation = kind == .polygon ? DrawbridgePolygonAnnotation(bounds:bounds,forType:type,withProperties:nil) : measurement != nil ? DrawbridgeMeasuredPathAnnotation(bounds: bounds, forType: type, withProperties: nil) : (kind == .rectangle || kind == .ellipse) ? DrawbridgeShapeAnnotation(bounds: bounds, forType: type, withProperties: nil) : PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
        if let (a,b) = endpoints {
            annotation.startPoint = CGPoint(x:a.x-bounds.minX,y:a.y-bounds.minY)
            annotation.endPoint = CGPoint(x:b.x-bounds.minX,y:b.y-bounds.minY)
            annotation.endLineStyle = kind == .arrow ? .openArrow : .none
        }
        annotation.setValue(RectangleMarkupRecord.prefix + UUID().uuidString, forAnnotationKey: RectangleMarkupRecord.identityKey)
        annotation.setValue(MarkupAuthorPreference.currentName, forAnnotationKey: PDFAnnotationKey(rawValue: "/T"))
        annotation.contents = kind == .text ? text : kind.rawValue.capitalized
        if kind == .polyline && measurement == nil { annotation.setValue(tool == .pen ? "pen" : "polyline", forAnnotationKey: RectangleMarkupRecord.inkToolKey) }
        if kind == .text { annotation.font = NSFont(name:"Helvetica",size:fontSize); annotation.fontColor = strokeColor; annotation.alignment = .left }
        if kind == .text { RectangleMarkupRecord.setTextColor(strokeColor,on:annotation); RectangleMarkupRecord.setTextFontSize(fontSize,on:annotation) } else { annotation.color = strokeColor }
        let border = PDFBorder(); border.lineWidth = kind == .text ? 0 : lineWidth; annotation.border = border
        MarkupStyle.apply(pattern: linePattern, opacity: strokeOpacity, to: annotation)
        if kind == .polyline || kind == .polygon { RectangleMarkupRecord.setVertices(vertices,on:annotation) }
        if kind == .polygon || kind == .rectangle || kind == .ellipse { RectangleMarkupRecord.setPolygonFill(fillColor,on:annotation) }
        if kind == .polygon || kind == .rectangle || kind == .ellipse { DraftingHatch.apply(hatchStyle, to: annotation) }
        if let measurement { annotation.setValue(MeasurementMetadata.json(measurement), forAnnotationKey: MeasurementMetadata.measurementKey); MeasurementMetadata.updateLabel(annotation) }
        annotation.shouldDisplay = true; annotation.shouldPrint = true
        assignNewMarkupLayer(annotation)
        // Only a successfully validated placement finishes the drawing tool.
        // Pen stays active for repeated strokes; drafts and undo/redo do not enter here.
        if tool != .pen { tool = .select }
        setPresence(true, annotation: annotation, page: page, action: "Add " + kind.rawValue.capitalized)
        return annotation
    }

    func beginTextEditing(on page:PDFPage, bounds:CGRect, annotation:PDFAnnotation? = nil) {
        finishTextEditing()
        guard canEdit(), page.document === boundDocument, let view else { return }
        if let annotation, !RectangleMarkupRecord.owns(annotation) || annotation.type != "FreeText" || annotation.isReadOnly || layerIsLocked(annotation) { return }
        let storage = NSTextStorage(), layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize:CGSize(width:500,height:500)); layout.addTextContainer(container)
        let editor = MarkupInlineTextView(frame:.zero,textContainer:container)
        editor.retainedStorage = storage
        editor.isRichText = false; editor.drawsBackground = false; editor.textContainerInset = .zero
        editor.allowsUndo = true
        editor.textContainer?.lineFragmentPadding = 0; editor.isVerticallyResizable = false; editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true; editor.textContainer?.heightTracksTextView = true
        editor.font = NSFont(name:"Helvetica",size:(annotation?.font?.pointSize ?? fontSize)*view.scaleFactor)
        editor.textColor = annotation.map(RectangleMarkupRecord.markupColor) ?? strokeColor
        editor.insertionPointColor = .controlAccentColor
        editor.string = annotation?.contents ?? ""
        editor.setAccessibilityLabel("Edit text on PDF page")
        editor.wantsLayer = true; editor.layer?.borderColor = NSColor.controlAccentColor.cgColor; editor.layer?.borderWidth = 1
        inlineText = (page,bounds,annotation,editor,hasUnsavedChanges)
        onDraftBegan?()
        annotation?.shouldDisplay = false
        editor.onFinish = { [weak self] cancel in self?.finishTextEditing(cancel:cancel) }
        editor.onChange = { [weak self] in
            guard let self, let draft = self.inlineText else { return }
            self.hasUnsavedChanges = true
            if let onDraftChanged = self.onDraftChanged { onDraftChanged() }
            else { self.onMutation?(draft.page) }
            self.refresh()
        }
        view.addSubview(editor); positionTextEditor(); view.needsDisplay = true
        view.window?.makeFirstResponder(editor); editor.setSelectedRange(NSRange(location:editor.string.utf16.count,length:0))
        refresh()
    }
    private func positionTextEditor() {
        guard let draft = inlineText, let view else { return }
        let rect = view.convert(draft.bounds,from:draft.page).standardized
        let scale = view.scaleFactor
        let editor = draft.editor
        editor.frameCenterRotation = 0
        editor.frame = CGRect(x:rect.midX-draft.bounds.width*scale/2,y:rect.midY-draft.bounds.height*scale/2,width:draft.bounds.width*scale,height:draft.bounds.height*scale)
        editor.frameCenterRotation = CGFloat(-draft.page.rotation)
        editor.font = NSFont(name:"Helvetica",size:(draft.annotation?.font?.pointSize ?? fontSize)*scale)
        editor.textColor = draft.annotation.map(RectangleMarkupRecord.markupColor) ?? strokeColor
    }
    func finishTextEditing(cancel:Bool = false) {
        guard let draft = inlineText else { return }
        inlineText = nil; draft.editor.onFinish = nil; draft.editor.onChange = nil
        let text = draft.editor.string
        let wasFirstResponder = view?.window?.firstResponder === draft.editor
        draft.annotation?.shouldDisplay = true
        draft.editor.removeFromSuperview(); hasUnsavedChanges = draft.wasDirty
        if !cancel && !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && text.utf8.count <= 100000 {
            if let annotation = draft.annotation { selected = annotation; editSelectedText(text,size:annotation.font?.pointSize ?? fontSize) }
            else { _ = create(on:draft.page,bounds:draft.bounds,kind:.text,text:text) }
        }
        if wasFirstResponder { view?.window?.makeFirstResponder(view) }
        view?.needsDisplay = true; refresh()
        onDraftEnded?()
    }

    func selectFromList(_ annotation: PDFAnnotation) {
        finishTextEditing(); cancelGesture(); tool = .select
        guard annotation.page?.document === boundDocument else { return }
        selected = layerIsLocked(annotation) ? nil : annotation; refresh()
    }

    func reorderSelected(toFront: Bool) {
        reorderSelected(toFront ? .bringToFront : .sendToBack)
    }

    func reorderSelected(_ action: MainViewController.AnnotationReorderAction) {
        guard canEdit() else { return }
        let selection = selectedItems
        let items = selection.filter { $0.page?.document === boundDocument && !$0.isReadOnly && !layerIsLocked($0) }
        let movingIDs = Set(items.map(ObjectIdentifier.init))
        var pages: [PDFPage] = []
        for item in items {
            if let page = item.page, !pages.contains(where: { $0 === page }) { pages.append(page) }
        }
        var changes: [(PDFPage, [PDFAnnotation])] = []
        for page in pages {
            let original = page.annotations
            // Screen-only capture tiles are part of their owner's stacking unit.
            var logical = original.filter { !($0 is SnapshotViewportTileAnnotation) }
            let isMoving: (PDFAnnotation) -> Bool = { movingIDs.contains(ObjectIdentifier($0)) }
            switch action {
            case .bringToFront: logical = logical.filter { !isMoving($0) } + logical.filter(isMoving)
            case .sendToBack: logical = logical.filter(isMoving) + logical.filter { !isMoving($0) }
            case .bringForward:
                if logical.count > 1 {
                    for i in stride(from: logical.count - 2, through: 0, by: -1) where isMoving(logical[i]) && !isMoving(logical[i + 1]) {
                        logical.swapAt(i, i + 1)
                    }
                }
            case .sendBackward:
                if logical.count > 1 {
                    for i in 1..<logical.count where isMoving(logical[i]) && !isMoving(logical[i - 1]) {
                        logical.swapAt(i, i - 1)
                    }
                }
            }
            let oldLogical = original.filter { !($0 is SnapshotViewportTileAnnotation) }
            guard logical.map(ObjectIdentifier.init) != oldLogical.map(ObjectIdentifier.init) else { continue }
            var tiles: [ObjectIdentifier: [PDFAnnotation]] = [:]
            var orphans: [PDFAnnotation] = []
            for case let tile as SnapshotViewportTileAnnotation in original {
                if let owner = tile.snapshot, logical.contains(where: { $0 === owner }) {
                    tiles[ObjectIdentifier(owner), default: []].append(tile)
                } else { orphans.append(tile) }
            }
            let order = logical.flatMap { [$0] + (tiles[ObjectIdentifier($0)] ?? []) } + orphans
            changes.append((page, order))
        }
        guard !changes.isEmpty else { return }
        undo.beginUndoGrouping()
        for (page, order) in changes { restoreAnnotationOrder(order, on: page, selection: selection) }
        undo.setActionName(action.undoTitle)
        undo.endUndoGrouping()
    }

    private func restoreAnnotationOrder(_ order: [PDFAnnotation], on page: PDFPage, selection: [PDFAnnotation]) {
        let previous = page.annotations
        let previousSelection = selectedItems
        undo.registerUndo(withTarget: self) { target in target.restoreAnnotationOrder(previous, on: page, selection: previousSelection) }
        previous.forEach(page.removeAnnotation)
        order.forEach(page.addAnnotation)
        importedState?.reordered(page)
        setSelectedItems(selection)
        changed(page)
    }

    func deleteSelected() {
        guard canEdit() else { return }
        let items = selectedItems.filter { (RectangleMarkupRecord.owns($0) || ImportedMarkupState.selectable($0) || canAssignLayer($0)) && !$0.isReadOnly && !layerIsLocked($0) }
        guard !items.isEmpty else { return }
        cancelGesture()
        undo.beginUndoGrouping()
        for annotation in items {
            if let page = annotation.page { setPresence(false, annotation: annotation, page: page, action: "Delete Markups") }
        }
        undo.endUndoGrouping()
        selected = nil; refresh()
    }

    func hatchSelected(_ style: DraftingHatch?) {
        guard canEdit(), style?.isValid ?? true else { return }
        guard let annotation = selected else { hatchStyle = style; refresh(); return }
        guard RectangleMarkupRecord.owns(annotation), ["Square", "Circle", "Polygon"].contains(annotation.type ?? ""),
              !annotation.isReadOnly, !layerIsLocked(annotation), let page = annotation.page else { return }
        setHatch(style, on: annotation, page: page)
    }
    private func setHatch(_ style: DraftingHatch?, on annotation: PDFAnnotation, page: PDFPage) {
        guard page.document === boundDocument else { return }
        let old = DraftingHatch.read(annotation)
        guard old != style else { return }
        undo.registerUndo(withTarget: self) { target in target.setHatch(old, on: annotation, page: page) }
        undo.setActionName("Hatch Appearance")
        DraftingHatch.apply(style, to: annotation); selected = annotation; changed(page)
    }

    func fillSelected(_ color: NSColor?) {
        guard canEdit() else { return }
        guard let annotation = selected else { fillColor = color; refresh(); return }
        guard ["Square", "Circle", "Polygon"].contains(annotation.type ?? ""), !annotation.isReadOnly, !layerIsLocked(annotation), let page = annotation.page else { return }
        setFill(color,on:annotation,page:page)
    }
    private func setFill(_ color: NSColor?, on annotation: PDFAnnotation, page: PDFPage) {
        guard canEdit(), page.document === boundDocument, RectangleMarkupRecord.owns(annotation) else { return }
        let old = RectangleMarkupRecord.polygonFill(annotation)
        guard old != color else { return }
        undo.registerUndo(withTarget:self) { target in target.setFill(old,on:annotation,page:page) }; undo.setActionName("Fill")
        RectangleMarkupRecord.setPolygonFill(color,on:annotation); selected = annotation; changed(page)
    }

    func styleSelected(color: NSColor, width: CGFloat) {
        guard canEdit(), width.isFinite, color.usingColorSpace(.deviceRGB) != nil else { return }
        let opaque = color.withAlphaComponent(1)
        let width = min(max(width, 0.25), 72)
        guard let selected else { strokeColor = opaque; lineWidth = width; refresh(); return }
        guard !selected.isReadOnly, !layerIsLocked(selected), selected.type != "Stamp", let page = selected.page else { return }
        setStyle(selected, page: page, color: opaque, width: width)
    }

    func setLineAppearance(pattern: MarkupLinePattern, opacity: Double) {
        guard canEdit(), opacity.isFinite, (0...1).contains(opacity) else { return }
        guard let annotation = selected else { linePattern = pattern; strokeOpacity = opacity; refresh(); return }
        guard RectangleMarkupRecord.owns(annotation), !annotation.isReadOnly, !layerIsLocked(annotation), annotation.type != "Stamp", let page = annotation.page else { return }
        setLineAppearance(pattern: pattern, opacity: opacity, annotation: annotation, page: page)
    }
    private func setLineAppearance(pattern: MarkupLinePattern, opacity: Double, annotation: PDFAnnotation, page: PDFPage) {
        guard page.document === boundDocument else { return }
        let oldPattern = MarkupStyle.pattern(annotation), oldOpacity = MarkupStyle.strokeOpacity(annotation)
        guard oldPattern != pattern || oldOpacity != opacity else { return }
        undo.registerUndo(withTarget: self) { target in target.setLineAppearance(pattern: oldPattern, opacity: oldOpacity, annotation: annotation, page: page) }
        undo.setActionName("Markup Appearance")
        MarkupStyle.apply(pattern: pattern, opacity: opacity, to: annotation)
        selected = annotation; changed(page)
    }

    func setFontSize(_ size: CGFloat) {
        guard canEdit(), size.isFinite, (6...144).contains(size) else { return }
        if let selected {
            guard selected.type == "FreeText" else { return }
            editSelectedText(selected.contents ?? "", size: size)
        } else { fontSize = size; refresh() }
    }

    private func setStyle(_ annotation: PDFAnnotation, page: PDFPage, color: NSColor, width: CGFloat) {
        guard canEdit(), page.document === boundDocument, RectangleMarkupRecord.owns(annotation) else { return }
        let oldColor = RectangleMarkupRecord.markupColor(annotation); let oldWidth = annotation.border?.lineWidth ?? 2
        guard oldColor != color || (annotation.type != "FreeText" && oldWidth != width) else { return }
        undo.registerUndo(withTarget: self) { target in target.setStyle(annotation, page: page, color: oldColor, width: oldWidth) }
        undo.setActionName("Style Markup")
        if annotation.type == "Line" {
            let a = handlePoint(.lowerLeft,annotation:annotation), b = handlePoint(.upperRight,annotation:annotation)
            annotation.bounds = Self.lineBounds(a,b,width:width)
            annotation.startPoint = CGPoint(x:a.x-annotation.bounds.minX,y:a.y-annotation.bounds.minY)
            annotation.endPoint = CGPoint(x:b.x-annotation.bounds.minX,y:b.y-annotation.bounds.minY)
        }
        if annotation.type == "FreeText" { RectangleMarkupRecord.setTextColor(color,on:annotation) } else { annotation.color = color }
        let pattern = MarkupStyle.pattern(annotation), opacity = MarkupStyle.strokeOpacity(annotation)
        let border = PDFBorder(); border.lineWidth = annotation.type == "FreeText" ? 0 : width; annotation.border = border
        MarkupStyle.apply(pattern: pattern, opacity: opacity, to: annotation)
        changed(page)
    }

    func editSelectedText(_ text: String, size: CGFloat) {
        guard canEdit(), let annotation = selected, !annotation.isReadOnly, !layerIsLocked(annotation), annotation.type == "FreeText", RectangleMarkupRecord.owns(annotation), let page = annotation.page,
              !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, text.utf8.count <= 100000, size.isFinite, (6...144).contains(size) else { return }
        let oldText = annotation.contents ?? "", oldSize = RectangleMarkupRecord.textFontSize(annotation)
        guard oldText != text || oldSize != size else { return }
        undo.registerUndo(withTarget:self) { target in target.editSelectedTextAnnotation(annotation,page:page,text:oldText,size:oldSize) }
        undo.setActionName("Edit Text")
        annotation.contents = text; RectangleMarkupRecord.setTextFontSize(size,on:annotation); changed(page)
    }
    private func editSelectedTextAnnotation(_ annotation: PDFAnnotation, page: PDFPage, text: String, size: CGFloat) {
        guard page.document === boundDocument else { return }
        selected = annotation; editSelectedText(text,size:size)
    }

    func setBounds(_ bounds: CGRect, of annotation: PDFAnnotation, on page: PDFPage, action: String) {
        setGeometry(bounds, endpoints:nil, of:annotation, on:page, action:action)
    }
    func setGeometry(_ bounds: CGRect, endpoints: (CGPoint,CGPoint)?, of annotation: PDFAnnotation, on page: PDFPage, action: String) {
        guard canEdit(), page.document === boundDocument, (RectangleMarkupRecord.owns(annotation) || ImportedMarkupState.selectable(annotation)), !annotation.isReadOnly, !layerIsLocked(annotation), bounds.width >= 2, bounds.height >= 2, [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy({ $0.isFinite }) else { return }
        if let (a,b) = endpoints {
            guard [a.x,a.y,b.x,b.y].allSatisfy({ $0.isFinite }), bounds.contains(a), bounds.contains(b), hypot(a.x-b.x,a.y-b.y) >= 2 else { return }
        }
        let previous = annotation.bounds
        if annotation.type == "Stamp", RectangleMarkupRecord.owns(annotation), bounds.size != previous.size { return }
        if !RectangleMarkupRecord.owns(annotation) {
            guard bounds.size == previous.size, endpoints == nil else { return }
            undo.registerUndo(withTarget: self) { target in target.setGeometry(previous, endpoints: nil, of: annotation, on: page, action: action) }
            undo.setActionName(action)
            importedState?.touch(annotation)
            annotation.shouldDisplay = false
            page.removeAnnotation(annotation)
            annotation.bounds = bounds
            page.addAnnotation(annotation)
            annotation.shouldDisplay = true
            selected = annotation; changed(page, importedAppearanceChanged: true); return
        }
        let oldVertices = RectangleMarkupRecord.vertices(annotation)
        let oldEndpoints: (CGPoint,CGPoint)? = annotation.type == "Line" ? (handlePoint(.lowerLeft,annotation:annotation),handlePoint(.upperRight,annotation:annotation)) : nil
        if previous == bounds {
            if endpoints == nil { return }
            if let a = oldEndpoints, let b = endpoints, a.0 == b.0 && a.1 == b.1 { return }
        }
        let transformed = oldVertices.map { p in CGPoint(x:bounds.minX+(p.x-previous.minX)*bounds.width/previous.width,y:bounds.minY+(p.y-previous.minY)*bounds.height/previous.height) }
        if let measurement = MeasurementMetadata.measurement(annotation), !measurement.valid(points: transformed) { onInvalidMeasurement?(); return }
        undo.registerUndo(withTarget: self) { target in target.setGeometry(previous,endpoints:oldEndpoints,of:annotation,on:page,action:action) }
        undo.setActionName(action)
        annotation.bounds = bounds
        if annotation.type == "Ink" || annotation.type == "Polygon" {
            RectangleMarkupRecord.setVertices(transformed,on:annotation)
        }
        if let (a,b) = endpoints {
            annotation.startPoint = CGPoint(x:a.x-bounds.minX,y:a.y-bounds.minY)
            annotation.endPoint = CGPoint(x:b.x-bounds.minX,y:b.y-bounds.minY)
        }
        selected = annotation; changed(page)
    }

    /// Change path nodes without transforming any other node or the underlying page.
    func setVertexPositions(_ points: [CGPoint], of annotation: PDFAnnotation, on page: PDFPage) {
        let previous = RectangleMarkupRecord.vertices(annotation)
        guard canEdit(), page.document === boundDocument, RectangleMarkupRecord.owns(annotation),
              !annotation.isReadOnly, !layerIsLocked(annotation), !previous.isEmpty, points.count == previous.count,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), points != previous else { return }
        if let measurement = MeasurementMetadata.measurement(annotation), !measurement.valid(points: points) { onInvalidMeasurement?(); return }
        replaceVertices(points, bounds: vertexBounds(points, annotation: annotation), of: annotation, on: page, action: "Edit Markup Node")
    }

    /// A context-menu request is tied to the exact geometry and document that supplied it.
    struct NodeInsertion {
        let annotation: PDFAnnotation
        let page: PDFPage
        let document: PDFDocument
        let vertices: [CGPoint]
        let bounds: CGRect
        let closed: Bool
        let index: Int
        let point: CGPoint
    }

    private func canInsertNode(in annotation: PDFAnnotation, on page: PDFPage) -> Bool {
        canEdit() && page.document === boundDocument && view?.document === boundDocument && view?.currentPage === page &&
        annotation.page === page && page.annotations.contains(where: { $0 === annotation }) &&
        RectangleMarkupRecord.owns(annotation) && !annotation.isReadOnly && !layerIsLocked(annotation) &&
        annotation.shouldDisplay && layerIsVisible(annotation) &&
        (annotation.type == "Polygon" || (annotation.type == "Ink" && annotation.value(forAnnotationKey: RectangleMarkupRecord.inkToolKey) as? String != "pen"))
    }

    func nodeInsertion(for annotation: PDFAnnotation, at point: CGPoint, tolerance: CGFloat) -> NodeInsertion? {
        guard let page = annotation.page, let document = page.document, canInsertNode(in: annotation, on: page),
              point.x.isFinite, point.y.isFinite, tolerance.isFinite, tolerance > 0 else { return nil }
        let vertices = RectangleMarkupRecord.vertices(annotation)
        guard vertices.count >= 2, vertices.count < 10000, vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              !vertices.contains(where: { hypot($0.x-point.x, $0.y-point.y) <= tolerance }) else { return nil }
        let closed = annotation.type == "Polygon"
        var best: (index: Int, point: CGPoint, distance: CGFloat)?
        for index in 0..<(closed ? vertices.count : vertices.count-1) {
            let a = vertices[index], b = vertices[(index+1) % vertices.count]
            let dx = b.x-a.x, dy = b.y-a.y, length = dx*dx+dy*dy
            guard length.isFinite, length > 0 else { continue }
            let t = ((point.x-a.x)*dx+(point.y-a.y)*dy)/length
            guard t > 0, t < 1 else { continue }
            let projected = CGPoint(x: a.x+t*dx, y: a.y+t*dy)
            let distance = hypot(point.x-projected.x, point.y-projected.y)
            guard distance <= tolerance, distance < (best?.distance ?? .infinity),
                  !vertices.contains(where: { hypot($0.x-projected.x, $0.y-projected.y) <= tolerance }) else { continue }
            best = (index+1, projected, distance)
        }
        guard let best else { return nil }
        var inserted = vertices; inserted.insert(best.point, at: best.index)
        if let measurement = MeasurementMetadata.measurement(annotation), !measurement.valid(points: inserted) { return nil }
        return NodeInsertion(annotation: annotation, page: page, document: document, vertices: vertices,
                             bounds: annotation.bounds, closed: closed, index: best.index, point: best.point)
    }

    func insertNode(_ request: NodeInsertion) {
        let annotation = request.annotation, page = request.page
        guard boundDocument === request.document, canInsertNode(in: annotation, on: page),
              annotation.bounds == request.bounds, RectangleMarkupRecord.vertices(annotation) == request.vertices,
              (annotation.type == "Polygon") == request.closed else { return }
        var points = request.vertices; points.insert(request.point, at: request.index)
        replaceVertices(points, bounds: vertexBounds(points, annotation: annotation), of: annotation, on: page, action: "Add Markup Node")
    }

    private func vertexBounds(_ points: [CGPoint], annotation: PDFAnnotation) -> CGRect {
        let measurement = MeasurementMetadata.measurement(annotation)
        let padding: CGFloat = measurement == nil ? 0 : (measurement!.closed ? 8 : 24)
        return Self.polylineBounds(points, width: annotation.border?.lineWidth ?? 2).insetBy(dx: -padding, dy: -padding)
    }

    private func replaceVertices(_ points: [CGPoint], bounds: CGRect, of annotation: PDFAnnotation, on page: PDFPage, action: String) {
        let previous = RectangleMarkupRecord.vertices(annotation), previousBounds = annotation.bounds
        guard canEdit(), page.document === boundDocument, annotation.page === page, RectangleMarkupRecord.owns(annotation),
              !annotation.isReadOnly, !layerIsLocked(annotation), points.count >= 2,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), points != previous else { return }
        if let measurement = MeasurementMetadata.measurement(annotation), !measurement.valid(points: points) { onInvalidMeasurement?(); return }
        undo.registerUndo(withTarget: self) { target in
            target.replaceVertices(previous, bounds: previousBounds, of: annotation, on: page, action: action)
        }
        undo.setActionName(action)
        annotation.bounds = bounds
        RectangleMarkupRecord.setVertices(points, on: annotation)
        selected = annotation; changed(page)
    }

    static func windowSelects(_ annotation: PDFAnnotation, in region: CGRect, crossing: Bool) -> Bool {
        var points = RectangleMarkupRecord.vertices(annotation)
        if annotation.type == "Line" {
            let origin = annotation.bounds.origin
            points = [CGPoint(x: origin.x + annotation.startPoint.x, y: origin.y + annotation.startPoint.y),
                      CGPoint(x: origin.x + annotation.endPoint.x, y: origin.y + annotation.endPoint.y)]
        }
        guard points.count >= 2 else { return crossing ? region.intersects(annotation.bounds) : region.contains(annotation.bounds) }
        if !crossing { return points.allSatisfy(region.contains) }
        if points.contains(where: region.contains) { return true }
        let closed = annotation.type == "Polygon"
        let edges = Array(zip(points, points.dropFirst())) + (closed ? [(points.last!, points[0])] : [])
        func intersects(_ a: CGPoint, _ b: CGPoint) -> Bool {
            // Clip the actual segment, rather than its bounding box. A diagonal
            // must not be selected by a window that only touches an empty corner.
            var lower: CGFloat = 0, upper: CGFloat = 1
            let dx = b.x-a.x, dy = b.y-a.y
            for (p, q) in [(-dx, a.x-region.minX), (dx, region.maxX-a.x), (-dy, a.y-region.minY), (dy, region.maxY-a.y)] {
                if p == 0 { if q < 0 { return false }; continue }
                let t = q/p
                if p < 0 { lower = max(lower, t) } else { upper = min(upper, t) }
                if lower > upper { return false }
            }
            return true
        }
        if edges.contains(where: { intersects($0.0, $0.1) }) { return true }
        if closed && RectangleMarkupRecord.polygonFill(annotation) != nil {
            let path = CGMutablePath(); path.move(to: points[0]); points.dropFirst().forEach { path.addLine(to: $0) }; path.closeSubpath()
            return path.contains(CGPoint(x: region.midX, y: region.midY))
        }
        return false
    }

    static func hitTest(_ annotation: PDFAnnotation, at point: CGPoint, tolerance: CGFloat) -> Bool {
        let points = RectangleMarkupRecord.vertices(annotation)
        let radius = max(tolerance,(annotation.border?.lineWidth ?? 2)/2)
        if annotation.type == "Line" {
            let origin = annotation.bounds.origin
            let a = CGPoint(x:origin.x+annotation.startPoint.x,y:origin.y+annotation.startPoint.y)
            let b = CGPoint(x:origin.x+annotation.endPoint.x,y:origin.y+annotation.endPoint.y)
            return distanceFromSegment(point, a, b) <= radius
        }
        if annotation.type == "Ink", !RectangleMarkupRecord.owns(annotation), let paths = annotation.paths {
            let local = CGPoint(x: point.x - annotation.bounds.minX, y: point.y - annotation.bounds.minY)
            return paths.contains { path in
                let outline = CGMutablePath()
                for index in 0..<path.elementCount {
                    var points = [CGPoint](repeating: .zero, count: 3)
                    switch path.element(at: index, associatedPoints: &points) {
                    case .moveTo: outline.move(to: points[0])
                    case .lineTo: outline.addLine(to: points[0])
                    case .curveTo, .cubicCurveTo: outline.addCurve(to: points[2], control1: points[0], control2: points[1])
                    case .quadraticCurveTo: outline.addQuadCurve(to: points[1], control: points[0])
                    case .closePath: outline.closeSubpath()
                    @unknown default: break
                    }
                }
                return outline.copy(strokingWithWidth: radius * 2, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(local)
            }
        }
        if annotation.type == "Circle" {
            let bounds = annotation.bounds
            guard bounds.width > 0, bounds.height > 0 else { return false }
            let x = (point.x-bounds.midX)/(bounds.width/2+radius)
            let y = (point.y-bounds.midY)/(bounds.height/2+radius)
            return x*x+y*y <= 1
        }
        guard let first = points.first, points.count >= 2 else {
            return annotation.bounds.insetBy(dx: -radius, dy: -radius).contains(point)
        }
        let closed = annotation.type == "Polygon"
        let path = CGMutablePath(); path.move(to:first)
        for p in points.dropFirst() { path.addLine(to:p) }
        if closed {
            path.closeSubpath()
            if RectangleMarkupRecord.polygonFill(annotation) != nil && path.contains(point) { return true }
        }
        let edges = Array(zip(points,points.dropFirst())) + (closed ? [(points.last!,first)] : [])
        return edges.contains { a,b in distanceFromSegment(point,a,b) <= radius }
    }

    private static func distanceFromSegment(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x-a.x, dy = b.y-a.y, length = dx*dx+dy*dy
        let t = length > 0 ? min(1,max(0,((point.x-a.x)*dx+(point.y-a.y)*dy)/length)) : 0
        return hypot(point.x-a.x-t*dx,point.y-a.y-t*dy)
    }

    private func setPresence(_ exists: Bool, annotation: PDFAnnotation, page: PDFPage, action: String) {
        guard canEdit(), page.document === boundDocument else { return }
        undo.registerUndo(withTarget: self) { target in target.setPresence(!exists, annotation: annotation, page: page, action: action) }
        undo.setActionName(action)
        let imported = !RectangleMarkupRecord.owns(annotation)
        if imported { importedState?.touch(annotation) }
        (annotation as? DrawbridgeSnapshotAnnotation)?.isRetired = !exists
        if exists {
            page.addAnnotation(annotation)
            annotation.shouldDisplay = true
            selected = annotation
        } else {
            annotation.shouldDisplay = false
            page.removeAnnotation(annotation); selected = nil
        }
        applyLayerVisibility()
        changed(page, importedAppearanceChanged: true)
    }

    func changed(_ page: PDFPage, importedAppearanceChanged: Bool = true) {
        // Saved owned markups carry an AP stream. Once edited, regenerate from
        // live geometry rather than retaining the old appearance underneath.
        if let selected, selected.page === page, RectangleMarkupRecord.owns(selected), !(selected is DrawbridgeSnapshotAnnotation) {
            selected.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/AP"))
        }
        if let selected, selected.page === page { MeasurementMetadata.updateLabel(selected) }
        // A real style mutation during drafting survives cancellation of the text.
        if var draft = inlineText { draft.wasDirty = true; inlineText = draft }
        hasUnsavedChanges = true; (view as? MarkupPDFView)?.refreshAnnotationRendering(on: page, importedAppearanceChanged: importedAppearanceChanged); refresh(); onMutation?(page)
    }

    @discardableResult
    func removeLastDraftPoint() -> Bool {
        guard tool == .area || tool == .perimeter || tool == .polygon || tool == .polyline, !polylinePoints.isEmpty else { return false }
        polylinePoints.removeLast(); polylineHover = nil
        if polylinePoints.isEmpty { polylinePage = nil }
        refresh(presentationChanged: false)
        return true
    }
    func cancelGesture() { groupMove = nil; selectionWindow = nil; penConstraintAnchor = nil; pendingLine = nil; polylinePage = nil; polylinePoints = []; polylineHover = nil; gesture = nil; preview = nil; previewEndpoints = nil; previewVertices = nil; refresh() }
    func escape() { cancelSnapshotCapture(); cancelGesture(); selected = nil; onClickAway?(); tool = .select; refresh() }
    // Observes real overlay work, including presentation-silent viewport refreshes.
    var onOverlayRefresh: (() -> Void)?
    func refresh(presentationChanged: Bool = true) {
        onOverlayRefresh?()
        positionTextEditor()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        overlay.frame = view?.bounds ?? .zero
        let path = CGMutablePath()
        if let view, let (page, bounds) = preview ?? selected.flatMap({ a in a.page.map { ($0, a.bounds) } }), page.document === view.document, (preview != nil || page === view.currentPage) {
            let rect = view.convert(bounds, from: page).standardized
            let vertices = selected.map { RectangleMarkupRecord.vertices($0) } ?? []
            if !vertices.isEmpty, let annotation = selected {
                let original = annotation.bounds
                let points = previewVertices ?? vertices.map { p in
                    CGPoint(x:bounds.minX+(p.x-original.minX)*bounds.width/original.width,
                            y:bounds.minY+(p.y-original.minY)*bounds.height/original.height)
                }
                for (i,p) in points.enumerated() {
                    let q = view.convert(p,from:page)
                    if i == 0 { path.move(to:q) } else { path.addLine(to:q) }
                }
                if annotation.type == "Polygon" { path.closeSubpath() }
                for point in points {
                    let q = view.convert(point,from:page)
                    path.addRect(CGRect(x:q.x-4,y:q.y-4,width:8,height:8))
                }
            } else if let (a,b) = previewEndpoints {
                path.move(to:view.convert(a,from:page)); path.addLine(to:view.convert(b,from:page))
            } else if preview != nil && tool == .ellipse { path.addEllipse(in:rect) }
            else { path.addRect(rect) }
            if preview == nil && vertices.isEmpty && selected.map(RectangleMarkupRecord.owns) != false {
                let corners: [Corner] = selected?.type == "Stamp" ? [] : selected?.type == "Line" ? [.lowerLeft,.upperRight] : Corner.allCases
                for corner in corners {
                    let point = selected.map { handlePoint(corner,annotation:$0) } ?? Self.cornerPoint(corner,in:bounds)
                    let p = view.convert(point, from: page)
                    path.addRect(CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
                }
            }
        }
        if let view, let page = polylinePage {
            for (i,p) in (polylinePoints + (polylineHover.map { [$0] } ?? [])).enumerated() {
                if i == 0 { path.move(to:view.convert(p,from:page)) } else { path.addLine(to:view.convert(p,from:page)) }
            }
            if tool == .polygon || tool == .area || tool == .snapshotPolygon || tool == .snapshotBox { path.closeSubpath() }
        }
        if let view {
            for annotation in additionalSelection where annotation.page === view.currentPage {
                if let page = annotation.page { path.addRect(view.convert(annotation.bounds, from: page).standardized) }
            }
        }
        if let move = groupMove, let view {
            for (_, original) in move.originals { path.addRect(view.convert(original.offsetBy(dx: move.offset.x, dy: move.offset.y), from: move.page)) }
        }
        if let window = selectionWindow {
            path.addRect(Self.rect(window.start, window.end))
        }
        overlay.strokeColor = (tool == .pen && polylinePage != nil ? strokeColor.withAlphaComponent(strokeOpacity) : NSColor.systemBlue).cgColor
        overlay.lineDashPattern = tool == .pen && polylinePage != nil ? linePattern.dash(width: lineWidth).map { NSNumber(value: $0 * Double(view?.scaleFactor ?? 1)) } : nil
        if let window = selectionWindow {
            overlay.lineDashPattern = window.end.x < window.start.x ? [6, 4] : nil
        }
        overlay.lineWidth = tool == .pen && polylinePage != nil ? lineWidth * (view?.scaleFactor ?? 1) : 2
        overlay.lineCap = .round; overlay.lineJoin = .round
        overlay.path = path
        // Pointer previews change geometry only. Toolbar state changes on tool,
        // selection, style, and committed edits, rather than every mouse event.
        if presentationChanged { onPresentationChanged?() }
    }

    private func handlePoint(_ corner: Corner, annotation: PDFAnnotation) -> CGPoint {
        guard annotation.type == "Line" else { return Self.cornerPoint(corner,in:annotation.bounds) }
        let p = corner == .lowerLeft ? annotation.startPoint : annotation.endPoint
        return CGPoint(x:annotation.bounds.minX+p.x,y:annotation.bounds.minY+p.y)
    }
    static func lineBounds(_ a: CGPoint, _ b: CGPoint, width: CGFloat) -> CGRect {
        rect(a,b).insetBy(dx:-max(6,width*4),dy:-max(6,width*4))
    }

    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect { CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(a.x-b.x), height: abs(a.y-b.y)) }
    static func clamped(_ p: CGPoint, to r: CGRect) -> CGPoint { CGPoint(x: min(max(p.x,r.minX),r.maxX), y: min(max(p.y,r.minY),r.maxY)) }
    static func cornerPoint(_ c: Corner, in r: CGRect) -> CGPoint {
        switch c { case .lowerLeft: return CGPoint(x:r.minX,y:r.minY); case .lowerRight: return CGPoint(x:r.maxX,y:r.minY); case .upperLeft: return CGPoint(x:r.minX,y:r.maxY); case .upperRight: return CGPoint(x:r.maxX,y:r.maxY) }
    }
}

/// Closed shapes share independent stroke and fill opacity with polygons.
final class DrawbridgeShapeAnnotation: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard shouldDisplay else { return }
        let origin = page?.bounds(for: box).origin ?? .zero
        let width = border?.lineWidth ?? 2
        let rect = bounds.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: width / 2, dy: width / 2)
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.beginPath()
        if type == "Circle" { context.addEllipse(in: rect) } else { context.addRect(rect) }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width); context.setLineJoin(.round)
        context.setLineDash(phase: 0, lengths: MarkupStyle.pattern(self).dash(width: width).map { CGFloat($0) })
        if let hatch = DraftingHatch.read(self), hatch.preset != .solid, let path = context.path {
            context.beginPath()
            hatch.draw(path: path, bounds: bounds.offsetBy(dx: -origin.x, dy: -origin.y), opacity: MarkupStyle.fillOpacity(self), in: context)
            context.addPath(path); context.strokePath()
        }
        else if let fill = RectangleMarkupRecord.polygonFill(self) { context.setFillColor(fill.cgColor); context.drawPath(using: .fillStroke) }
        else { context.strokePath() }
    }
}

/// Draw a closed annotation path; never draw or transform the underlying page.
final class DrawbridgePolygonAnnotation: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard shouldDisplay else { return }
        let origin = page?.bounds(for:box).origin ?? .zero
        let points = RectangleMarkupRecord.vertices(self).map { CGPoint(x:$0.x-origin.x,y:$0.y-origin.y) }
        guard points.count >= 3 else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.beginPath(); context.move(to:points[0])
        for point in points.dropFirst() { context.addLine(to:point) }
        context.closePath(); context.setStrokeColor(color.cgColor)
        context.setLineWidth(border?.lineWidth ?? 2); context.setLineJoin(.round)
        context.setLineDash(phase: 0, lengths: MarkupStyle.pattern(self).dash(width: border?.lineWidth ?? 2).map { CGFloat($0) })
        if let hatch = DraftingHatch.read(self), hatch.preset != .solid, let path = context.path {
            context.beginPath()
            hatch.draw(path: path, bounds: bounds.offsetBy(dx: -origin.x, dy: -origin.y), opacity: MarkupStyle.fillOpacity(self), in: context)
            context.addPath(path); context.strokePath()
        }
        else if let fill = RectangleMarkupRecord.polygonFill(self) { context.setFillColor(fill.cgColor); context.drawPath(using:.fillStroke) }
        else { context.strokePath() }
        MeasurementAppearance.draw(self, box: box, context: context)
    }
}

/// A transient page overlay; typing never modifies original PDF content.
@MainActor
final class MarkupInlineTextView: NSTextView, NSTextViewDelegate {
    // Draft typing has its own history. Removing the transient editor must not
    // leave text-system undo actions mixed into the document's markup history.
    private let editingUndo = UndoManager()
    override var undoManager: UndoManager? { editingUndo }
    @objc func undo(_ sender: Any?) { editingUndo.undo() }
    @objc func redo(_ sender: Any?) { editingUndo.redo() }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return editingUndo.canUndo }
        if item.action == #selector(redo(_:)) { return editingUndo.canRedo }
        return super.validateUserInterfaceItem(item)
    }
    var retainedStorage: NSTextStorage?
    var onFinish: ((Bool)->Void)?
    var onChange: (()->Void)?
    override init(frame:NSRect,textContainer:NSTextContainer?) { super.init(frame:frame,textContainer:textContainer); delegate = self }
    required init?(coder:NSCoder) { super.init(coder:coder); delegate = self }
    func textDidChange(_ notification:Notification) { onChange?() }
    override func keyDown(with event:NSEvent) {
        if event.keyCode == 53 { onFinish?(true); return }
        if [36,76].contains(event.keyCode), event.modifierFlags.contains(.command) { onFinish?(false); return }
        super.keyDown(with:event)
    }
    override func resignFirstResponder() -> Bool {
        let wasEditing = window?.firstResponder === self
        let result = super.resignFirstResponder()
        if result && wasEditing { onFinish?(false) }
        return result
    }
}
