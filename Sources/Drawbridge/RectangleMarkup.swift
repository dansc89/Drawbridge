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
    static func read(_ url: URL) -> Self? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Self(size: Int(info.st_size), modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)),
                    device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino),
                    modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                    changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }
}

struct RectangleMarkupRecord: Sendable, Equatable {
    static let prefix = "DrawbridgeRectangleV1:"
    enum Kind: String, Sendable { case rectangle, ellipse, line, arrow, text, polyline, polygon }
    var kind: Kind = .rectangle
    var text: String = ""
    var fontSize: Double = 18
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

    static func owns(_ annotation: PDFAnnotation) -> Bool {
        ["Square", "Circle", "Line", "FreeText", "Ink", "Polygon"].contains(annotation.type ?? "") && annotation.userName?.hasPrefix(prefix) == true
    }

    static let fillKey = PDFAnnotationKey(rawValue:"DrawbridgePolygonFill")
    static func polygonFill(_ annotation: PDFAnnotation) -> NSColor? {
        guard let values = annotation.value(forAnnotationKey:fillKey) as? [Double], values.count == 3 else { return nil }
        return NSColor(deviceRed:values[0],green:values[1],blue:values[2],alpha:1)
    }
    static func setPolygonFill(_ color: NSColor?, on annotation: PDFAnnotation) {
        let rgb = color?.usingColorSpace(.deviceRGB)
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
        annotation.setValue([Double(rgb.redComponent),Double(rgb.greenComponent),Double(rgb.blueComponent)], forAnnotationKey: textColorKey)
        annotation.fontColor = color
        annotation.color = .clear
    }

    static func capture(_ document: PDFDocument) -> [Self] {
        // PDF editors may preserve /T when duplicating a markup. Give each owned
        // annotation its own identity without changing its appearance or geometry.
        var seen = Set<String>()
        return (0..<document.pageCount).flatMap { index in
            document.page(at: index)?.annotations.compactMap { annotation -> Self? in
                guard owns(annotation), var id = annotation.userName else { return nil }
                if !seen.insert(id).inserted {
                    id = prefix + UUID().uuidString
                    annotation.setValue(id, forAnnotationKey: PDFAnnotationKey(rawValue: "/T"))
                    annotation.setValue(id, forAnnotationKey: PDFAnnotationKey(rawValue: "/NM"))
                    seen.insert(id)
                }
                guard let rgb = markupColor(annotation).usingColorSpace(.deviceRGB) else { return nil }
                var record = Self(id: id, pageIndex: index, bounds: annotation.bounds,
                            red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent),
                            lineWidth: Double(annotation.border?.lineWidth ?? 2))
                if annotation.type == "FreeText" {
                    record.kind = .text; record.text = annotation.contents ?? ""; record.fontSize = Double(annotation.font?.pointSize ?? 18)
                    record.lineWidth = 2
                }
                if annotation.type == "Ink" || annotation.type == "Polygon" {
                    record.kind = annotation.type == "Polygon" ? .polygon : .polyline; record.vertices = vertices(annotation)
                    if let rgb = polygonFill(annotation)?.usingColorSpace(.deviceRGB), record.kind == .polygon { record.fill = [Double(rgb.redComponent),Double(rgb.greenComponent),Double(rgb.blueComponent)] }
                }
                if annotation.type == "Circle" { record.kind = .ellipse }
                if annotation.type == "Line" {
                    record.kind = annotation.endLineStyle == .openArrow ? .arrow : .line
                    record.start = CGPoint(x: annotation.bounds.minX + annotation.startPoint.x, y: annotation.bounds.minY + annotation.startPoint.y)
                    record.end = CGPoint(x: annotation.bounds.minX + annotation.endPoint.x, y: annotation.bounds.minY + annotation.endPoint.y)
                }
                return record
            } ?? []
        }
    }

    var isValid: Bool {
        id.hasPrefix(Self.prefix) && pageIndex >= 0 &&
        [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy { $0.isFinite } &&
        bounds.width >= 2 && bounds.height >= 2 &&
        [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } &&
        (kind != .text || (!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && text.utf8.count <= 100000 && fontSize.isFinite && (6...144).contains(fontSize))) &&
        (fill == nil || (kind == .polygon && fill!.count == 3 && fill!.allSatisfy { $0.isFinite && (0...1).contains($0) })) &&
        (!(kind == .polyline || kind == .polygon) || (vertices.count >= (kind == .polygon ? 3 : 2) && vertices.count <= 10000 && vertices.allSatisfy { $0.x.isFinite && $0.y.isFinite && bounds.contains($0) })) &&
        lineWidth.isFinite && (0.25...12).contains(lineWidth) &&
        (!(kind == .line || kind == .arrow) || (start != nil && end != nil && [start!.x,start!.y,end!.x,end!.y].allSatisfy { $0.isFinite } && bounds.contains(start!) && bounds.contains(end!) && hypot(start!.x-end!.x,start!.y-end!.y) >= 2))
    }
}

/// New annotation interaction state; deliberately independent of legacy ToolMode.
@MainActor
final class RectangleMarkupController {
    enum Tool { case select, pen, rectangle, ellipse, line, arrow, text, polyline, polygon }
    enum Corner: CaseIterable { case lowerLeft, lowerRight, upperLeft, upperRight }
    private enum Gesture {
        case create(PDFPage, CGPoint)
        case vertex(PDFPage, PDFAnnotation, Int)
        case edit(PDFPage, PDFAnnotation, CGRect, CGPoint, Corner?)
    }
    weak var view: PDFView?
    private weak var boundDocument: PDFDocument?
    private let fallbackUndo = UndoManager()
    var undo: UndoManager { inlineText?.editor.undoManager ?? view?.window?.undoManager ?? fallbackUndo }
    private(set) var selected: PDFAnnotation?
    private var gesture: Gesture?
    private var pendingLine: (page: PDFPage, start: CGPoint)?
    private var preview: (PDFPage, CGRect)?
    private var polylinePage: PDFPage?
    private var polylinePoints: [CGPoint] = []
    private var polylineHover: CGPoint?
    private var previewEndpoints: (CGPoint, CGPoint)?
    private var previewVertices: [CGPoint]?
    private final class DocumentState: NSObject {
        let dirty: Bool; let stamp: PDFMarkupSourceStamp?
        init(dirty: Bool, stamp: PDFMarkupSourceStamp?) { self.dirty = dirty; self.stamp = stamp }
    }
    private let documentStates = NSMapTable<PDFDocument, DocumentState>.weakToStrongObjects()
    private(set) var hasUnsavedChanges = false
    private(set) var sourceStamp: PDFMarkupSourceStamp?
    func rememberSource(_ url: URL?) {
        guard !hasUnsavedChanges || sourceStamp == nil else { return }
        sourceStamp = url.flatMap(PDFMarkupSourceStamp.read)
    }
    var onMutation: ((PDFPage) -> Void)?
    var onDraftChanged: (() -> Void)?
    var onDraftBegan: (() -> Void)?
    var onDraftEnded: (() -> Void)?
    var onPresentationChanged: (() -> Void)?
    var canEdit: () -> Bool = { true }
    var tool: Tool = .select {
        didSet { finishTextEditing(); cancelGesture(); if tool != .select { selected = nil }; refresh() }
    }
    private var inlineText: (page:PDFPage, bounds:CGRect, annotation:PDFAnnotation?, editor:MarkupInlineTextView, wasDirty:Bool)?
    var isEditingText: Bool { inlineText != nil }
    var fontSize: CGFloat = 18
    var fillColor: NSColor? = .orange
    var strokeColor: NSColor = .red
    var lineWidth: CGFloat = 2
    private let overlay = CAShapeLayer()

    static func shortcutTool(for event: NSEvent) -> Tool? {
        let modifiers = event.modifierFlags.intersection([.shift,.command,.option,.control])
        switch (event.charactersIgnoringModifiers?.lowercased(),modifiers) {
        case ("v", []): return .select
        case ("p", []): return .pen
        case ("a", []): return .arrow
        case ("t", []): return .text
        case ("e", []): return .ellipse
        case ("r", []): return .rectangle
        case ("l", []): return .line
        case ("n", [.shift]): return .polyline
        case ("p", [.shift]): return .polygon
        default: return nil
        }
    }
    func handleToolShortcut(_ event: NSEvent) -> Bool {
        guard canEdit(), let tool = Self.shortcutTool(for:event) else { return false }
        self.tool = tool
        return true
    }

    func bind(to document: PDFDocument?) {
        guard boundDocument !== document else { return }
        finishTextEditing()
        if let previous = boundDocument {
            documentStates.setObject(DocumentState(dirty: hasUnsavedChanges, stamp: sourceStamp), forKey: previous)
        }
        cancelGesture()
        undo.removeAllActions(withTarget: self)
        fallbackUndo.removeAllActions()
        boundDocument = document
        if let document {
            for index in 0..<document.pageCount {
                guard let page = document.page(at:index) else { continue }
                for original in page.annotations where original.type == "Polygon" && RectangleMarkupRecord.owns(original) && !(original is DrawbridgePolygonAnnotation) {
                    let polygon = DrawbridgePolygonAnnotation(bounds:original.bounds,forType:PDFAnnotationSubtype(rawValue:"/Polygon"),withProperties:nil)
                    polygon.setValue(original.userName ?? "",forAnnotationKey:PDFAnnotationKey(rawValue:"/T")); polygon.contents = original.contents; polygon.color = original.color; polygon.border = original.border
                    polygon.shouldDisplay = original.shouldDisplay; polygon.shouldPrint = original.shouldPrint; polygon.isReadOnly = original.isReadOnly
                    RectangleMarkupRecord.setVertices(RectangleMarkupRecord.vertices(original),on:polygon)
                    RectangleMarkupRecord.setPolygonFill(RectangleMarkupRecord.polygonFill(original),on:polygon)
                    page.removeAnnotation(original); page.addAnnotation(polygon)
                }
            }
        }
        selected = nil; hasUnsavedChanges = false; tool = .select
        sourceStamp = document?.documentURL.flatMap(PDFMarkupSourceStamp.read)
        if let document, let state = documentStates.object(forKey: document) {
            hasUnsavedChanges = state.dirty; sourceStamp = state.stamp
        }
        refresh()
    }

    func install(on view: PDFView) {
        self.view = view
        view.wantsLayer = true
        overlay.strokeColor = NSColor.systemBlue.cgColor
        overlay.fillColor = NSColor.clear.cgColor
        overlay.lineWidth = 2
        overlay.zPosition = 2000
        view.layer?.addSublayer(overlay)
    }

    func markSaved(at url: URL) { hasUnsavedChanges = false; rememberSource(url) }
    /// A save can finish after another markup was added. Advance the known file
    /// version without marking those newer edits clean.
    func acceptPersistedSource(at url: URL) { sourceStamp = PDFMarkupSourceStamp.read(url) }

    func pointerDown(at location: CGPoint, clickCount: Int = 1) -> Bool {
        finishTextEditing()
        guard let view, canEdit(), let page = view.page(for: location, nearest: false) else { return false }
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
        if tool == .line || tool == .arrow {
            view.setCurrentSelection(nil, animate: false)
            let endpoint = Self.clamped(point, to: page.bounds(for: view.displayBox))
            if let draft = pendingLine {
                guard draft.page === page else { return true }
                guard hypot(draft.start.x-endpoint.x, draft.start.y-endpoint.y) >= 2 else { return true }
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
        if tool == .polyline || tool == .polygon {
            view.setCurrentSelection(nil, animate:false)
            guard polylinePage == nil || polylinePage === page else { return true }
            polylinePage = page
            let p = Self.clamped(point,to:page.bounds(for:view.displayBox))
            if let last = polylinePoints.last, hypot(last.x-p.x,last.y-p.y) < 0.5 { } else { polylinePoints.append(p) }
            polylineHover = p
            if clickCount >= 2 { finishPolyline() } else { refresh() }
            return true
        }
        if clickCount >= 2, let hit = page.annotations.reversed().first(where:{ RectangleMarkupRecord.owns($0) && $0.type == "FreeText" && !$0.isReadOnly && $0.bounds.contains(point) }) {
            selected = hit; beginTextEditing(on:page,bounds:hit.bounds,annotation:hit); return true
        }
        if tool != .select {
            view.setCurrentSelection(nil, animate: false)
            gesture = .create(page, point); preview = (page, CGRect(origin: point, size: .zero)); refresh()
            return true
        }
        if let selected, selected.page === page {
            let vertices = RectangleMarkupRecord.vertices(selected)
            if let index = vertices.indices.first(where: { i in
                let p = view.convert(vertices[i],from:page)
                return hypot(location.x-p.x,location.y-p.y) <= 8
            }) {
                gesture = .vertex(page,selected,index); previewVertices = vertices
                preview = (page,selected.bounds); refresh(); return true
            }
            let corners: [Corner] = !vertices.isEmpty ? [] : selected.type == "Line" ? [.lowerLeft, .upperRight] : Corner.allCases
            let corner = corners.first { corner in
                let p = view.convert(handlePoint(corner, annotation: selected), from: page)
                return hypot(location.x - p.x, location.y - p.y) <= 8
            }
            if corner != nil || Self.hitTest(selected,at:point,tolerance:8 / max(view.scaleFactor,0.01)) {
                gesture = .edit(page, selected, selected.bounds, point, corner)
                preview = (page, selected.bounds); refresh(); return true
            }
        }
        if let hit = page.annotations.reversed().first(where: { RectangleMarkupRecord.owns($0) && !$0.isReadOnly && $0.shouldDisplay && Self.hitTest($0,at:point,tolerance:8 / max(view.scaleFactor,0.01)) }) {
            selected = hit; view.setCurrentSelection(nil, animate: false)
            gesture = .edit(page, hit, hit.bounds, point, nil); preview = (page, hit.bounds); refresh(); return true
        }
        selected = nil; refresh(); return false
    }

    func pointerMoved(at location: CGPoint) {
        if let draft = pendingLine, let view {
            guard view.page(for: location, nearest: false) === draft.page else { return }
            let end = Self.clamped(view.convert(location, to: draft.page), to: draft.page.bounds(for: view.displayBox))
            previewEndpoints = (draft.start, end)
            preview = (draft.page, Self.lineBounds(draft.start, end, width: lineWidth))
            refresh(presentationChanged: false); return
        }
        guard let view, let page = polylinePage else { return }
        polylineHover = Self.clamped(view.convert(location,to:page),to:page.bounds(for:view.displayBox)); refresh(presentationChanged: false)
    }
    @discardableResult
    func finishPolyline() -> Bool {
        guard let page = polylinePage else { return false }
        let points = polylinePoints
        polylinePage = nil; polylinePoints = []; polylineHover = nil
        _ = createPolyline(on:page,points:points,closed:tool == .polygon); refresh(); return true
    }
    @discardableResult
    func createPolyline(on page: PDFPage, points: [CGPoint], closed: Bool = false) -> PDFAnnotation? {
        guard points.count >= (closed ? 3 : 2), points.count <= 10000, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              zip(points,points.dropFirst()).contains(where: { hypot($0.0.x-$0.1.x,$0.0.y-$0.1.y) >= 2 }) else { return nil }
        let bounds = Self.polylineBounds(points,width:lineWidth)
        guard let annotation = create(on:page,bounds:bounds,kind:closed ? .polygon : .polyline,vertices:points) else { return nil }
        return annotation
    }
    static func polylineBounds(_ points: [CGPoint], width: CGFloat) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x:xs.min() ?? 0,y:ys.min() ?? 0,width:(xs.max() ?? 0)-(xs.min() ?? 0),height:(ys.max() ?? 0)-(ys.min() ?? 0)).insetBy(dx:-max(6,width*4),dy:-max(6,width*4))
    }

    @discardableResult
    func pointerDragged(at location: CGPoint) -> Bool {
        if tool == .pen, let view, let page = polylinePage {
            let point = Self.clamped(view.convert(location, to: page), to: page.bounds(for: view.displayBox))
            if let last = polylinePoints.last, hypot(last.x-point.x, last.y-point.y) >= 0.25 / max(view.scaleFactor, 0.01), polylinePoints.count < 10000 {
                polylinePoints.append(point)
            }
            refresh(presentationChanged: false)
            return true
        }
        if pendingLine != nil { pointerMoved(at: location); return true }
        guard let view, let gesture else { return false }
        switch gesture {
        case .vertex(let page, let annotation, let index):
            var points = RectangleMarkupRecord.vertices(annotation)
            guard points.indices.contains(index) else { return false }
            points[index] = Self.clamped(view.convert(location,to:page),to:page.bounds(for:view.displayBox))
            previewVertices = points
            preview = (page,Self.polylineBounds(points,width:annotation.border?.lineWidth ?? 2))
        case .create(let page, let start):
            let end = Self.clamped(view.convert(location, to: page), to: page.bounds(for: view.displayBox))
            if tool == .line || tool == .arrow {
                previewEndpoints = (start,end); preview = (page, Self.lineBounds(start,end,width:lineWidth))
            } else { preview = (page, Self.rect(start, end)) }
        case .edit(let page, let annotation, let original, let start, let corner):
            let end = view.convert(location, to: page)
            let crop = page.bounds(for: view.displayBox)
            if annotation.type == "Line" {
                var a = handlePoint(.lowerLeft, annotation: annotation), b = handlePoint(.upperRight, annotation: annotation)
                if let corner {
                    if corner == .lowerLeft { a = Self.clamped(end,to:crop) } else { b = Self.clamped(end,to:crop) }
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

    func pointerUp(at location: CGPoint) -> Bool {
        if tool == .pen, let page = polylinePage {
            _ = pointerDragged(at: location)
            let points = polylinePoints
            polylinePage = nil; polylinePoints = []; polylineHover = nil
            _ = createPolyline(on: page, points: points)
            selected = nil
            refresh()
            return true
        }
        if pendingLine != nil { return true }
        if tool == .polyline || tool == .polygon { return true }
        guard let gesture else { return false }
        _ = pointerDragged(at: location)
        let candidate = preview?.1
        let endpoints = previewEndpoints
        let vertices = previewVertices
        self.gesture = nil; preview = nil; previewEndpoints = nil; previewVertices = nil
        guard canEdit(), let candidate, candidate.width >= 2, candidate.height >= 2 else { refresh(); return true }
        switch gesture {
        case .vertex(let page, let annotation, _):
            if let vertices { setVertexPositions(vertices,of:annotation,on:page) }
        case .create(let page, _):
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

    @discardableResult
    func create(on page: PDFPage, bounds: CGRect, kind: RectangleMarkupRecord.Kind = .rectangle, endpoints: (CGPoint,CGPoint)? = nil, text: String = "", vertices: [CGPoint] = []) -> PDFAnnotation? {
        guard canEdit(), bounds.width >= 2, bounds.height >= 2,
              page.document === boundDocument, [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy({ $0.isFinite }) else { return nil }
        if kind == .text && (text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || text.utf8.count > 100000) { return nil }
        if (kind == .polyline || kind == .polygon) && (vertices.count < (kind == .polygon ? 3 : 2) || vertices.count > 10000 || !vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && bounds.contains($0) })) { return nil }
        let type: PDFAnnotationSubtype = kind == .polygon ? PDFAnnotationSubtype(rawValue:"/Polygon") : kind == .polyline ? .ink : kind == .text ? .freeText : kind == .ellipse ? .circle : (kind == .line || kind == .arrow ? .line : .square)
        if type == .line {
            guard let (a,b) = endpoints, [a.x,a.y,b.x,b.y].allSatisfy({ $0.isFinite }), bounds.contains(a), bounds.contains(b), hypot(a.x-b.x,a.y-b.y) >= 2 else { return nil }
        }
        let annotation = kind == .polygon ? DrawbridgePolygonAnnotation(bounds:bounds,forType:type,withProperties:nil) : PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
        if let (a,b) = endpoints {
            annotation.startPoint = CGPoint(x:a.x-bounds.minX,y:a.y-bounds.minY)
            annotation.endPoint = CGPoint(x:b.x-bounds.minX,y:b.y-bounds.minY)
            annotation.endLineStyle = kind == .arrow ? .openArrow : .none
        }
        annotation.setValue(RectangleMarkupRecord.prefix + UUID().uuidString,forAnnotationKey:PDFAnnotationKey(rawValue:"/T"))
        annotation.contents = kind == .text ? text : kind.rawValue.capitalized
        if kind == .text { annotation.font = NSFont(name:"Helvetica",size:fontSize); annotation.fontColor = strokeColor; annotation.alignment = .left }
        if kind == .text { RectangleMarkupRecord.setTextColor(strokeColor,on:annotation) } else { annotation.color = strokeColor }
        let border = PDFBorder(); border.lineWidth = kind == .text ? 0 : lineWidth; annotation.border = border
        if kind == .polyline || kind == .polygon { RectangleMarkupRecord.setVertices(vertices,on:annotation) }
        if kind == .polygon { RectangleMarkupRecord.setPolygonFill(fillColor,on:annotation) }
        annotation.shouldDisplay = true; annotation.shouldPrint = true
        setPresence(true, annotation: annotation, page: page, action: "Add " + kind.rawValue.capitalized)
        return annotation
    }

    func beginTextEditing(on page:PDFPage, bounds:CGRect, annotation:PDFAnnotation? = nil) {
        finishTextEditing()
        guard canEdit(), page.document === boundDocument, let view else { return }
        if let annotation, !RectangleMarkupRecord.owns(annotation) || annotation.type != "FreeText" || annotation.isReadOnly { return }
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

    func deleteSelected() {
        guard canEdit(), let selected, RectangleMarkupRecord.owns(selected), !selected.isReadOnly, let page = selected.page else { return }
        cancelGesture(); setPresence(false, annotation: selected, page: page, action: "Delete Markup")
    }

    func fillSelected(_ color: NSColor?) {
        fillColor = color
        guard canEdit(), let annotation = selected, annotation.type == "Polygon", !annotation.isReadOnly, let page = annotation.page else { return }
        setFill(color,on:annotation,page:page)
    }
    private func setFill(_ color: NSColor?, on annotation: PDFAnnotation, page: PDFPage) {
        guard canEdit(), page.document === boundDocument, RectangleMarkupRecord.owns(annotation) else { return }
        let old = RectangleMarkupRecord.polygonFill(annotation)
        guard old != color else { return }
        undo.registerUndo(withTarget:self) { target in target.setFill(old,on:annotation,page:page) }; undo.setActionName("Polygon Fill")
        RectangleMarkupRecord.setPolygonFill(color,on:annotation); selected = annotation; changed(page)
    }

    func styleSelected(color: NSColor, width: CGFloat) {
        strokeColor = color; lineWidth = min(max(width, 0.25), 12)
        refresh()
        guard canEdit(), let selected, !selected.isReadOnly, let page = selected.page else { return }
        setStyle(selected, page: page, color: strokeColor, width: lineWidth)
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
        let border = PDFBorder(); border.lineWidth = annotation.type == "FreeText" ? 0 : width; annotation.border = border
        changed(page)
    }

    func editSelectedText(_ text: String, size: CGFloat) {
        guard canEdit(), let annotation = selected, annotation.type == "FreeText", RectangleMarkupRecord.owns(annotation), let page = annotation.page,
              !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, text.utf8.count <= 100000, size.isFinite, (6...144).contains(size) else { return }
        let oldText = annotation.contents ?? "", oldSize = annotation.font?.pointSize ?? 18
        guard oldText != text || oldSize != size else { return }
        undo.registerUndo(withTarget:self) { target in target.editSelectedTextAnnotation(annotation,page:page,text:oldText,size:oldSize) }
        undo.setActionName("Edit Text")
        annotation.contents = text; annotation.font = NSFont(name:"Helvetica",size:size); changed(page)
    }
    private func editSelectedTextAnnotation(_ annotation: PDFAnnotation, page: PDFPage, text: String, size: CGFloat) {
        guard page.document === boundDocument else { return }
        selected = annotation; editSelectedText(text,size:size)
    }

    func setBounds(_ bounds: CGRect, of annotation: PDFAnnotation, on page: PDFPage, action: String) {
        setGeometry(bounds, endpoints:nil, of:annotation, on:page, action:action)
    }
    func setGeometry(_ bounds: CGRect, endpoints: (CGPoint,CGPoint)?, of annotation: PDFAnnotation, on page: PDFPage, action: String) {
        guard canEdit(), page.document === boundDocument, RectangleMarkupRecord.owns(annotation), !annotation.isReadOnly, bounds.width >= 2, bounds.height >= 2, [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy({ $0.isFinite }) else { return }
        if let (a,b) = endpoints {
            guard [a.x,a.y,b.x,b.y].allSatisfy({ $0.isFinite }), bounds.contains(a), bounds.contains(b), hypot(a.x-b.x,a.y-b.y) >= 2 else { return }
        }
        let previous = annotation.bounds
        let oldVertices = RectangleMarkupRecord.vertices(annotation)
        let oldEndpoints: (CGPoint,CGPoint)? = annotation.type == "Line" ? (handlePoint(.lowerLeft,annotation:annotation),handlePoint(.upperRight,annotation:annotation)) : nil
        if previous == bounds {
            if endpoints == nil { return }
            if let a = oldEndpoints, let b = endpoints, a.0 == b.0 && a.1 == b.1 { return }
        }
        undo.registerUndo(withTarget: self) { target in target.setGeometry(previous,endpoints:oldEndpoints,of:annotation,on:page,action:action) }
        undo.setActionName(action)
        annotation.bounds = bounds
        if annotation.type == "Ink" || annotation.type == "Polygon" {
            RectangleMarkupRecord.setVertices(oldVertices.map { p in CGPoint(x:bounds.minX+(p.x-previous.minX)*bounds.width/previous.width,y:bounds.minY+(p.y-previous.minY)*bounds.height/previous.height) },on:annotation)
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
              !annotation.isReadOnly, !previous.isEmpty, points.count == previous.count,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), points != previous else { return }
        undo.registerUndo(withTarget:self) { target in target.setVertexPositions(previous,of:annotation,on:page) }
        undo.setActionName("Edit Markup Node")
        annotation.bounds = Self.polylineBounds(points,width:annotation.border?.lineWidth ?? 2)
        RectangleMarkupRecord.setVertices(points,on:annotation)
        selected = annotation; changed(page)
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
        if annotation.type == "Circle" {
            let bounds = annotation.bounds
            guard bounds.width > 0, bounds.height > 0 else { return false }
            let x = (point.x-bounds.midX)/(bounds.width/2+radius)
            let y = (point.y-bounds.midY)/(bounds.height/2+radius)
            return x*x+y*y <= 1
        }
        guard let first = points.first, points.count >= 2 else { return annotation.bounds.contains(point) }
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
        if exists { page.addAnnotation(annotation); selected = annotation } else { page.removeAnnotation(annotation); selected = nil }
        changed(page)
    }

    private func changed(_ page: PDFPage) {
        // A real style mutation during drafting survives cancellation of the text.
        if var draft = inlineText { draft.wasDirty = true; inlineText = draft }
        hasUnsavedChanges = true; (view as? MarkupPDFView)?.refreshAnnotationRendering(on: page); refresh(); onMutation?(page)
    }

    func cancelGesture() { pendingLine = nil; polylinePage = nil; polylinePoints = []; polylineHover = nil; gesture = nil; preview = nil; previewEndpoints = nil; previewVertices = nil; refresh() }
    func escape() { cancelGesture(); selected = nil; tool = .select; refresh() }
    func refresh(presentationChanged: Bool = true) {
        positionTextEditor()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        overlay.frame = view?.bounds ?? .zero
        let path = CGMutablePath()
        if let view, let (page, bounds) = preview ?? selected.flatMap({ a in a.page.map { ($0, a.bounds) } }), page.document === view.document {
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
            if preview == nil && vertices.isEmpty {
                let corners: [Corner] = selected?.type == "Line" ? [.lowerLeft,.upperRight] : Corner.allCases
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
            if tool == .polygon { path.closeSubpath() }
        }
        overlay.strokeColor = (tool == .pen && polylinePage != nil ? strokeColor : NSColor.systemBlue).cgColor
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

/// Draw a closed annotation path; never draw or transform the underlying page.
final class DrawbridgePolygonAnnotation: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let origin = page?.bounds(for:box).origin ?? .zero
        let points = RectangleMarkupRecord.vertices(self).map { CGPoint(x:$0.x-origin.x,y:$0.y-origin.y) }
        guard points.count >= 3 else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.beginPath(); context.move(to:points[0])
        for point in points.dropFirst() { context.addLine(to:point) }
        context.closePath(); context.setStrokeColor(color.cgColor)
        context.setLineWidth(border?.lineWidth ?? 2); context.setLineJoin(.round)
        if let fill = RectangleMarkupRecord.polygonFill(self) { context.setFillColor(fill.cgColor); context.drawPath(using:.fillStroke) }
        else { context.strokePath() }
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
