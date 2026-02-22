import AppKit
import PDFKit
import UniformTypeIdentifiers

final class MarkupPDFView: PDFView, NSTextFieldDelegate {
    private typealias Segment = (start: NSPoint, end: NSPoint)
    private enum ResizeCorner {
        case lowerLeft
        case lowerRight
        case upperLeft
        case upperRight
    }
    private enum CalloutDragHandle {
        case moveAll
        case tip
        case elbow
        case textCorner(ResizeCorner)
    }
    private struct CalloutDragState {
        var page: PDFPage
        var textAnnotation: PDFAnnotation
        var leaderAnnotation: PDFAnnotation
        var dotAnnotation: PDFAnnotation?
        var startTextBounds: NSRect
        var startElbow: NSPoint
        var startTip: NSPoint
        var startPointerInPage: NSPoint
        var handle: CalloutDragHandle
    }
    private struct DimensionGeometry {
        let segments: [Segment]
        let labelAnchor: NSPoint
    }
    private struct DimensionStyle {
        let offset: CGFloat
        let extensionOvershoot: CGFloat
        let tickLength: CGFloat
        let tickAngle: CGFloat
        let labelOffset: CGFloat
    }
    private static let calloutGroupPrefix = "DrawbridgeCallout:"
    private static let textGroupPrefix = "DrawbridgeText:"
    private static let textOutlineMarker = "Drawbridge Text Outline"
    enum ArrowEndStyle: Int, CaseIterable {
        case solidArrow = 0
        case openArrow = 1
        case filledDot = 2
        case openDot = 3
        case filledSquare = 4
        case openSquare = 5
        case filledTriangle = 6
        case openTriangle = 7

        var displayName: String {
            switch self {
            case .solidArrow: return "Solid Arrow"
            case .openArrow: return "Open Arrow"
            case .filledDot: return "Filled Dot"
            case .openDot: return "Open Dot"
            case .filledSquare: return "Filled Square"
            case .openSquare: return "Open Square"
            case .filledTriangle: return "Filled Triangle"
            case .openTriangle: return "Open Triangle"
            }
        }
    }

    var toolMode: ToolMode = .pen
    var penColor: NSColor = .systemRed
    var penLineWidth: CGFloat = 15.0
    var arrowStrokeColor: NSColor = .systemRed
    var arrowLineWidth: CGFloat = 2.0
    var areaLineWidth: CGFloat = 1.0
    var highlighterColor: NSColor = NSColor.systemYellow.withAlphaComponent(0.5)
    var highlighterLineWidth: CGFloat = 31.0
    var rectangleStrokeColor: NSColor = .systemRed
    var rectangleFillColor: NSColor = .systemYellow
    var rectangleLineWidth: CGFloat = 50.0
    var textForegroundColor: NSColor = .labelColor
    var textBackgroundColor: NSColor = NSColor.systemOrange.withAlphaComponent(0.25)
    var textOutlineColor: NSColor = MarkupStyleDefaults.textOutlineColor
    var textOutlineWidth: CGFloat = MarkupStyleDefaults.textOutlineWidth
    var textFontName: String = ".SFNS-Regular"
    var textFontSize: CGFloat = 15.0
    var calloutStrokeColor: NSColor = .systemRed
    var calloutLineWidth: CGFloat = 2.0
    var calloutArrowStyle: ArrowEndStyle = .solidArrow
    var arrowHeadSize: CGFloat = 8.0
    var calloutArrowHeadSize: CGFloat = 8.0
    var measurementStrokeColor: NSColor = .systemBlue
    var calibrationStrokeColor: NSColor = .systemGreen
    var measurementLineWidth: CGFloat = 2.0
    var measurementUnitsPerPoint: CGFloat = 1.0
    var measurementUnitLabel: String = "pt"
    var onCalibrationDistanceMeasured: ((CGFloat) -> Void)?
    var onAnnotationAdded: ((PDFPage, PDFAnnotation, String) -> Void)?
    var onAnnotationTextEdited: ((PDFPage, PDFAnnotation, String) -> Void)?
    var onAnnotationClicked: ((PDFPage, PDFAnnotation) -> Void)?
    var onAnnotationsBoxSelected: ((PDFPage, [PDFAnnotation]) -> Void)?
    var onAnnotationMoved: ((PDFPage, PDFAnnotation, NSRect) -> Void)?
    var onResolveDragSelection: ((PDFPage, PDFAnnotation) -> [PDFAnnotation])?
    var onDeleteKeyPressed: (() -> Void)?
    var onSnapshotCaptured: ((Data, NSRect) -> Void)?
    var onOpenDroppedPDF: ((URL) -> Void)?
    var onImageDropped: ((PDFPage, PDFAnnotation, NSRect) -> Void)?
    var onToolShortcut: ((ToolMode) -> Void)?
    var onPageNavigationShortcut: ((Int) -> Void)?
    var onViewportChanged: (() -> Void)?
    var onRegionCaptured: ((PDFPage, NSRect) -> Void)?
    var shouldBeginMarkupInteraction: (() -> Bool)?

    private var dragStartInView: NSPoint?
    private var dragPage: PDFPage?
    private var middlePanLastWindowPoint: NSPoint?
    private var regionCaptureStartInView: NSPoint?
    private var regionCapturePage: PDFPage?
    private var isRegionCaptureModeEnabled = false
    private var didPushRegionCaptureCursor = false
    private var penPointsPage: [NSPoint] = []
    private var penPage: PDFPage?
    private var penPreviewPath: CGMutablePath?
    private var penLastPointInView: NSPoint?
    private var inlineTextField: NSTextField?
    private var inlineTextPage: PDFPage?
    private var inlineTextAnchorInPage: NSPoint?
    private var inlineLiveTextAnnotation: PDFAnnotation?
    private var inlineAnnotationWasDisplayed = true
    private var inlineEditingExistingAnnotation = false
    private var inlineOriginalTextContents: String?
    private var movingAnnotation: PDFAnnotation?
    private var movingAnnotationPage: PDFPage?
    private var movingAnnotationStartBounds: NSRect?
    private var movingStartPointInPage: NSPoint?
    private var movingResizeCorner: ResizeCorner?
    private var movingCalloutState: CalloutDragState?
    private var movingAnnotations: [PDFAnnotation] = []
    private var movingAnnotationStartBoundsByID: [ObjectIdentifier: NSRect] = [:]
    private var didMoveAnnotation = false
    private var fenceStartInView: NSPoint?
    private var fencePage: PDFPage?
    private var pendingCalloutPage: PDFPage?
    private var pendingCalloutTipInPage: NSPoint?
    private var pendingCalloutElbowInPage: NSPoint?
    private var pendingCalloutGroupID: String?
    private var pendingPolylinePage: PDFPage?
    private var pendingPolylinePointsInPage: [NSPoint] = []
    private var pendingArrowPage: PDFPage?
    private var pendingArrowStartInPage: NSPoint?
    private var pendingLinePage: PDFPage?
    private var pendingLineStartInPage: NSPoint?
    private var pendingAreaPage: PDFPage?
    private var pendingAreaPointsInPage: [NSPoint] = []
    private var pendingMeasurePage: PDFPage?
    private var pendingMeasureStartInPage: NSPoint?
    private var lastPointerInView: NSPoint?
    private var typedDistanceBuffer: String = ""
    private var mouseTrackingArea: NSTrackingArea?
    private let dragPreviewLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.strokeColor = NSColor.systemRed.cgColor
        layer.fillColor = NSColor.systemRed.withAlphaComponent(0.08).cgColor
        layer.lineWidth = 2
        layer.lineJoin = .round
        layer.lineCap = .round
        layer.zPosition = 10
        layer.actions = [
            "path": NSNull(),
            "strokeColor": NSNull(),
            "fillColor": NSNull(),
            "lineWidth": NSNull()
        ]
        layer.isHidden = true
        return layer
    }()
    private let calloutTextBoxPreviewLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.strokeColor = NSColor.systemRed.cgColor
        layer.fillColor = NSColor.clear.cgColor
        layer.lineWidth = 1.0
        layer.lineJoin = .round
        layer.zPosition = 9
        layer.actions = [
            "path": NSNull(),
            "strokeColor": NSNull(),
            "fillColor": NSNull(),
            "lineWidth": NSNull(),
            "hidden": NSNull()
        ]
        layer.isHidden = true
        return layer
    }()
    private let dropHighlightLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.strokeColor = NSColor.controlAccentColor.cgColor
        layer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        layer.lineWidth = 3
        layer.lineDashPattern = [10, 6]
        layer.isHidden = true
        return layer
    }()
    private let gridOverlayLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.22).cgColor
        layer.fillColor = NSColor.clear.cgColor
        layer.lineWidth = 0.8
        layer.zPosition = 1
        layer.isHidden = true
        layer.actions = [
            "path": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()
    private let textEditCaretLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.strokeColor = NSColor.systemBlue.cgColor
        layer.fillColor = NSColor.clear.cgColor
        layer.lineWidth = 1.25
        layer.zPosition = 25
        layer.isHidden = true
        layer.actions = [
            "path": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()
    private let typedDistanceHUDBackgroundLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
        layer.fillColor = NSColor.black.withAlphaComponent(0.82).cgColor
        layer.lineWidth = 1.0
        layer.zPosition = 40
        layer.isHidden = true
        layer.actions = [
            "path": NSNull(),
            "hidden": NSNull(),
            "position": NSNull(),
            "bounds": NSNull()
        ]
        return layer
    }()
    private let typedDistanceHUDTextLayer: CATextLayer = {
        let layer = CATextLayer()
        layer.alignmentMode = .left
        layer.truncationMode = .none
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.zPosition = 41
        layer.isWrapped = false
        layer.isHidden = true
        layer.actions = [
            "hidden": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "string": NSNull()
        ]
        return layer
    }()
    private let snapStatusBackgroundLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.7).cgColor
        layer.fillColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
        layer.lineWidth = 1.0
        layer.zPosition = 45
        layer.isHidden = true
        layer.actions = [
            "path": NSNull(),
            "hidden": NSNull(),
            "position": NSNull(),
            "bounds": NSNull()
        ]
        return layer
    }()
    private let snapStatusTextLayer: CATextLayer = {
        let layer = CATextLayer()
        layer.alignmentMode = .left
        layer.truncationMode = .none
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.zPosition = 46
        layer.isWrapped = false
        layer.isHidden = true
        layer.actions = [
            "hidden": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "string": NSNull(),
            "opacity": NSNull()
        ]
        return layer
    }()
    private var snapStatusHideWorkItem: DispatchWorkItem?
    private var textEditCaretTimer: Timer?
    private var isGridVisible = false
    private var isGridSnapEnabled = false
    private var isOrthoSnapEnabled = false
    private var isEndpointSnapEnabled = false
    private var isMidpointSnapEnabled = false
    private var isIntersectionSnapEnabled = false
    private let gridSpacingInPoints: CGFloat = 24.0
    private let maxGridLinesPerAxis = 400

    private func forceUprightTextAnnotationIfSupported(_ annotation: PDFAnnotation, on page: PDFPage) {
        let selector = NSSelectorFromString("setRotation:")
        guard annotation.responds(to: selector) else { return }
        let pageRotation = ((page.rotation % 360) + 360) % 360
        let desired = (360 - pageRotation) % 360
        annotation.setValue(desired, forKey: "rotation")
    }

    private func configureInlineEditorField(_ field: NSTextField) {
        field.alignment = .left
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        if let cell = field.cell as? NSTextFieldCell {
            cell.wraps = true
            cell.usesSingleLineMode = false
            cell.isScrollable = false
            cell.lineBreakMode = .byWordWrapping
        }
    }

    private func resolvedTextBackgroundColor(for annotation: PDFAnnotation) -> NSColor {
        annotation.color
    }

    private func applyTextBoxStyle(to annotation: PDFAnnotation) {
        annotation.color = textBackgroundColor
        annotation.interiorColor = nil
        assignLineWidth(0.0, to: annotation)
    }

    private func inlineEditorDisplayFont(from baseFont: NSFont) -> NSFont {
        let zoom = max(0.05, scaleFactor)
        return baseFont.withSize(max(4.0, baseFont.pointSize * zoom))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(gridOverlayLayer)
        layer?.addSublayer(calloutTextBoxPreviewLayer)
        layer?.addSublayer(dragPreviewLayer)
        layer?.addSublayer(dropHighlightLayer)
        layer?.addSublayer(textEditCaretLayer)
        layer?.addSublayer(typedDistanceHUDBackgroundLayer)
        layer?.addSublayer(typedDistanceHUDTextLayer)
        layer?.addSublayer(snapStatusBackgroundLayer)
        layer?.addSublayer(snapStatusTextLayer)
        autoScales = true
        displayMode = .singlePage
        displayDirection = .vertical
        displaysPageBreaks = true
        refreshAppearanceColors()
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearanceColors()
    }

    func refreshAppearanceColors() {
        backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1.0)
    }

    override func layout() {
        super.layout()
        let insetBounds = bounds.insetBy(dx: 24, dy: 24)
        dropHighlightLayer.path = CGPath(roundedRect: insetBounds, cornerWidth: 14, cornerHeight: 14, transform: nil)
        updateGridOverlayIfNeeded()
    }

    func setGridVisible(_ visible: Bool) {
        isGridVisible = visible
        updateGridOverlayIfNeeded()
    }

    func setGridSnapEnabled(_ enabled: Bool) {
        isGridSnapEnabled = enabled
    }

    func setOrthoSnapEnabled(_ enabled: Bool) {
        isOrthoSnapEnabled = enabled
    }

    func setEndpointSnapEnabled(_ enabled: Bool) {
        isEndpointSnapEnabled = enabled
    }

    func setMidpointSnapEnabled(_ enabled: Bool) {
        isMidpointSnapEnabled = enabled
    }

    func setIntersectionSnapEnabled(_ enabled: Bool) {
        isIntersectionSnapEnabled = enabled
    }

    private func isOrthoConstraintActive(for event: NSEvent) -> Bool {
        event.modifierFlags.contains(.shift) || (isOrthoSnapEnabled && (toolMode == .line || toolMode == .polyline))
    }

    func showSnapStatusToast(enabled: Bool) {
        snapStatusHideWorkItem?.cancel()
        snapStatusHideWorkItem = nil

        let text = enabled ? "SNAP ON" : "SNAP OFF"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let paddingX: CGFloat = 10
        let paddingY: CGFloat = 6
        let toastWidth = max(90, ceil(textSize.width) + paddingX * 2)
        let toastHeight = max(26, ceil(textSize.height) + paddingY * 2)

        let anchorPoint: NSPoint
        if let pointer = lastPointerInView {
            anchorPoint = pointer
        } else {
            anchorPoint = NSPoint(x: bounds.midX, y: bounds.midY)
        }
        var origin = NSPoint(x: anchorPoint.x + 12, y: anchorPoint.y + 28)
        origin.x = min(max(8, origin.x), max(8, bounds.maxX - toastWidth - 8))
        origin.y = min(max(8, origin.y), max(8, bounds.maxY - toastHeight - 8))
        let rect = NSRect(x: origin.x, y: origin.y, width: toastWidth, height: toastHeight)

        snapStatusBackgroundLayer.path = CGPath(roundedRect: rect, cornerWidth: 7, cornerHeight: 7, transform: nil)
        snapStatusBackgroundLayer.fillColor = (enabled ? NSColor.systemBlue : NSColor.systemGray).withAlphaComponent(0.90).cgColor
        snapStatusBackgroundLayer.isHidden = false

        snapStatusTextLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        snapStatusTextLayer.string = NSAttributedString(string: text, attributes: attrs)
        snapStatusTextLayer.frame = NSRect(
            x: rect.minX + paddingX,
            y: rect.minY + paddingY - 1,
            width: rect.width - paddingX * 2,
            height: rect.height - paddingY * 2
        )
        snapStatusTextLayer.opacity = 1.0
        snapStatusTextLayer.isHidden = false

        let hideWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.snapStatusBackgroundLayer.isHidden = true
            self.snapStatusBackgroundLayer.path = nil
            self.snapStatusTextLayer.isHidden = true
            self.snapStatusTextLayer.string = nil
            CATransaction.commit()
        }
        snapStatusHideWorkItem = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: hideWork)
    }

    private func snapPointInPageIfNeeded(_ point: NSPoint, on page: PDFPage) -> NSPoint {
        guard isGridSnapEnabled || isEndpointSnapEnabled || isMidpointSnapEnabled || isIntersectionSnapEnabled else { return point }
        let pointInView = convert(point, from: page)
        let snappedInView = snapPointInViewIfNeeded(pointInView, on: page)
        return convert(snappedInView, to: page)
    }

    private func snapPointInViewIfNeeded(_ point: NSPoint, on page: PDFPage) -> NSPoint {
        if isEndpointSnapEnabled || isMidpointSnapEnabled || isIntersectionSnapEnabled {
            let segments = snapSegmentsInView(on: page)
            var candidates: [NSPoint] = []
            candidates.reserveCapacity(segments.count * 2)
            if isEndpointSnapEnabled {
                for segment in segments {
                    candidates.append(segment.start)
                    candidates.append(segment.end)
                }
            }
            if isMidpointSnapEnabled {
                for segment in segments {
                    candidates.append(NSPoint(x: (segment.start.x + segment.end.x) * 0.5, y: (segment.start.y + segment.end.y) * 0.5))
                }
            }
            if isIntersectionSnapEnabled {
                candidates.append(contentsOf: segmentIntersectionsInView(from: segments))
            }
            if let snapPoint = nearestPoint(to: point, within: 14.0, from: candidates) {
                return snapPoint
            }
        }
        guard isGridVisible, isGridSnapEnabled else { return point }
        let pageBounds = page.bounds(for: displayBox)
        let spacing = gridSpacingInPoints
        guard spacing.isFinite, spacing > 0 else { return point }
        let pointInPage = convert(point, to: page)
        guard pointInPage.x.isFinite,
              pointInPage.y.isFinite else {
            return point
        }
        let snappedPageX = pageBounds.minX + round((pointInPage.x - pageBounds.minX) / spacing) * spacing
        let snappedPageY = pageBounds.minY + round((pointInPage.y - pageBounds.minY) / spacing) * spacing
        return convert(NSPoint(x: snappedPageX, y: snappedPageY), from: page)
    }

    private func nearestPoint(to target: NSPoint, within maxDistance: CGFloat, from points: [NSPoint]) -> NSPoint? {
        var bestPoint: NSPoint?
        var bestDistance = maxDistance
        for point in points {
            let distance = hypot(point.x - target.x, point.y - target.y)
            if distance <= bestDistance {
                bestDistance = distance
                bestPoint = point
            }
        }
        return bestPoint
    }

    private func endpointSnapEligible(_ annotation: PDFAnnotation) -> Bool {
        guard annotation.shouldDisplay else { return false }
        guard let type = annotation.type?.lowercased(), type.contains("ink") else { return false }
        let contents = (annotation.contents ?? "").lowercased()
        return contents.contains("line") || contents.contains("polyline")
    }

    private func annotationSegmentsInPage(for annotation: PDFAnnotation) -> [(NSPoint, NSPoint)] {
        guard let path = annotation.paths?.first, path.elementCount > 0 else { return [] }
        let origin = annotation.bounds.origin
        var segments: [(NSPoint, NSPoint)] = []
        segments.reserveCapacity(max(1, path.elementCount - 1))
        var previousPoint: NSPoint?

        for idx in 0..<path.elementCount {
            var points = [NSPoint](repeating: .zero, count: 3)
            let element = path.element(at: idx, associatedPoints: &points)
            switch element {
            case .moveTo:
                previousPoint = NSPoint(x: points[0].x + origin.x, y: points[0].y + origin.y)
            case .lineTo:
                let point = NSPoint(x: points[0].x + origin.x, y: points[0].y + origin.y)
                if let previousPoint, hypot(point.x - previousPoint.x, point.y - previousPoint.y) > 0.01 {
                    segments.append((previousPoint, point))
                }
                previousPoint = point
            default:
                break
            }
        }
        return segments
    }

    private struct SnapSegmentInView {
        let start: NSPoint
        let end: NSPoint
    }

    private func snapSegmentsInView(on page: PDFPage) -> [SnapSegmentInView] {
        var segments: [SnapSegmentInView] = []
        segments.reserveCapacity(120)
        for annotation in page.annotations {
            guard endpointSnapEligible(annotation) else { continue }
            let annotationSegments = annotationSegmentsInPage(for: annotation)
            guard !annotationSegments.isEmpty else { continue }
            for segment in annotationSegments {
                segments.append(SnapSegmentInView(start: convert(segment.0, from: page), end: convert(segment.1, from: page)))
            }
        }
        return segments
    }

    private func segmentIntersectionsInView(from segments: [SnapSegmentInView]) -> [NSPoint] {
        guard segments.count >= 2 else { return [] }
        let capped = min(segments.count, 220)
        var intersections: [NSPoint] = []
        intersections.reserveCapacity(min(400, capped * 2))
        for i in 0..<(capped - 1) {
            for j in (i + 1)..<capped {
                if let p = segmentIntersectionPoint(segments[i].start, segments[i].end, segments[j].start, segments[j].end) {
                    intersections.append(p)
                }
            }
        }
        return intersections
    }

    private func segmentIntersectionPoint(_ p1: NSPoint, _ p2: NSPoint, _ p3: NSPoint, _ p4: NSPoint) -> NSPoint? {
        let x1 = p1.x, y1 = p1.y
        let x2 = p2.x, y2 = p2.y
        let x3 = p3.x, y3 = p3.y
        let x4 = p4.x, y4 = p4.y
        let denominator = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
        if abs(denominator) < 0.00001 { return nil }

        let det1 = x1 * y2 - y1 * x2
        let det2 = x3 * y4 - y3 * x4
        let px = (det1 * (x3 - x4) - (x1 - x2) * det2) / denominator
        let py = (det1 * (y3 - y4) - (y1 - y2) * det2) / denominator

        func within(_ v: CGFloat, _ a: CGFloat, _ b: CGFloat) -> Bool {
            let minV = min(a, b) - 0.5
            let maxV = max(a, b) + 0.5
            return v >= minV && v <= maxV
        }
        guard within(px, x1, x2), within(py, y1, y2), within(px, x3, x4), within(py, y3, y4) else {
            return nil
        }
        return NSPoint(x: px, y: py)
    }

    func beginRegionCaptureMode() {
        isRegionCaptureModeEnabled = true
        regionCaptureStartInView = nil
        regionCapturePage = nil
        dragPreviewLayer.strokeColor = NSColor.systemBlue.cgColor
        dragPreviewLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        dragPreviewLayer.lineWidth = 1.5
        dragPreviewLayer.lineDashPattern = [6, 4]
        dragPreviewLayer.isHidden = true
        dragPreviewLayer.path = nil
        if !didPushRegionCaptureCursor {
            NSCursor.crosshair.push()
            didPushRegionCaptureCursor = true
        }
    }

    func cancelRegionCaptureMode() {
        isRegionCaptureModeEnabled = false
        regionCaptureStartInView = nil
        regionCapturePage = nil
        dragPreviewLayer.isHidden = true
        dragPreviewLayer.path = nil
        dragPreviewLayer.lineDashPattern = nil
        if didPushRegionCaptureCursor {
            NSCursor.pop()
            didPushRegionCaptureCursor = false
        }
    }

    private func updateGridOverlayIfNeeded() {
        guard isGridVisible,
              let page = currentPage else {
            gridOverlayLayer.isHidden = true
            gridOverlayLayer.path = nil
            return
        }

        let pageBounds = page.bounds(for: displayBox)
        let startInView = convert(NSPoint(x: pageBounds.minX, y: pageBounds.minY), from: page)
        let endInView = convert(NSPoint(x: pageBounds.maxX, y: pageBounds.maxY), from: page)
        guard startInView.x.isFinite, startInView.y.isFinite, endInView.x.isFinite, endInView.y.isFinite else {
            gridOverlayLayer.isHidden = true
            gridOverlayLayer.path = nil
            return
        }
        let pageRectInView = normalizedRect(from: startInView, to: endInView)
        guard pageRectInView.width.isFinite,
              pageRectInView.height.isFinite,
              pageRectInView.width > 1,
              pageRectInView.height > 1,
              pageRectInView.width < 200_000,
              pageRectInView.height < 200_000 else {
            gridOverlayLayer.isHidden = true
            gridOverlayLayer.path = nil
            return
        }

        let majorEvery = 5
        let path = CGMutablePath()
        let spacing = gridSpacingInPoints
        guard spacing.isFinite, spacing > 0 else {
            gridOverlayLayer.isHidden = true
            gridOverlayLayer.path = nil
            return
        }
        let pageWidth = pageBounds.width
        let pageHeight = pageBounds.height
        let xLineEstimate = Int(ceil(pageWidth / spacing)) + 1
        let yLineEstimate = Int(ceil(pageHeight / spacing)) + 1
        guard xLineEstimate <= maxGridLinesPerAxis, yLineEstimate <= maxGridLinesPerAxis else {
            // Avoid extreme path sizes on atypical documents/zoom levels.
            gridOverlayLayer.isHidden = true
            gridOverlayLayer.path = nil
            return
        }

        var i = 0
        var xPage = pageBounds.minX
        while xPage <= pageBounds.maxX + 0.001, i <= maxGridLinesPerAxis {
            let from = convert(NSPoint(x: xPage, y: pageBounds.minY), from: page)
            let to = convert(NSPoint(x: xPage, y: pageBounds.maxY), from: page)
            path.move(to: CGPoint(x: from.x, y: from.y))
            path.addLine(to: CGPoint(x: to.x, y: to.y))
            if i % majorEvery == 0 {
                path.move(to: CGPoint(x: from.x + 0.25, y: from.y))
                path.addLine(to: CGPoint(x: to.x + 0.25, y: to.y))
            }
            xPage += spacing
            i += 1
        }

        i = 0
        var yPage = pageBounds.minY
        while yPage <= pageBounds.maxY + 0.001, i <= maxGridLinesPerAxis {
            let from = convert(NSPoint(x: pageBounds.minX, y: yPage), from: page)
            let to = convert(NSPoint(x: pageBounds.maxX, y: yPage), from: page)
            path.move(to: CGPoint(x: from.x, y: from.y))
            path.addLine(to: CGPoint(x: to.x, y: to.y))
            if i % majorEvery == 0 {
                path.move(to: CGPoint(x: from.x, y: from.y + 0.25))
                path.addLine(to: CGPoint(x: to.x, y: to.y + 0.25))
            }
            yPage += spacing
            i += 1
        }

        gridOverlayLayer.path = path
        gridOverlayLayer.isHidden = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = mouseTrackingArea {
            removeTrackingArea(tracking)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        mouseTrackingArea = tracking
    }

    override func mouseMoved(with event: NSEvent) {
        lastPointerInView = convert(event.locationInWindow, from: nil)
        updateTypedDistanceHUD()
        if toolMode == .line {
            let ortho = isOrthoConstraintActive(for: event)
            if let page = pendingLinePage, let pointer = lastPointerInView {
                updateLinePreview(at: snapPointInViewIfNeeded(pointer, on: page), orthogonal: ortho)
            } else {
                updateLinePreview(at: lastPointerInView, orthogonal: ortho)
            }
            return
        }
        if toolMode == .measure {
            updateMeasurePreview(with: event)
            return
        }
        if toolMode == .polyline {
            let locationInView = convert(event.locationInWindow, from: nil)
            let ortho = isOrthoConstraintActive(for: event)
            if let page = pendingPolylinePage {
                updatePolylinePreview(at: snapPointInViewIfNeeded(locationInView, on: page), orthogonal: ortho)
            } else {
                updatePolylinePreview(at: locationInView, orthogonal: ortho)
            }
            return
        }
        if toolMode == .arrow {
            let locationInView = convert(event.locationInWindow, from: nil)
            updateArrowPreview(at: locationInView, orthogonal: event.modifierFlags.contains(.shift))
            return
        }
        if toolMode == .area {
            let locationInView = convert(event.locationInWindow, from: nil)
            updateAreaPreview(at: locationInView, orthogonal: event.modifierFlags.contains(.shift))
            return
        }
        if toolMode == .text {
            let locationInView = convert(event.locationInWindow, from: nil)
            if let page = page(for: locationInView, nearest: true) {
                updateTextPreview(at: snapPointInViewIfNeeded(locationInView, on: page))
            } else {
                updateTextPreview(at: locationInView)
            }
            return
        }
        guard toolMode == .callout else {
            super.mouseMoved(with: event)
            return
        }
        let locationInView = convert(event.locationInWindow, from: nil)
        if let page = pendingCalloutPage ?? page(for: locationInView, nearest: true) {
            updateCalloutPreview(at: snapPointInViewIfNeeded(locationInView, on: page))
        } else {
            updateCalloutPreview(at: locationInView)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let locationInView = convert(event.locationInWindow, from: nil)
        lastPointerInView = locationInView
        if isRegionCaptureModeEnabled {
            guard let page = page(for: locationInView, nearest: true) else { return }
            regionCaptureStartInView = locationInView
            regionCapturePage = page
            dragPreviewLayer.strokeColor = NSColor.systemBlue.cgColor
            dragPreviewLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
            dragPreviewLayer.lineWidth = 1.5
            dragPreviewLayer.lineDashPattern = [6, 4]
            dragPreviewLayer.path = CGPath(rect: NSRect(origin: locationInView, size: .zero), transform: nil)
            dragPreviewLayer.isHidden = false
            return
        }
        let createsMarkupTool: Bool
        switch toolMode {
        case .pen, .arrow, .highlighter, .line, .polyline, .area, .cloud, .rectangle, .text, .callout, .measure, .calibrate:
            createsMarkupTool = true
        default:
            createsMarkupTool = false
        }
        if createsMarkupTool, (shouldBeginMarkupInteraction?() == false) {
            return
        }

        if toolMode == .callout {
            handleCalloutClick(at: locationInView)
            return
        }
        if toolMode == .select, let page = page(for: locationInView, nearest: true) {
            let pointInPage = convert(locationInView, to: page)
            if let hit = nearestAnnotation(
                to: pointInPage,
                on: page,
                maxDistance: selectionHitDistanceInPage()
            ) {
                let dragCandidates = onResolveDragSelection?(page, hit) ?? [hit]
                let shouldPreserveSelectionForDrag = dragCandidates.count > 1
                if !shouldPreserveSelectionForDrag {
                    onAnnotationClicked?(page, hit)
                }
                if event.clickCount >= 2, isEditableTextAnnotation(hit) {
                    beginInlineTextEditing(for: hit, on: page)
                    return
                }
                if let calloutState = initialCalloutDragState(from: hit, on: page, pointerInView: locationInView, pointerInPage: pointInPage) {
                    movingCalloutState = calloutState
                    didMoveAnnotation = false
                    return
                }
                movingAnnotation = hit
                movingAnnotationPage = page
                movingAnnotationStartBounds = hit.bounds
                movingStartPointInPage = pointInPage
                movingResizeCorner = resizeCornerHit(for: hit, on: page, at: locationInView)
                let requested = dragCandidates
                if movingResizeCorner != nil {
                    movingAnnotations = [hit]
                } else {
                    var seen = Set<ObjectIdentifier>()
                    movingAnnotations = requested.filter { candidate in
                        let key = ObjectIdentifier(candidate)
                        if seen.contains(key) { return false }
                        seen.insert(key)
                        return candidate.page === page
                    }
                    if movingAnnotations.isEmpty {
                        movingAnnotations = [hit]
                    }
                }
                movingAnnotationStartBoundsByID = Dictionary(uniqueKeysWithValues: movingAnnotations.map { (ObjectIdentifier($0), $0.bounds) })
                didMoveAnnotation = false
                return
            }
            fenceStartInView = locationInView
            fencePage = page
            dragPreviewLayer.strokeColor = NSColor.controlAccentColor.cgColor
            dragPreviewLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            dragPreviewLayer.lineWidth = 1.5
            dragPreviewLayer.lineDashPattern = [6, 4]
            dragPreviewLayer.path = CGPath(rect: NSRect(origin: locationInView, size: .zero), transform: nil)
            dragPreviewLayer.isHidden = false
            return
        }

        switch toolMode {
        case .select:
            return
        case .grab:
            guard let page = page(for: locationInView, nearest: true) else {
                super.mouseDown(with: event)
                return
            }
            dragStartInView = locationInView
            dragPage = page
            dragPreviewLayer.strokeColor = NSColor.controlAccentColor.cgColor
            dragPreviewLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            dragPreviewLayer.lineWidth = 1.5
            dragPreviewLayer.lineDashPattern = [6, 4]
            dragPreviewLayer.path = CGPath(rect: NSRect(origin: locationInView, size: .zero), transform: nil)
            dragPreviewLayer.isHidden = false
            return
        case .pen, .highlighter:
            if inlineTextField != nil {
                _ = commitInlineTextEditor(cancel: false)
            }
            guard let page = page(for: locationInView, nearest: true) else {
                super.mouseDown(with: event)
                return
            }
            penPage = page
            penPointsPage = [convert(locationInView, to: page)]
            let path = CGMutablePath()
            path.move(to: locationInView)
            penPreviewPath = path
            penLastPointInView = locationInView
            let strokeColor = (toolMode == .highlighter) ? highlighterColor : penColor
            let strokeWidth = (toolMode == .highlighter) ? highlighterLineWidth : penLineWidth
            dragPreviewLayer.strokeColor = strokeColor.cgColor
            dragPreviewLayer.fillColor = NSColor.clear.cgColor
            dragPreviewLayer.lineWidth = strokeWidth
            dragPreviewLayer.path = path
            dragPreviewLayer.isHidden = false
        case .arrow:
            if inlineTextField != nil {
                _ = commitInlineTextEditor(cancel: false)
            }
            guard let page = page(for: locationInView, nearest: true) else {
                super.mouseDown(with: event)
                return
            }
            let pointInPage = snapPointInPageIfNeeded(convert(locationInView, to: page), on: page)
            if pendingArrowPage == nil || pendingArrowPage !== page || pendingArrowStartInPage == nil {
                pendingArrowPage = page
                pendingArrowStartInPage = pointInPage
                updateArrowPreview(at: snapPointInViewIfNeeded(locationInView, on: page), orthogonal: event.modifierFlags.contains(.shift))
            } else if let start = pendingArrowStartInPage {
                let endInPage: NSPoint
                if event.modifierFlags.contains(.shift) {
                    let startInView = convert(start, from: page)
                    let snapped = orthogonalSnapPoint(anchor: startInView, current: locationInView)
                    endInPage = snapPointInPageIfNeeded(convert(snapped, to: page), on: page)
                } else {
                    endInPage = pointInPage
                }
                addArrowAnnotation(from: start, to: endInPage, on: page)
                clearPendingArrow()
            }
            return
        case .line:
            if inlineTextField != nil {
                _ = commitInlineTextEditor(cancel: false)
            }
            guard let page = page(for: locationInView, nearest: true) else {
                super.mouseDown(with: event)
                return
            }
            typedDistanceBuffer = ""
            let pointInPage = snapPointInPageIfNeeded(convert(locationInView, to: page), on: page)
            let ortho = isOrthoConstraintActive(for: event)
            if pendingLinePage == nil || pendingLinePage !== page || pendingLineStartInPage == nil {
                pendingLinePage = page
                pendingLineStartInPage = pointInPage
            } else if let start = pendingLineStartInPage {
                let endInPage: NSPoint
                if ortho {
                    let startInView = convert(start, from: page)
                    let snapped = orthogonalSnapPoint(anchor: startInView, current: locationInView)
                    endInPage = snapPointInPageIfNeeded(convert(snapped, to: page), on: page)
                } else {
                    endInPage = pointInPage
                }
                addLineAnnotation(from: start, to: endInPage, on: page, actionName: "Add Line", contents: "Line")
                clearPendingLine()
            }
            let previewPoint = snapPointInViewIfNeeded(locationInView, on: page)
            updateLinePreview(at: previewPoint, orthogonal: ortho)
            return
        case .polyline:
            if inlineTextField != nil {
                _ = commitInlineTextEditor(cancel: false)
            }
            guard let page = page(for: locationInView, nearest: true) else {
                super.mouseDown(with: event)
                return
            }
            let ortho = isOrthoConstraintActive(for: event)
            let pointInPage = snapPointInPageIfNeeded(convert(locationInView, to: page), on: page)
            let constrainedPointInPage: NSPoint
            if ortho,
               pendingPolylinePage === page,
               let last = pendingPolylinePointsInPage.last {
                let lastInView = convert(last, from: page)
                let currentInView = convert(pointInPage, from: page)
                constrainedPointInPage = snapPointInPageIfNeeded(convert(orthogonalSnapPoint(anchor: lastInView, current: currentInView), to: page), on: page)
            } else {
                constrainedPointInPage = pointInPage
            }
            if pendingPolylinePage == nil || pendingPolylinePage !== page {
                pendingPolylinePage = page
                pendingPolylinePointsInPage = [constrainedPointInPage]
            } else if event.clickCount >= 2, pendingPolylinePointsInPage.count >= 1 {
                pendingPolylinePointsInPage.append(constrainedPointInPage)
                _ = endPendingPolyline()
            } else {
                pendingPolylinePointsInPage.append(constrainedPointInPage)
            }
            typedDistanceBuffer = ""
            let previewPoint = snapPointInViewIfNeeded(locationInView, on: page)
            updatePolylinePreview(at: previewPoint, orthogonal: ortho)
        case .area:
            if inlineTextField != nil {
                _ = commitInlineTextEditor(cancel: false)
            }
            guard let page = page(for: locationInView, nearest: true) else {
                super.mouseDown(with: event)
                return
            }
            let pointInPage = snapPointInPageIfNeeded(convert(locationInView, to: page), on: page)
            let constrainedPointInPage: NSPoint
            if event.modifierFlags.contains(.shift),
               pendingAreaPage === page,
               let last = pendingAreaPointsInPage.last {
                let lastInView = convert(last, from: page)
                let currentInView = convert(pointInPage, from: page)
                constrainedPointInPage = snapPointInPageIfNeeded(convert(orthogonalSnapPoint(anchor: lastInView, current: currentInView), to: page), on: page)
            } else {
                constrainedPointInPage = pointInPage
            }
            if pendingAreaPage == nil || pendingAreaPage !== page {
                pendingAreaPage = page
                pendingAreaPointsInPage = [constrainedPointInPage]
            } else if event.clickCount >= 2, pendingAreaPointsInPage.count >= 2 {
                pendingAreaPointsInPage.append(constrainedPointInPage)
                _ = endPendingArea()
            } else {
                pendingAreaPointsInPage.append(constrainedPointInPage)
            }
            let previewPoint = snapPointInViewIfNeeded(locationInView, on: page)
            updateAreaPreview(at: previewPoint, orthogonal: event.modifierFlags.contains(.shift))
        case .cloud, .rectangle:
            if inlineTextField != nil {
                _ = commitInlineTextEditor(cancel: false)
            }
            guard let page = page(for: locationInView, nearest: true) else {
                super.mouseDown(with: event)
                return
            }
            let snappedLocationInView = snapPointInViewIfNeeded(locationInView, on: page)
            dragStartInView = snappedLocationInView
            dragPage = page
            dragPreviewLayer.isHidden = false
            dragPreviewLayer.path = CGPath(rect: NSRect(origin: snappedLocationInView, size: .zero), transform: nil)
        case .text:
            hideTextPreview()
            if let page = page(for: locationInView, nearest: true) {
                beginInlineTextEditing(at: snapPointInViewIfNeeded(locationInView, on: page))
            } else {
                beginInlineTextEditing(at: locationInView)
            }
        case .callout:
            return
        case .measure, .calibrate:
            if inlineTextField != nil {
                _ = commitInlineTextEditor(cancel: false)
            }
            guard let page = page(for: locationInView, nearest: true) else {
                super.mouseDown(with: event)
                return
            }
            if toolMode == .measure {
                let pointInPage = snapPointInPageIfNeeded(convert(locationInView, to: page), on: page)
                if let startPage = pendingMeasurePage,
                   let start = pendingMeasureStartInPage,
                   startPage == page {
                    addMeasurementAnnotation(from: start, to: pointInPage, on: page)
                    pendingMeasurePage = nil
                    pendingMeasureStartInPage = nil
                    dragPreviewLayer.isHidden = true
                    dragPreviewLayer.path = nil
                } else {
                    pendingMeasurePage = page
                    pendingMeasureStartInPage = pointInPage
                    let startInView = convert(pointInPage, from: page)
                    let path = CGMutablePath()
                    path.move(to: startInView)
                    path.addLine(to: startInView)
                    dragPreviewLayer.strokeColor = measurementStrokeColor.cgColor
                    dragPreviewLayer.fillColor = NSColor.clear.cgColor
                    dragPreviewLayer.lineWidth = measurementLineWidth
                    dragPreviewLayer.path = path
                    dragPreviewLayer.isHidden = false
                }
            } else {
                let snappedLocationInView = snapPointInViewIfNeeded(locationInView, on: page)
                dragStartInView = snappedLocationInView
                dragPage = page
                dragPreviewLayer.strokeColor = calibrationStrokeColor.cgColor
                dragPreviewLayer.fillColor = NSColor.clear.cgColor
                dragPreviewLayer.lineWidth = measurementLineWidth
                dragPreviewLayer.path = CGPath(rect: NSRect(origin: snappedLocationInView, size: .zero), transform: nil)
                dragPreviewLayer.isHidden = false
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        lastPointerInView = convert(event.locationInWindow, from: nil)
        updateTypedDistanceHUD()
        if isRegionCaptureModeEnabled {
            guard let start = regionCaptureStartInView else { return }
            let current = convert(event.locationInWindow, from: nil)
            let rect = normalizedRect(from: start, to: current)
            dragPreviewLayer.path = CGPath(rect: rect, transform: nil)
            return
        }
        if toolMode == .select {
            if let start = fenceStartInView {
                let current = convert(event.locationInWindow, from: nil)
                let rect = normalizedRect(from: start, to: current)
                dragPreviewLayer.path = CGPath(rect: rect, transform: nil)
                return
            }
            if var calloutState = movingCalloutState {
                let locationInView = convert(event.locationInWindow, from: nil)
                let currentPoint = convert(locationInView, to: calloutState.page)
                let minSize = minimumResizeSize(for: calloutState.textAnnotation)
                var nextTextBounds = calloutState.startTextBounds
                var nextElbow = calloutState.startElbow
                var nextTip = calloutState.startTip
                switch calloutState.handle {
                case .moveAll:
                    let dx = currentPoint.x - calloutState.startPointerInPage.x
                    let dy = currentPoint.y - calloutState.startPointerInPage.y
                    if abs(dx) < 0.01, abs(dy) < 0.01 { return }
                    nextTextBounds = calloutState.startTextBounds.offsetBy(dx: dx, dy: dy)
                    nextElbow = NSPoint(x: calloutState.startElbow.x + dx, y: calloutState.startElbow.y + dy)
                    nextTip = NSPoint(x: calloutState.startTip.x + dx, y: calloutState.startTip.y + dy)
                case .tip:
                    nextTip = currentPoint
                case .elbow:
                    nextElbow = currentPoint
                case let .textCorner(corner):
                    var minX = calloutState.startTextBounds.minX
                    var minY = calloutState.startTextBounds.minY
                    var maxX = calloutState.startTextBounds.maxX
                    var maxY = calloutState.startTextBounds.maxY
                    switch corner {
                    case .lowerLeft:
                        minX = min(currentPoint.x, maxX - minSize.width)
                        minY = min(currentPoint.y, maxY - minSize.height)
                    case .lowerRight:
                        maxX = max(currentPoint.x, minX + minSize.width)
                        minY = min(currentPoint.y, maxY - minSize.height)
                    case .upperLeft:
                        minX = min(currentPoint.x, maxX - minSize.width)
                        maxY = max(currentPoint.y, minY + minSize.height)
                    case .upperRight:
                        maxX = max(currentPoint.x, minX + minSize.width)
                        maxY = max(currentPoint.y, minY + minSize.height)
                    }
                    nextTextBounds = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                }

                calloutState.textAnnotation.bounds = nextTextBounds
                replaceCalloutLeader(
                    state: &calloutState,
                    elbow: nextElbow,
                    tip: nextTip
                )
                movingCalloutState = calloutState
                didMoveAnnotation = true
                needsDisplay = true
                onViewportChanged?()
                return
            }
            guard let annotation = movingAnnotation,
                  let page = movingAnnotationPage,
                  let startBounds = movingAnnotationStartBounds,
                  let startPoint = movingStartPointInPage else {
                return
            }

            let locationInView = convert(event.locationInWindow, from: nil)
            let currentPoint = convert(locationInView, to: page)
            if let resizeCorner = movingResizeCorner {
                let minSize = minimumResizeSize(for: annotation)
                var minX = startBounds.minX
                var minY = startBounds.minY
                var maxX = startBounds.maxX
                var maxY = startBounds.maxY
                switch resizeCorner {
                case .lowerLeft:
                    minX = min(currentPoint.x, maxX - minSize.width)
                    minY = min(currentPoint.y, maxY - minSize.height)
                case .lowerRight:
                    maxX = max(currentPoint.x, minX + minSize.width)
                    minY = min(currentPoint.y, maxY - minSize.height)
                case .upperLeft:
                    minX = min(currentPoint.x, maxX - minSize.width)
                    maxY = max(currentPoint.y, minY + minSize.height)
                case .upperRight:
                    maxX = max(currentPoint.x, minX + minSize.width)
                    maxY = max(currentPoint.y, minY + minSize.height)
                }
                let resized = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                if abs(resized.width - annotation.bounds.width) > 0.01 || abs(resized.height - annotation.bounds.height) > 0.01 || abs(resized.origin.x - annotation.bounds.origin.x) > 0.01 || abs(resized.origin.y - annotation.bounds.origin.y) > 0.01 {
                    didMoveAnnotation = true
                    annotation.bounds = resized
                    needsDisplay = true
                    onViewportChanged?()
                }
                return
            }
            let dx = currentPoint.x - startPoint.x
            let dy = currentPoint.y - startPoint.y
            if abs(dx) < 0.01, abs(dy) < 0.01 {
                return
            }
            didMoveAnnotation = true
            if movingAnnotations.count > 1 {
                for candidate in movingAnnotations {
                    let key = ObjectIdentifier(candidate)
                    guard let base = movingAnnotationStartBoundsByID[key] else { continue }
                    candidate.bounds = base.offsetBy(dx: dx, dy: dy)
                }
            } else {
                annotation.bounds = startBounds.offsetBy(dx: dx, dy: dy)
            }
            needsDisplay = true
            onViewportChanged?()
            return
        }

        if toolMode == .polyline {
            let locationInView = convert(event.locationInWindow, from: nil)
            let ortho = isOrthoConstraintActive(for: event)
            if let page = pendingPolylinePage {
                updatePolylinePreview(at: snapPointInViewIfNeeded(locationInView, on: page), orthogonal: ortho)
            } else {
                updatePolylinePreview(at: locationInView, orthogonal: ortho)
            }
            return
        }
        if toolMode == .arrow {
            let locationInView = convert(event.locationInWindow, from: nil)
            if let page = pendingArrowPage {
                updateArrowPreview(at: snapPointInViewIfNeeded(locationInView, on: page), orthogonal: event.modifierFlags.contains(.shift))
            } else {
                updateArrowPreview(at: locationInView, orthogonal: event.modifierFlags.contains(.shift))
            }
            return
        }
        if toolMode == .line {
            let locationInView = convert(event.locationInWindow, from: nil)
            let ortho = isOrthoConstraintActive(for: event)
            if let page = pendingLinePage {
                updateLinePreview(at: snapPointInViewIfNeeded(locationInView, on: page), orthogonal: ortho)
            } else {
                updateLinePreview(at: locationInView, orthogonal: ortho)
            }
            return
        }
        if toolMode == .area {
            let locationInView = convert(event.locationInWindow, from: nil)
            if let page = pendingAreaPage {
                updateAreaPreview(at: snapPointInViewIfNeeded(locationInView, on: page), orthogonal: event.modifierFlags.contains(.shift))
            } else {
                updateAreaPreview(at: locationInView, orthogonal: event.modifierFlags.contains(.shift))
            }
            return
        }

        guard (toolMode == .pen || toolMode == .highlighter || toolMode == .cloud || toolMode == .rectangle || toolMode == .calibrate || toolMode == .grab) else {
            super.mouseDragged(with: event)
            return
        }

        if toolMode == .pen || toolMode == .highlighter {
            guard let page = penPage else { return }
            let rawCurrent = convert(event.locationInWindow, from: nil)
            let isOrthogonal = event.modifierFlags.contains(.shift)
            let firstPagePoint = penPointsPage.first ?? convert(rawCurrent, to: page)
            let firstViewPoint = convert(firstPagePoint, from: page)

            if isOrthogonal {
                let snapped = orthogonalSnapPoint(anchor: firstViewPoint, current: rawCurrent)
                penPointsPage = [firstPagePoint, convert(snapped, to: page)]
                let path = CGMutablePath()
                path.move(to: firstViewPoint)
                path.addLine(to: snapped)
                penPreviewPath = path
            } else {
                let last = penLastPointInView ?? rawCurrent
                let dx = rawCurrent.x - last.x
                let dy = rawCurrent.y - last.y
                let distance = hypot(dx, dy)
                let steps = max(1, Int(distance / 4.0))
                for step in 1...steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    let pointInView = NSPoint(x: last.x + dx * t, y: last.y + dy * t)
                    penPointsPage.append(convert(pointInView, to: page))
                    penPreviewPath?.addLine(to: pointInView)
                }
            }
            penLastPointInView = rawCurrent

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let strokeColor = (toolMode == .highlighter) ? highlighterColor : penColor
            let strokeWidth = (toolMode == .highlighter) ? highlighterLineWidth : penLineWidth
            dragPreviewLayer.strokeColor = strokeColor.cgColor
            dragPreviewLayer.fillColor = NSColor.clear.cgColor
            dragPreviewLayer.lineWidth = strokeWidth
            dragPreviewLayer.path = penPreviewPath
            CATransaction.commit()
            return
        } else if toolMode == .cloud || toolMode == .rectangle || toolMode == .grab {
            let rawCurrent = convert(event.locationInWindow, from: nil)
            guard let start = dragStartInView else { return }
            let current: NSPoint
            if (toolMode == .cloud || toolMode == .rectangle),
               let page = dragPage {
                current = snapPointInViewIfNeeded(rawCurrent, on: page)
            } else {
                current = rawCurrent
            }
            let rect = normalizedRect(from: start, to: current)
            if toolMode == .grab {
                dragPreviewLayer.strokeColor = NSColor.controlAccentColor.cgColor
                dragPreviewLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
                dragPreviewLayer.lineWidth = 1.5
                dragPreviewLayer.lineDashPattern = [6, 4]
            } else {
                dragPreviewLayer.strokeColor = (toolMode == .cloud ? NSColor.systemCyan : rectangleStrokeColor).cgColor
                dragPreviewLayer.fillColor = (toolMode == .cloud ? NSColor.clear.cgColor : rectangleFillColor.cgColor)
            }
            dragPreviewLayer.path = CGPath(rect: rect, transform: nil)
        } else {
            let rawCurrent = convert(event.locationInWindow, from: nil)
            guard let start = dragStartInView else { return }
            let current: NSPoint
            if let page = dragPage {
                current = snapPointInViewIfNeeded(rawCurrent, on: page)
            } else {
                current = rawCurrent
            }
            let path = CGMutablePath()
            path.move(to: start)
            path.addLine(to: current)
            dragPreviewLayer.strokeColor = calibrationStrokeColor.cgColor
            dragPreviewLayer.fillColor = NSColor.clear.cgColor
            dragPreviewLayer.lineWidth = measurementLineWidth
            dragPreviewLayer.path = path
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isRegionCaptureModeEnabled {
            defer {
                regionCaptureStartInView = nil
                regionCapturePage = nil
                dragPreviewLayer.isHidden = true
                dragPreviewLayer.path = nil
                dragPreviewLayer.lineDashPattern = nil
            }
            guard let startInView = regionCaptureStartInView,
                  let page = regionCapturePage else { return }
            let endInView = convert(event.locationInWindow, from: nil)
            let startInPage = convert(startInView, to: page)
            let endInPage = convert(endInView, to: page)
            let rectInPage = normalizedRect(from: startInPage, to: endInPage)
            guard rectInPage.width > 2, rectInPage.height > 2 else {
                NSSound.beep()
                return
            }
            cancelRegionCaptureMode()
            onRegionCaptured?(page, rectInPage)
            return
        }
        defer {
            dragStartInView = nil
            dragPage = nil
            penPage = nil
            penPointsPage = []
            penPreviewPath = nil
            penLastPointInView = nil
            movingAnnotation = nil
            movingAnnotationPage = nil
            movingAnnotationStartBounds = nil
            movingStartPointInPage = nil
            movingResizeCorner = nil
            movingCalloutState = nil
            movingAnnotations = []
            movingAnnotationStartBoundsByID.removeAll(keepingCapacity: false)
            didMoveAnnotation = false
            fenceStartInView = nil
            fencePage = nil
            if (toolMode != .measure || pendingMeasureStartInPage == nil) &&
                !(toolMode == .arrow && pendingArrowStartInPage != nil) &&
                !(toolMode == .line && pendingLineStartInPage != nil) &&
                !(toolMode == .polyline && !pendingPolylinePointsInPage.isEmpty) &&
                !(toolMode == .area && !pendingAreaPointsInPage.isEmpty) {
                dragPreviewLayer.isHidden = true
                dragPreviewLayer.path = nil
            }
            dragPreviewLayer.lineDashPattern = nil
        }

        if toolMode == .select {
            if let start = fenceStartInView, let page = fencePage {
                let end = convert(event.locationInWindow, from: nil)
                let rectInView = normalizedRect(from: start, to: end)
                guard rectInView.width > 4, rectInView.height > 4 else {
                    onAnnotationsBoxSelected?(page, [])
                    return
                }
                let p1 = convert(rectInView.origin, to: page)
                let p2 = convert(NSPoint(x: rectInView.maxX, y: rectInView.maxY), to: page)
                let box = normalizedRect(from: p1, to: p2)
                let hits = page.annotations.filter { $0.bounds.intersects(box) }
                onAnnotationsBoxSelected?(page, hits)
                return
            }
            if didMoveAnnotation, let calloutState = movingCalloutState {
                onAnnotationMoved?(calloutState.page, calloutState.textAnnotation, calloutState.startTextBounds)
                return
            }
            guard didMoveAnnotation, let page = movingAnnotationPage else { return }
            if !movingAnnotations.isEmpty {
                for annotation in movingAnnotations {
                    let key = ObjectIdentifier(annotation)
                    guard let startBounds = movingAnnotationStartBoundsByID[key] else { continue }
                    onAnnotationMoved?(page, annotation, startBounds)
                }
                return
            }
            guard let annotation = movingAnnotation,
                  let startBounds = movingAnnotationStartBounds else { return }
            onAnnotationMoved?(page, annotation, startBounds)
            return
        }

        if toolMode == .pen || toolMode == .highlighter {
            guard let page = penPage, penPointsPage.count >= 2 else { return }
            let strokeWidth = (toolMode == .highlighter) ? highlighterLineWidth : penLineWidth
            let simplifyTolerance = max(0.9, strokeWidth * 0.08)
            let simplifiedPoints = simplifyPolyline(penPointsPage, tolerance: simplifyTolerance)
            guard simplifiedPoints.count >= 2 else { return }

            let xs = simplifiedPoints.map(\.x)
            let ys = simplifiedPoints.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
            let inkBounds = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -4, dy: -4)
            let localPath = NSBezierPath()
            for (idx, point) in simplifiedPoints.enumerated() {
                let local = NSPoint(x: point.x - inkBounds.origin.x, y: point.y - inkBounds.origin.y)
                if idx == 0 {
                    localPath.move(to: local)
                } else {
                    localPath.line(to: local)
                }
            }

            let annotation = PDFAnnotation(bounds: inkBounds, forType: .ink, withProperties: nil)
            let strokeColor = (toolMode == .highlighter) ? highlighterColor : penColor
            annotation.color = strokeColor
            localPath.lineWidth = strokeWidth
            assignLineWidth(strokeWidth, to: annotation)
            annotation.contents = (toolMode == .highlighter) ? "Highlighter" : "Pen"
            annotation.add(localPath)
            page.addAnnotation(annotation)
            onAnnotationAdded?(page, annotation, (toolMode == .highlighter) ? "Add Highlighter" : "Add Pen")
            return
        }

        if toolMode == .grab,
           let start = dragStartInView,
           let page = dragPage {
            let end = convert(event.locationInWindow, from: nil)
            let rectInView = normalizedRect(from: start, to: end)
            guard rectInView.width > 4, rectInView.height > 4 else { return }
            let p1 = convert(rectInView.origin, to: page)
            let p2 = convert(NSPoint(x: rectInView.maxX, y: rectInView.maxY), to: page)
            let pageRect = normalizedRect(from: p1, to: p2)
            if let snapshotData = captureSnapshotVectorData(on: page, in: pageRect) {
                onSnapshotCaptured?(snapshotData, pageRect)
            }
            return
        }

        guard (toolMode == .cloud || toolMode == .rectangle || toolMode == .calibrate),
              let start = dragStartInView,
              let page = dragPage else {
            super.mouseUp(with: event)
            return
        }

        let rawEnd = convert(event.locationInWindow, from: nil)
        let end = snapPointInViewIfNeeded(rawEnd, on: page)
        if toolMode == .calibrate {
            let p1 = convert(start, to: page)
            let p2 = convert(end, to: page)
            let distance = hypot(p2.x - p1.x, p2.y - p1.y)
            guard distance > 4 else { return }
            onCalibrationDistanceMeasured?(distance)
            return
        }

        let rectInView = normalizedRect(from: start, to: end)
        guard rectInView.width > 4, rectInView.height > 4 else { return }

        let p1 = convert(rectInView.origin, to: page)
        let p2 = convert(NSPoint(x: rectInView.maxX, y: rectInView.maxY), to: page)
        let annotationRect = normalizedRect(from: p1, to: p2)

        if toolMode == .cloud {
            addCloudAnnotation(on: page, in: annotationRect)
            return
        }

        let annotation = PDFAnnotation(bounds: annotationRect, forType: .square, withProperties: nil)
        annotation.color = rectangleStrokeColor
        annotation.interiorColor = rectangleFillColor
        assignLineWidth(rectangleLineWidth, to: annotation)
        page.addAnnotation(annotation)
        onAnnotationAdded?(page, annotation, "Add Rectangle")
    }

    private func addLineAnnotation(from start: NSPoint, to end: NSPoint, on page: PDFPage, actionName: String, contents: String) {
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance > 1.0 else { return }

        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxX = max(start.x, end.x)
        let maxY = max(start.y, end.y)
        let pad = max(4.0, penLineWidth * 0.5)
        let bounds = NSRect(x: minX - pad, y: minY - pad, width: (maxX - minX) + pad * 2.0, height: (maxY - minY) + pad * 2.0)

        let localPath = NSBezierPath()
        localPath.move(to: NSPoint(x: start.x - bounds.origin.x, y: start.y - bounds.origin.y))
        localPath.line(to: NSPoint(x: end.x - bounds.origin.x, y: end.y - bounds.origin.y))

        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        annotation.color = penColor
        localPath.lineWidth = penLineWidth
        assignLineWidth(penLineWidth, to: annotation)
        annotation.contents = contents
        annotation.add(localPath)
        page.addAnnotation(annotation)
        onAnnotationAdded?(page, annotation, actionName)
    }

    private func addArrowAnnotation(from start: NSPoint, to end: NSPoint, on page: PDFPage) {
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance > 1.0 else { return }

        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxX = max(start.x, end.x)
        let maxY = max(start.y, end.y)
        let pad = max(6.0, arrowLineWidth * 2.5)
        let bounds = NSRect(x: minX - pad, y: minY - pad, width: (maxX - minX) + pad * 2.0, height: (maxY - minY) + pad * 2.0)

        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let localStart = NSPoint(x: start.x - bounds.origin.x, y: start.y - bounds.origin.y)
        let localEnd = NSPoint(x: end.x - bounds.origin.x, y: end.y - bounds.origin.y)
        path.move(to: localStart)
        path.line(to: localEnd)
        addArrowDecoration(
            to: path,
            tip: localEnd,
            from: localStart,
            style: calloutArrowStyle,
            lineWidth: arrowLineWidth,
            headSize: arrowHeadSize
        )

        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        annotation.color = arrowStrokeColor
        path.lineWidth = arrowLineWidth
        assignLineWidth(arrowLineWidth, to: annotation)
        annotation.contents = "Arrow|Style:\(calloutArrowStyle.rawValue)|Head:\(encodedHeadSize(arrowHeadSize))"
        annotation.add(path)
        page.addAnnotation(annotation)
        onAnnotationAdded?(page, annotation, "Add Arrow")
        if let endpoint = makeArrowEndpointAnnotation(
            tip: end,
            style: calloutArrowStyle,
            lineWidth: arrowLineWidth,
            strokeColor: arrowStrokeColor,
            headSize: arrowHeadSize,
            groupID: nil,
            isCallout: false
        ) {
            page.addAnnotation(endpoint)
            onAnnotationAdded?(page, endpoint, "Add Arrow")
        }
    }

    private func assignLineWidth(_ lineWidth: CGFloat, to annotation: PDFAnnotation) {
        let normalized = max(0.0, lineWidth)
        let border = annotation.border ?? PDFBorder()
        border.lineWidth = normalized
        annotation.border = border
    }

    private func simplifyPolyline(_ points: [NSPoint], tolerance: CGFloat) -> [NSPoint] {
        guard points.count > 2 else { return points }
        let epsilon = max(0.1, tolerance)

        var keep = Array(repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        func perpendicularDistance(_ point: NSPoint, _ lineStart: NSPoint, _ lineEnd: NSPoint) -> CGFloat {
            let dx = lineEnd.x - lineStart.x
            let dy = lineEnd.y - lineStart.y
            let lengthSquared = dx * dx + dy * dy
            if lengthSquared <= 0.0001 {
                return hypot(point.x - lineStart.x, point.y - lineStart.y)
            }
            let t = max(0, min(1, ((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / lengthSquared))
            let projection = NSPoint(x: lineStart.x + t * dx, y: lineStart.y + t * dy)
            return hypot(point.x - projection.x, point.y - projection.y)
        }

        func simplifySegment(start: Int, end: Int) {
            guard end - start > 1 else { return }
            var maxDistance: CGFloat = 0
            var maxIndex = -1
            for i in (start + 1)..<end {
                let distance = perpendicularDistance(points[i], points[start], points[end])
                if distance > maxDistance {
                    maxDistance = distance
                    maxIndex = i
                }
            }
            guard maxIndex >= 0, maxDistance > epsilon else { return }
            keep[maxIndex] = true
            simplifySegment(start: start, end: maxIndex)
            simplifySegment(start: maxIndex, end: end)
        }

        simplifySegment(start: 0, end: points.count - 1)

        var simplified: [NSPoint] = []
        simplified.reserveCapacity(points.count / 2)
        for (index, point) in points.enumerated() where keep[index] {
            simplified.append(point)
        }
        return simplified.count >= 2 ? simplified : [points.first!, points.last!]
    }

    private func captureSnapshotVectorData(on page: PDFPage, in pageRect: NSRect) -> Data? {
        guard pageRect.width > 1, pageRect.height > 1 else { return nil }

        let buffer = NSMutableData()
        guard let consumer = CGDataConsumer(data: buffer as CFMutableData) else {
            return nil
        }

        var mediaBox = CGRect(origin: .zero, size: pageRect.size)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }

        context.beginPDFPage(nil)
        context.saveGState()
        context.translateBy(x: -pageRect.minX, y: -pageRect.minY)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()
        return buffer as Data
    }

    private func clearPendingPolyline() {
        pendingPolylinePage = nil
        pendingPolylinePointsInPage = []
        typedDistanceBuffer = ""
        hideTypedDistanceHUD()
        dragPreviewLayer.path = nil
        dragPreviewLayer.isHidden = true
    }

    func endPendingPolyline() -> Bool {
        let hadPending = pendingPolylinePage != nil || !pendingPolylinePointsInPage.isEmpty
        defer { clearPendingPolyline() }
        guard let page = pendingPolylinePage, pendingPolylinePointsInPage.count >= 2 else {
            return hadPending
        }
        for idx in 1..<pendingPolylinePointsInPage.count {
            addLineAnnotation(
                from: pendingPolylinePointsInPage[idx - 1],
                to: pendingPolylinePointsInPage[idx],
                on: page,
                actionName: "Add Polyline",
                contents: "Polyline"
            )
        }
        return true
    }

    func cancelPendingPolyline() {
        clearPendingPolyline()
    }

    private func updateLinePreview(at locationInView: NSPoint?, orthogonal: Bool) {
        guard toolMode == .line,
              let page = pendingLinePage,
              let start = pendingLineStartInPage else {
            return
        }
        let startInView = convert(start, from: page)
        let targetInView: NSPoint
        if let typedTarget = typedLengthPreviewTargetInView(
            on: page,
            from: start,
            fallbackLocationInView: locationInView,
            orthogonal: orthogonal
        ) {
            targetInView = typedTarget
        } else if let locationInView,
           self.page(for: locationInView, nearest: true) == page {
            targetInView = orthogonal ? orthogonalSnapPoint(anchor: startInView, current: locationInView) : locationInView
        } else {
            targetInView = startInView
        }

        let path = CGMutablePath()
        path.move(to: startInView)
        path.addLine(to: targetInView)
        dragPreviewLayer.strokeColor = penColor.cgColor
        dragPreviewLayer.fillColor = NSColor.clear.cgColor
        dragPreviewLayer.lineWidth = penLineWidth
        dragPreviewLayer.lineDashPattern = [6, 4]
        dragPreviewLayer.path = path
        dragPreviewLayer.isHidden = false
    }

    private func clearPendingLine() {
        pendingLinePage = nil
        pendingLineStartInPage = nil
        typedDistanceBuffer = ""
        hideTypedDistanceHUD()
        dragPreviewLayer.path = nil
        dragPreviewLayer.isHidden = true
    }

    func cancelPendingLine() {
        clearPendingLine()
    }

    private func parseFractionOrDecimal(_ raw: String) -> Double? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty { return nil }
        if let value = Double(token) {
            return value
        }
        let pieces = token.split(separator: "/")
        guard pieces.count == 2,
              let numerator = Double(pieces[0]),
              let denominator = Double(pieces[1]),
              denominator != 0 else {
            return nil
        }
        return numerator / denominator
    }

    private func parseLengthInCurrentUnit(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let normalized = text.replacingOccurrences(of: " ", with: "")
        if normalized.contains("'") || normalized.contains("\"") {
            let feetPart = normalized.split(separator: "'", maxSplits: 1, omittingEmptySubsequences: false)
            let feetValue = parseFractionOrDecimal(String(feetPart.first ?? "")) ?? 0
            var inchesValue = 0.0
            if feetPart.count > 1 {
                let afterFeet = String(feetPart[1]).replacingOccurrences(of: "\"", with: "")
                if !afterFeet.isEmpty {
                    if afterFeet.contains("-") {
                        let components = afterFeet.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                        let whole = parseFractionOrDecimal(String(components.first ?? "")) ?? 0
                        let frac = parseFractionOrDecimal(String(components.count > 1 ? components[1] : "")) ?? 0
                        inchesValue = whole + frac
                    } else {
                        inchesValue = parseFractionOrDecimal(afterFeet) ?? 0
                    }
                }
            }
            let feetTotal = feetValue + (inchesValue / 12.0)
            switch measurementUnitLabel {
            case "ft":
                return feetTotal
            case "in":
                return feetTotal * 12.0
            case "m":
                return feetTotal * 0.3048
            default:
                return feetTotal * 864.0
            }
        }

        if normalized.contains("-") {
            let components = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if components.count == 2,
               let feet = parseFractionOrDecimal(String(components[0])),
               let inches = parseFractionOrDecimal(String(components[1])) {
                let feetTotal = feet + (inches / 12.0)
                switch measurementUnitLabel {
                case "ft":
                    return feetTotal
                case "in":
                    return feetTotal * 12.0
                case "m":
                    return feetTotal * 0.3048
                default:
                    return feetTotal * 864.0
                }
            }
        }

        return parseFractionOrDecimal(normalized)
    }

    private func directionPointForTypedDistance(on page: PDFPage, from anchor: NSPoint, orthogonal: Bool) -> NSPoint {
        guard let pointerInView = lastPointerInView else {
            return NSPoint(x: anchor.x + 1.0, y: anchor.y)
        }
        let pointerPage = snapPointInPageIfNeeded(convert(pointerInView, to: page), on: page)
        if !orthogonal {
            return pointerPage
        }
        let dx = pointerPage.x - anchor.x
        let dy = pointerPage.y - anchor.y
        if abs(dx) >= abs(dy) {
            return NSPoint(x: pointerPage.x, y: anchor.y)
        }
        return NSPoint(x: anchor.x, y: pointerPage.y)
    }

    private func typedLengthPreviewTargetInView(
        on page: PDFPage,
        from anchor: NSPoint,
        fallbackLocationInView: NSPoint?,
        orthogonal: Bool
    ) -> NSPoint? {
        guard let lengthInUnits = parseLengthInCurrentUnit(typedDistanceBuffer),
              lengthInUnits > 0 else {
            return nil
        }
        let lengthInPoints = CGFloat(lengthInUnits) / max(0.0001, measurementUnitsPerPoint)
        let pointerInView = fallbackLocationInView ?? lastPointerInView ?? convert(anchor, from: page)
        let pointerPage = snapPointInPageIfNeeded(convert(pointerInView, to: page), on: page)
        let toward: NSPoint
        if orthogonal {
            let dx = pointerPage.x - anchor.x
            let dy = pointerPage.y - anchor.y
            if abs(dx) >= abs(dy) {
                toward = NSPoint(x: pointerPage.x, y: anchor.y)
            } else {
                toward = NSPoint(x: anchor.x, y: pointerPage.y)
            }
        } else {
            toward = pointerPage
        }

        var dx = toward.x - anchor.x
        var dy = toward.y - anchor.y
        let magnitude = hypot(dx, dy)
        if magnitude < 0.001 {
            dx = 1
            dy = 0
        } else {
            dx /= magnitude
            dy /= magnitude
        }
        let targetInPage = NSPoint(x: anchor.x + dx * lengthInPoints, y: anchor.y + dy * lengthInPoints)
        return convert(targetInPage, from: page)
    }

    private func refreshTypedDistancePreview(orthogonal: Bool) {
        updateTypedDistanceHUD()
        switch toolMode {
        case .line:
            if let page = pendingLinePage {
                let pointer = lastPointerInView.map { snapPointInViewIfNeeded($0, on: page) }
                updateLinePreview(at: pointer, orthogonal: orthogonal)
            }
        case .polyline:
            if let page = pendingPolylinePage, !pendingPolylinePointsInPage.isEmpty {
                let pointer = lastPointerInView.map { snapPointInViewIfNeeded($0, on: page) }
                updatePolylinePreview(at: pointer, orthogonal: orthogonal)
            }
        default:
            break
        }
    }

    private func commitTypedDistanceIfPossible(orthogonal: Bool) -> Bool {
        guard !typedDistanceBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let lengthInUnits = parseLengthInCurrentUnit(typedDistanceBuffer),
              lengthInUnits > 0 else {
            NSSound.beep()
            return false
        }
        let lengthInPoints = CGFloat(lengthInUnits) / max(0.0001, measurementUnitsPerPoint)

        if toolMode == .line,
           let page = pendingLinePage,
           let start = pendingLineStartInPage {
            let toward = directionPointForTypedDistance(on: page, from: start, orthogonal: orthogonal)
            var dx = toward.x - start.x
            var dy = toward.y - start.y
            let magnitude = hypot(dx, dy)
            if magnitude < 0.001 {
                dx = 1
                dy = 0
            } else {
                dx /= magnitude
                dy /= magnitude
            }
            let end = NSPoint(x: start.x + dx * lengthInPoints, y: start.y + dy * lengthInPoints)
            addLineAnnotation(from: start, to: end, on: page, actionName: "Add Line", contents: "Line")
            clearPendingLine()
            return true
        }

        if toolMode == .polyline,
           let page = pendingPolylinePage,
           let anchor = pendingPolylinePointsInPage.last {
            let toward = directionPointForTypedDistance(on: page, from: anchor, orthogonal: orthogonal)
            var dx = toward.x - anchor.x
            var dy = toward.y - anchor.y
            let magnitude = hypot(dx, dy)
            if magnitude < 0.001 {
                dx = 1
                dy = 0
            } else {
                dx /= magnitude
                dy /= magnitude
            }
            let next = NSPoint(x: anchor.x + dx * lengthInPoints, y: anchor.y + dy * lengthInPoints)
            pendingPolylinePointsInPage.append(next)
            typedDistanceBuffer = ""
            updatePolylinePreview(at: lastPointerInView, orthogonal: orthogonal)
            return true
        }

        return false
    }

    private func updateArrowPreview(at locationInView: NSPoint?, orthogonal: Bool) {
        guard toolMode == .arrow,
              let page = pendingArrowPage,
              let start = pendingArrowStartInPage else {
            return
        }
        let startInView = convert(start, from: page)
        let targetInView: NSPoint
        if let locationInView,
           self.page(for: locationInView, nearest: true) == page {
            let snappedCurrent = snapPointInViewIfNeeded(locationInView, on: page)
            if orthogonal {
                let orthogonalPoint = orthogonalSnapPoint(anchor: startInView, current: snappedCurrent)
                targetInView = snapPointInViewIfNeeded(orthogonalPoint, on: page)
            } else {
                targetInView = snappedCurrent
            }
        } else {
            targetInView = startInView
        }

        let path = NSBezierPath()
        path.move(to: startInView)
        path.line(to: targetInView)
        addArrowDecoration(
            to: path,
            tip: targetInView,
            from: startInView,
            style: calloutArrowStyle,
            lineWidth: arrowLineWidth,
            headSize: arrowHeadSize
        )

        dragPreviewLayer.strokeColor = arrowStrokeColor.cgColor
        dragPreviewLayer.fillColor = NSColor.clear.cgColor
        dragPreviewLayer.lineWidth = arrowLineWidth
        dragPreviewLayer.lineDashPattern = [6, 4]
        dragPreviewLayer.path = cgPath(from: path)
        dragPreviewLayer.isHidden = false
    }

    private func clearPendingArrow() {
        pendingArrowPage = nil
        pendingArrowStartInPage = nil
        typedDistanceBuffer = ""
        hideTypedDistanceHUD()
        dragPreviewLayer.path = nil
        dragPreviewLayer.isHidden = true
    }

    func cancelPendingArrow() {
        clearPendingArrow()
    }

    private func updateAreaPreview(at locationInView: NSPoint?, orthogonal: Bool) {
        guard toolMode == .area,
              let page = pendingAreaPage,
              !pendingAreaPointsInPage.isEmpty else {
            return
        }

        let path = CGMutablePath()
        let first = convert(pendingAreaPointsInPage[0], from: page)
        path.move(to: first)
        for point in pendingAreaPointsInPage.dropFirst() {
            path.addLine(to: convert(point, from: page))
        }
        if let locationInView,
           self.page(for: locationInView, nearest: true) == page {
            if orthogonal, let last = pendingAreaPointsInPage.last {
                let lastInView = convert(last, from: page)
                path.addLine(to: orthogonalSnapPoint(anchor: lastInView, current: locationInView))
            } else {
                path.addLine(to: locationInView)
            }
        }

        dragPreviewLayer.strokeColor = penColor.cgColor
        dragPreviewLayer.fillColor = penColor.withAlphaComponent(0.12).cgColor
        dragPreviewLayer.lineWidth = areaLineWidth
        dragPreviewLayer.lineDashPattern = [5, 4]
        dragPreviewLayer.path = path
        dragPreviewLayer.isHidden = false
    }

    private func clearPendingArea() {
        pendingAreaPage = nil
        pendingAreaPointsInPage = []
        typedDistanceBuffer = ""
        hideTypedDistanceHUD()
        dragPreviewLayer.path = nil
        dragPreviewLayer.isHidden = true
    }

    func endPendingArea() -> Bool {
        let hadPending = pendingAreaPage != nil || !pendingAreaPointsInPage.isEmpty
        defer { clearPendingArea() }
        guard let page = pendingAreaPage, pendingAreaPointsInPage.count >= 3 else {
            return hadPending
        }

        let points = pendingAreaPointsInPage
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return hadPending
        }
        let pad = max(6.0, areaLineWidth * 0.6)
        let bounds = NSRect(x: minX - pad, y: minY - pad, width: (maxX - minX) + pad * 2.0, height: (maxY - minY) + pad * 2.0)

        let polygonPath = NSBezierPath()
        polygonPath.move(to: NSPoint(x: points[0].x - bounds.origin.x, y: points[0].y - bounds.origin.y))
        for point in points.dropFirst() {
            polygonPath.line(to: NSPoint(x: point.x - bounds.origin.x, y: point.y - bounds.origin.y))
        }
        polygonPath.close()

        let areaAnnotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        areaAnnotation.color = penColor
        polygonPath.lineWidth = areaLineWidth
        assignLineWidth(areaLineWidth, to: areaAnnotation)
        areaAnnotation.contents = "Area"
        areaAnnotation.add(polygonPath)
        page.addAnnotation(areaAnnotation)
        onAnnotationAdded?(page, areaAnnotation, "Add Area")

        let areaPoints = polygonAreaInPointsSquared(points: points)
        let scaledArea = areaPoints * measurementUnitsPerPoint * measurementUnitsPerPoint
        let centroid = polygonCentroid(points: points) ?? points[0]
        let labelBounds = NSRect(x: centroid.x - 72, y: centroid.y - 12, width: 144, height: 24)
        let label = PDFAnnotation(bounds: labelBounds, forType: .freeText, withProperties: nil)
        label.contents = "Area: \(formatAreaValue(scaledArea)) \(measurementUnitLabel)\u{00B2}"
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.fontColor = penColor
        label.color = NSColor.white.withAlphaComponent(0.88)
        forceUprightTextAnnotationIfSupported(label, on: page)
        page.addAnnotation(label)
        onAnnotationAdded?(page, label, "Add Area Label")
        return true
    }

    func cancelPendingArea() {
        clearPendingArea()
    }

    private func polygonAreaInPointsSquared(points: [NSPoint]) -> CGFloat {
        guard points.count >= 3 else { return 0 }
        var sum: CGFloat = 0
        for idx in 0..<points.count {
            let a = points[idx]
            let b = points[(idx + 1) % points.count]
            sum += (a.x * b.y) - (b.x * a.y)
        }
        return abs(sum) * 0.5
    }

    private func polygonCentroid(points: [NSPoint]) -> NSPoint? {
        guard points.count >= 3 else { return nil }
        var signedArea: CGFloat = 0
        var cx: CGFloat = 0
        var cy: CGFloat = 0
        for idx in 0..<points.count {
            let a = points[idx]
            let b = points[(idx + 1) % points.count]
            let cross = (a.x * b.y) - (b.x * a.y)
            signedArea += cross
            cx += (a.x + b.x) * cross
            cy += (a.y + b.y) * cross
        }
        guard abs(signedArea) > 0.0001 else { return nil }
        signedArea *= 0.5
        return NSPoint(x: cx / (6.0 * signedArea), y: cy / (6.0 * signedArea))
    }

    private func formatAreaValue(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }

    func addHighlightForCurrentSelection() {
        guard let selection = currentSelection else {
            NSSound.beep()
            return
        }

        let pages = selection.pages
        for page in pages {
            let pageSelections = selection.selectionsByLine()
            for lineSelection in pageSelections {
                let bounds = lineSelection.bounds(for: page)
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = NSColor.systemYellow.withAlphaComponent(0.45)
                page.addAnnotation(annotation)
                onAnnotationAdded?(page, annotation, "Add Highlight")
            }
        }

        self.setCurrentSelection(nil, animate: false)
    }

    private func beginInlineTextEditing(at locationInView: NSPoint) {
        _ = commitInlineTextEditor(cancel: false)

        guard let page = page(for: locationInView, nearest: true) else {
            NSSound.beep()
            return
        }

        let field = NSTextField(frame: .zero)
        let resolvedFont = NSFont(name: textFontName, size: max(6.0, textFontSize))
            ?? NSFont.systemFont(ofSize: max(6.0, textFontSize), weight: .regular)
        field.font = inlineEditorDisplayFont(from: resolvedFont)
        field.textColor = textForegroundColor
        field.drawsBackground = true
        field.backgroundColor = textBackgroundColor
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.delegate = self
        field.placeholderString = nil
        configureInlineEditorField(field)

        addSubview(field)
        inlineTextField = field
        inlineTextPage = page
        inlineTextAnchorInPage = convert(locationInView, to: page)
        inlineEditingExistingAnnotation = false
        inlineOriginalTextContents = nil

        let anchor = inlineTextAnchorInPage!
        let bounds = calloutTextAnnotationBounds(forAnchorInPage: anchor, on: page)
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = " "
        annotation.font = resolvedFont
        annotation.fontColor = textForegroundColor
        applyTextBoxStyle(to: annotation)
        annotation.alignment = .left
        forceUprightTextAnnotationIfSupported(annotation, on: page)
        if toolMode == .callout, let calloutGroupID = pendingCalloutGroupID {
            annotation.userName = Self.calloutGroupPrefix + calloutGroupID
        } else {
            annotation.userName = Self.textGroupPrefix + UUID().uuidString
        }
        page.addAnnotation(annotation)
        inlineLiveTextAnnotation = annotation
        inlineAnnotationWasDisplayed = annotation.shouldDisplay
        annotation.shouldDisplay = false
        field.frame = inlineEditorFrame(for: annotation, on: page)
        startTextEditCaretBlink(for: annotation, page: page)

        window?.makeFirstResponder(field)
    }

    private func beginInlineTextEditing(for annotation: PDFAnnotation, on page: PDFPage) {
        _ = commitInlineTextEditor(cancel: false)
        guard isEditableTextAnnotation(annotation) else {
            NSSound.beep()
            return
        }

        let field = NSTextField(frame: .zero)
        let size = max(6.0, annotation.font?.pointSize ?? textFontSize)
        let resolvedFont = NSFont(name: textFontName, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .regular)
        field.font = inlineEditorDisplayFont(from: resolvedFont)
        field.textColor = annotation.fontColor ?? textForegroundColor
        field.drawsBackground = true
        field.backgroundColor = resolvedTextBackgroundColor(for: annotation)
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.delegate = self
        field.stringValue = annotation.contents ?? ""
        configureInlineEditorField(field)

        addSubview(field)
        inlineTextField = field
        inlineTextPage = page
        inlineTextAnchorInPage = nil
        inlineLiveTextAnnotation = annotation
        inlineEditingExistingAnnotation = true
        inlineOriginalTextContents = annotation.contents ?? ""
        inlineAnnotationWasDisplayed = annotation.shouldDisplay
        annotation.shouldDisplay = false
        field.frame = inlineEditorFrame(for: annotation, on: page)
        startTextEditCaretBlink(for: annotation, page: page)

        window?.makeFirstResponder(field)
        if let editor = window?.fieldEditor(true, for: field) as? NSTextView {
            let end = (field.stringValue as NSString).length
            editor.setSelectedRange(NSRange(location: end, length: 0))
        }
    }

    private func commitInlineTextEditor(cancel: Bool, selectCommittedAnnotation: Bool = false) -> PDFAnnotation? {
        guard let field = inlineTextField else { return nil }
        let wasEditingExisting = inlineEditingExistingAnnotation
        let originalText = inlineOriginalTextContents
        defer {
            stopTextEditCaretBlink()
            field.removeFromSuperview()
            inlineTextField = nil
            inlineTextPage = nil
            inlineTextAnchorInPage = nil
            inlineLiveTextAnnotation = nil
            inlineEditingExistingAnnotation = false
            inlineOriginalTextContents = nil
        }

        guard let page = inlineTextPage else { return nil }
        let annotation = inlineLiveTextAnnotation

        if cancel {
            if let annotation {
                if wasEditingExisting {
                    annotation.contents = originalText
                    annotation.shouldDisplay = inlineAnnotationWasDisplayed
                } else {
                    page.removeAnnotation(annotation)
                }
            }
            return nil
        }

        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let annotation else { return nil }
        if text.isEmpty {
            if wasEditingExisting {
                annotation.contents = originalText
                annotation.shouldDisplay = inlineAnnotationWasDisplayed
            } else {
                page.removeAnnotation(annotation)
            }
            return nil
        }
        annotation.contents = text
        annotation.shouldDisplay = inlineAnnotationWasDisplayed
        syncTextOutlineAppearance(for: annotation, outlineColor: textOutlineColor, outlineWidth: textOutlineWidth)
        if wasEditingExisting {
            let previousText = originalText ?? ""
            if previousText != text {
                onAnnotationTextEdited?(page, annotation, previousText)
            }
        } else {
            onAnnotationAdded?(page, annotation, "Add Text")
            // After placing a textbox note, return to Select (V) to avoid accidental extra text boxes.
            if toolMode == .text {
                toolMode = .select
                onToolShortcut?(.select)
            }
        }
        if selectCommittedAnnotation {
            onAnnotationClicked?(page, annotation)
        } else {
            onAnnotationsBoxSelected?(page, [])
        }
        return annotation
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let committed = commitInlineTextEditor(cancel: false)
        finalizeCommittedCalloutTextIfNeeded(committed)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = inlineTextField,
              let annotation = inlineLiveTextAnnotation else { return }
        let text = field.stringValue
        annotation.contents = text.isEmpty ? " " : text
        if let page = inlineTextPage {
            field.frame = inlineEditorFrame(for: annotation, on: page)
        }
        if let page = inlineTextPage {
            updateTextEditCaret(for: annotation, page: page)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let committed = commitInlineTextEditor(cancel: false)
            finalizeCommittedCalloutTextIfNeeded(committed)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Esc should finalize text markup instead of discarding it.
            let committed = commitInlineTextEditor(cancel: false)
            finalizeCommittedCalloutTextIfNeeded(committed)
            return true
        }
        return false
    }

    private func finalizeCommittedCalloutTextIfNeeded(_ annotation: PDFAnnotation?) {
        guard toolMode == .callout,
              let annotation,
              let page = annotation.page,
              let tip = pendingCalloutTipInPage,
              let elbow = pendingCalloutElbowInPage,
              pendingCalloutPage == page else { return }
        addCalloutLeader(on: page, textAnnotation: annotation, elbow: elbow, tip: tip)
        clearPendingCallout()
    }

    private func isEditableTextAnnotation(_ annotation: PDFAnnotation) -> Bool {
        let type = (annotation.type ?? "").lowercased()
        return type.contains("freetext") || (type.contains("free") && type.contains("text"))
    }

    private func startTextEditCaretBlink(for annotation: PDFAnnotation, page: PDFPage) {
        updateTextEditCaret(for: annotation, page: page)
        textEditCaretLayer.isHidden = false
        textEditCaretTimer?.invalidate()
        textEditCaretTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(toggleTextEditCaretVisibility), userInfo: nil, repeats: true)
        if let timer = textEditCaretTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopTextEditCaretBlink() {
        textEditCaretTimer?.invalidate()
        textEditCaretTimer = nil
        textEditCaretLayer.isHidden = true
        textEditCaretLayer.path = nil
    }

    private func updateTextEditCaret(for annotation: PDFAnnotation, page: PDFPage) {
        let text = (annotation.contents ?? "").replacingOccurrences(of: "\n", with: " ")
        let font = annotation.font ?? NSFont.systemFont(ofSize: max(6.0, textFontSize), weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let measured = (text as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 4
        let caretHeight = max(12, min(annotation.bounds.height - 4, font.ascender - font.descender))
        var x = annotation.bounds.minX + padding + measured.width
        x = min(max(x, annotation.bounds.minX + padding), annotation.bounds.maxX - 2)
        let y = annotation.bounds.midY - caretHeight * 0.5
        let p1 = convert(NSPoint(x: x, y: y), from: page)
        let p2 = convert(NSPoint(x: x, y: y + caretHeight), from: page)
        let path = CGMutablePath()
        path.move(to: p1)
        path.addLine(to: p2)
        textEditCaretLayer.path = path
        textEditCaretLayer.strokeColor = (annotation.fontColor ?? textForegroundColor).cgColor
        textEditCaretLayer.isHidden = false
    }

    @objc private func toggleTextEditCaretVisibility() {
        textEditCaretLayer.isHidden.toggle()
    }

    private func inlineEditorFrame(for annotation: PDFAnnotation, on page: PDFPage) -> NSRect {
        let p1 = convert(annotation.bounds.origin, from: page)
        let p2 = convert(NSPoint(x: annotation.bounds.maxX, y: annotation.bounds.maxY), from: page)
        let rect = NSRect(
            x: min(p1.x, p2.x),
            y: min(p1.y, p2.y),
            width: abs(p2.x - p1.x),
            height: abs(p2.y - p1.y)
        )
        return NSRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: max(rect.size.width, 24),
            height: max(rect.size.height, 18)
        )
    }

    private func minimumResizeSize(for annotation: PDFAnnotation) -> NSSize {
        let fontSize = max(6.0, annotation.font?.pointSize ?? textFontSize)
        return NSSize(width: max(120.0, fontSize * 8.0), height: max(34.0, fontSize * 2.4))
    }

    private func resizeCornerHit(for annotation: PDFAnnotation, on page: PDFPage, at locationInView: NSPoint) -> ResizeCorner? {
        guard isEditableTextAnnotation(annotation) else { return nil }
        // Match handle geometry shown by MainViewController selection overlay for FreeText.
        let visualRect = rectInView(fromPageRect: annotation.bounds, on: page).insetBy(dx: -4, dy: -4)
        guard visualRect.width > 0.1, visualRect.height > 0.1 else { return nil }
        let handles: [(ResizeCorner, NSPoint)] = [
            (.lowerLeft, NSPoint(x: visualRect.minX, y: visualRect.minY)),
            (.lowerRight, NSPoint(x: visualRect.maxX, y: visualRect.minY)),
            (.upperLeft, NSPoint(x: visualRect.minX, y: visualRect.maxY)),
            (.upperRight, NSPoint(x: visualRect.maxX, y: visualRect.maxY))
        ]
        let threshold: CGFloat = 16.0
        for (corner, point) in handles {
            if hypot(locationInView.x - point.x, locationInView.y - point.y) <= threshold {
                return corner
            }
        }
        return nil
    }

    private func initialCalloutDragState(
        from hit: PDFAnnotation,
        on page: PDFPage,
        pointerInView: NSPoint,
        pointerInPage: NSPoint
    ) -> CalloutDragState? {
        guard let groupID = calloutGroupID(for: hit) else { return nil }
        let grouped = page.annotations.filter { calloutGroupID(for: $0) == groupID }
        guard let text = grouped.first(where: { isEditableTextAnnotation($0) }),
              let leader = grouped.first(where: { ($0.contents ?? "").lowercased().contains("callout leader") }),
              let geometry = calloutLeaderGeometry(for: leader) else {
            return nil
        }
        let handle: CalloutDragHandle
        if let corner = resizeCornerHit(for: text, on: page, at: pointerInView) {
            handle = .textCorner(corner)
        } else {
            let elbowInView = convert(geometry.elbow, from: page)
            let tipInView = convert(geometry.tip, from: page)
            if hypot(pointerInView.x - tipInView.x, pointerInView.y - tipInView.y) <= 12 {
                handle = .tip
            } else if hypot(pointerInView.x - elbowInView.x, pointerInView.y - elbowInView.y) <= 12 {
                handle = .elbow
            } else {
                handle = .moveAll
            }
        }
        return CalloutDragState(
            page: page,
            textAnnotation: text,
            leaderAnnotation: leader,
            dotAnnotation: grouped.first(where: { isCalloutEndpointAnnotation($0) }),
            startTextBounds: text.bounds,
            startElbow: geometry.elbow,
            startTip: geometry.tip,
            startPointerInPage: pointerInPage,
            handle: handle
        )
    }

    private func replaceCalloutLeader(state: inout CalloutDragState, elbow: NSPoint, tip: NSPoint) {
        let style = calloutArrowStyle(for: state.leaderAnnotation) ?? calloutArrowStyle
        let headSize = calloutArrowHeadSize(for: state.leaderAnnotation) ?? calloutArrowHeadSize
        let lineWidth = max(0.1, state.leaderAnnotation.border?.lineWidth ?? calloutLineWidth)
        let stroke = state.leaderAnnotation.color
        let groupID = calloutGroupID(for: state.textAnnotation)
        state.page.removeAnnotation(state.leaderAnnotation)
        if let dot = state.dotAnnotation {
            state.page.removeAnnotation(dot)
        }
        let rebuilt = makeCalloutLeaderAnnotations(
            on: state.page,
            textAnnotation: state.textAnnotation,
            elbow: elbow,
            tip: tip,
            style: style,
            lineWidth: lineWidth,
            headSize: headSize,
            strokeColor: stroke,
            groupID: groupID
        )
        state.page.addAnnotation(rebuilt.leader)
        if let endpoint = rebuilt.endpoint {
            state.page.addAnnotation(endpoint)
        }
        state.leaderAnnotation = rebuilt.leader
        state.dotAnnotation = rebuilt.endpoint
    }

    private func calloutLeaderGeometry(for leader: PDFAnnotation) -> (elbow: NSPoint, tip: NSPoint)? {
        if let contents = leader.contents {
            var elbow: NSPoint?
            var tip: NSPoint?
            for part in contents.split(separator: "|") {
                let token = String(part)
                if token.hasPrefix("Elbow:") {
                    elbow = parseCalloutPoint(String(token.dropFirst("Elbow:".count)))
                } else if token.hasPrefix("Tip:") {
                    tip = parseCalloutPoint(String(token.dropFirst("Tip:".count)))
                }
            }
            if let elbow, let tip {
                return (elbow, tip)
            }
        }
        guard let path = leader.paths?.first, path.elementCount >= 3 else { return nil }
        var polylinePoints: [NSPoint] = []
        polylinePoints.reserveCapacity(3)
        for idx in 0..<path.elementCount {
            var associated = [NSPoint](repeating: .zero, count: 3)
            let element = path.element(at: idx, associatedPoints: &associated)
            switch element {
            case .moveTo, .lineTo:
                polylinePoints.append(associated[0])
            default:
                break
            }
            if polylinePoints.count >= 3 {
                break
            }
        }
        guard polylinePoints.count >= 3 else { return nil }
        let offset = leader.bounds.origin
        return (
            translated(polylinePoints[1], by: offset),
            translated(polylinePoints[2], by: offset)
        )
    }

    private func parseCalloutPoint(_ token: String) -> NSPoint? {
        let values = token.split(separator: ",", maxSplits: 1).map(String.init)
        guard values.count == 2,
              let x = Double(values[0]),
              let y = Double(values[1]) else {
            return nil
        }
        return NSPoint(x: x, y: y)
    }

    private func encodedCalloutPoint(_ point: NSPoint) -> String {
        String(format: "%.4f,%.4f", point.x, point.y)
    }

    private func encodedHeadSize(_ headSize: CGFloat) -> String {
        String(format: "%.2f", max(1.0, headSize))
    }

    private func makeCalloutLeaderAnnotations(
        on page: PDFPage,
        textAnnotation: PDFAnnotation,
        elbow: NSPoint,
        tip: NSPoint,
        style: ArrowEndStyle,
        lineWidth: CGFloat,
        headSize: CGFloat,
        strokeColor: NSColor,
        groupID: String?
    ) -> (leader: PDFAnnotation, endpoint: PDFAnnotation?) {
        let anchor = nearestPointOnRectBoundary(textAnnotation.bounds, toward: elbow)
        let points = [anchor, elbow, tip]
        let minX = points.map(\.x).min() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let pad = max(6.0, lineWidth * 2.0)
        let bounds = NSRect(x: minX - pad, y: minY - pad, width: (maxX - minX) + pad * 2.0, height: (maxY - minY) + pad * 2.0)

        let path = NSBezierPath()
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: anchor.x - bounds.origin.x, y: anchor.y - bounds.origin.y))
        path.line(to: NSPoint(x: elbow.x - bounds.origin.x, y: elbow.y - bounds.origin.y))
        path.line(to: NSPoint(x: tip.x - bounds.origin.x, y: tip.y - bounds.origin.y))

        addArrowDecoration(
            to: path,
            tip: NSPoint(x: tip.x - bounds.origin.x, y: tip.y - bounds.origin.y),
            from: NSPoint(x: elbow.x - bounds.origin.x, y: elbow.y - bounds.origin.y),
            style: style,
            lineWidth: lineWidth,
            headSize: headSize
        )

        let leader = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        leader.color = strokeColor
        path.lineWidth = lineWidth
        assignLineWidth(lineWidth, to: leader)
        leader.contents = "Callout Leader|Arrow:\(style.rawValue)|Head:\(encodedHeadSize(headSize))|Elbow:\(encodedCalloutPoint(elbow))|Tip:\(encodedCalloutPoint(tip))"
        if let groupID {
            leader.userName = Self.calloutGroupPrefix + groupID
        }
        leader.add(path)

        let endpoint = makeArrowEndpointAnnotation(
            tip: tip,
            style: style,
            lineWidth: lineWidth,
            strokeColor: strokeColor,
            headSize: headSize,
            groupID: groupID,
            isCallout: true
        )
        return (leader, endpoint)
    }

    private func handleCalloutClick(at locationInView: NSPoint) {
        guard let page = page(for: locationInView, nearest: true) else {
            NSSound.beep()
            return
        }
        let snappedLocationInView = snapPointInViewIfNeeded(locationInView, on: page)
        let pointInPage = snapPointInPageIfNeeded(convert(snappedLocationInView, to: page), on: page)

        if inlineTextField != nil {
            let committed = commitInlineTextEditor(cancel: false)
            guard let textAnnotation = committed,
                  let tip = pendingCalloutTipInPage,
                  let elbow = pendingCalloutElbowInPage,
                  pendingCalloutPage == page else {
                clearPendingCallout()
                return
            }
            addCalloutLeader(on: page, textAnnotation: textAnnotation, elbow: elbow, tip: tip)
            clearPendingCallout()
            return
        }

        if pendingCalloutPage == nil || pendingCalloutPage !== page {
            clearPendingCallout()
            pendingCalloutPage = page
            pendingCalloutTipInPage = pointInPage
            pendingCalloutGroupID = UUID().uuidString
            updateCalloutPreview(at: snappedLocationInView)
            return
        }

        if pendingCalloutTipInPage == nil {
            pendingCalloutTipInPage = pointInPage
            updateCalloutPreview(at: snappedLocationInView)
            return
        }
        if pendingCalloutElbowInPage == nil {
            pendingCalloutElbowInPage = pointInPage
            updateCalloutPreview(at: snappedLocationInView)
            return
        }

        hideCalloutPreview()
        beginInlineTextEditing(at: snappedLocationInView)
    }

    private func clearPendingCallout() {
        pendingCalloutPage = nil
        pendingCalloutTipInPage = nil
        pendingCalloutElbowInPage = nil
        pendingCalloutGroupID = nil
        hideTypedDistanceHUD()
        hideCalloutPreview()
    }

    func cancelPendingCallout() {
        clearPendingCallout()
    }

    func cancelPendingMeasurement() {
        pendingMeasurePage = nil
        pendingMeasureStartInPage = nil
        hideTypedDistanceHUD()
        if toolMode == .measure {
            dragPreviewLayer.isHidden = true
            dragPreviewLayer.path = nil
        }
    }

    private func hideTypedDistanceHUD() {
        typedDistanceHUDBackgroundLayer.isHidden = true
        typedDistanceHUDBackgroundLayer.path = nil
        typedDistanceHUDTextLayer.isHidden = true
        typedDistanceHUDTextLayer.string = nil
    }

    private func updateTypedDistanceHUD() {
        let isLineReady = (toolMode == .line && pendingLinePage != nil && pendingLineStartInPage != nil)
        let isPolylineReady = (toolMode == .polyline && pendingPolylinePage != nil && !pendingPolylinePointsInPage.isEmpty)
        guard isLineReady || isPolylineReady else {
            hideTypedDistanceHUD()
            return
        }

        let hasTypedLength = !typedDistanceBuffer.isEmpty
        let text = hasTypedLength ? typedDistanceBuffer : "Type length..."
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: hasTypedLength ? NSColor.white : NSColor.systemBlue.withAlphaComponent(0.95)
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let paddingX: CGFloat = 8
        let paddingY: CGFloat = 5
        let hudWidth = max(56, ceil(textSize.width) + paddingX * 2)
        let hudHeight = max(24, ceil(textSize.height) + paddingY * 2)

        let anchorPoint: NSPoint
        if let pointer = lastPointerInView {
            anchorPoint = pointer
        } else if toolMode == .line, let page = pendingLinePage, let start = pendingLineStartInPage {
            anchorPoint = convert(start, from: page)
        } else if toolMode == .polyline, let page = pendingPolylinePage, let last = pendingPolylinePointsInPage.last {
            anchorPoint = convert(last, from: page)
        } else {
            hideTypedDistanceHUD()
            return
        }

        let origin = NSPoint(x: anchorPoint.x + 14, y: anchorPoint.y + 14)
        let rect = NSRect(x: origin.x, y: origin.y, width: hudWidth, height: hudHeight)
        typedDistanceHUDBackgroundLayer.path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        typedDistanceHUDBackgroundLayer.isHidden = false

        typedDistanceHUDTextLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        typedDistanceHUDTextLayer.string = NSAttributedString(string: text, attributes: attrs)
        typedDistanceHUDTextLayer.frame = NSRect(
            x: rect.minX + paddingX,
            y: rect.minY + paddingY - 1,
            width: rect.width - paddingX * 2,
            height: rect.height - paddingY * 2
        )
        typedDistanceHUDTextLayer.isHidden = false
    }

    private func updateMeasurePreview(with event: NSEvent) {
        guard toolMode == .measure,
              let page = pendingMeasurePage,
              let start = pendingMeasureStartInPage else {
            return
        }
        let locationInView = convert(event.locationInWindow, from: nil)
        guard self.page(for: locationInView, nearest: true) == page else { return }
        let endInPage = snapPointInPageIfNeeded(convert(locationInView, to: page), on: page)
        let geometry = measurementGeometry(from: start, to: endInPage)
        let path = CGMutablePath()
        for segment in geometry.segments {
            path.move(to: convert(segment.start, from: page))
            path.addLine(to: convert(segment.end, from: page))
        }
        dragPreviewLayer.strokeColor = measurementStrokeColor.cgColor
        dragPreviewLayer.fillColor = NSColor.clear.cgColor
        dragPreviewLayer.lineWidth = measurementLineWidth
        dragPreviewLayer.lineDashPattern = nil
        dragPreviewLayer.path = path
        dragPreviewLayer.isHidden = false
    }

    private func addMeasurementAnnotation(from p1: NSPoint, to p2: NSPoint, on page: PDFPage) {
        let distance = hypot(p2.x - p1.x, p2.y - p1.y)
        guard distance > 4 else { return }

        let geometry = measurementGeometry(from: p1, to: p2)
        let geometryPoints = geometry.segments.flatMap { [$0.start, $0.end] }
        let xs = geometryPoints.map(\.x)
        let ys = geometryPoints.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return
        }

        let lineBounds = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -6, dy: -6)
        let path = NSBezierPath()
        for segment in geometry.segments {
            path.move(to: NSPoint(x: segment.start.x - lineBounds.origin.x, y: segment.start.y - lineBounds.origin.y))
            path.line(to: NSPoint(x: segment.end.x - lineBounds.origin.x, y: segment.end.y - lineBounds.origin.y))
        }

        let line = PDFAnnotation(bounds: lineBounds, forType: .ink, withProperties: nil)
        line.color = measurementStrokeColor
        path.lineWidth = measurementLineWidth
        assignLineWidth(measurementLineWidth, to: line)
        line.contents = String(format: "DrawbridgeMeasure|%.8f", distance)
        line.add(path)
        page.addAnnotation(line)
        onAnnotationAdded?(page, line, "Add Measurement")

        let labelText = formattedMeasurementLabel(distanceInPoints: distance)
        let labelBounds = NSRect(x: geometry.labelAnchor.x - 52, y: geometry.labelAnchor.y - 10, width: 116, height: 22)
        let label = PDFAnnotation(bounds: labelBounds, forType: .freeText, withProperties: nil)
        label.contents = labelText
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.fontColor = measurementStrokeColor
        label.color = NSColor.white.withAlphaComponent(0.88)
        forceUprightTextAnnotationIfSupported(label, on: page)
        page.addAnnotation(label)
        onAnnotationAdded?(page, label, "Add Measurement Label")
    }

    private func formattedMeasurementLabel(distanceInPoints: CGFloat) -> String {
        let value = distanceInPoints * measurementUnitsPerPoint
        guard measurementUnitLabel == "ft" else {
            return String(format: "%.2f %@", value, measurementUnitLabel)
        }

        let roundedTotalInches = (Double(value) * 12.0 * 16.0).rounded() / 16.0
        var feet = Int(floor(roundedTotalInches / 12.0))
        var inches = roundedTotalInches - Double(feet * 12)

        if inches >= 12.0 {
            feet += 1
            inches -= 12.0
        }
        return "\(feet)' - \(formatFractionalInches(inches))\""
    }

    private func formatFractionalInches(_ inches: Double) -> String {
        var whole = Int(floor(inches + 0.000001))
        var numerator = Int(((inches - Double(whole)) * 16.0).rounded())
        var denominator = 16

        if numerator == denominator {
            whole += 1
            numerator = 0
        }

        if numerator == 0 {
            return "\(whole)"
        }

        let divisor = gcd(numerator, denominator)
        numerator /= divisor
        denominator /= divisor
        return "\(whole) \(numerator)/\(denominator)"
    }

    private func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let t = x % y
            x = y
            y = t
        }
        return max(1, x)
    }

    private func measurementGeometry(from p1: NSPoint, to p2: NSPoint) -> DimensionGeometry {
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        let distance = hypot(dx, dy)
        guard distance > 0.0001 else {
            return DimensionGeometry(segments: [(p1, p2)], labelAnchor: p1)
        }

        let ux = dx / distance
        let uy = dy / distance
        let normal = NSPoint(x: -uy, y: ux)
        let style = DimensionStyle(
            offset: max(14.0, measurementLineWidth * 2.5),
            extensionOvershoot: max(4.0, measurementLineWidth * 0.8),
            tickLength: max(10.0, measurementLineWidth * 1.8),
            tickAngle: .pi / 4.0,
            labelOffset: max(8.0, measurementLineWidth * 1.4)
        )

        let startDim = NSPoint(x: p1.x + normal.x * style.offset, y: p1.y + normal.y * style.offset)
        let endDim = NSPoint(x: p2.x + normal.x * style.offset, y: p2.y + normal.y * style.offset)
        let startDimExtended = NSPoint(x: startDim.x + normal.x * style.extensionOvershoot, y: startDim.y + normal.y * style.extensionOvershoot)
        let endDimExtended = NSPoint(x: endDim.x + normal.x * style.extensionOvershoot, y: endDim.y + normal.y * style.extensionOvershoot)

        let cosTheta = cos(style.tickAngle)
        let sinTheta = sin(style.tickAngle)
        let tickDirection = NSPoint(
            x: ux * cosTheta - uy * sinTheta,
            y: ux * sinTheta + uy * cosTheta
        )

        func tick(at point: NSPoint) -> Segment {
            let half = style.tickLength * 0.5
            let a = NSPoint(x: point.x - tickDirection.x * half, y: point.y - tickDirection.y * half)
            let b = NSPoint(x: point.x + tickDirection.x * half, y: point.y + tickDirection.y * half)
            return (a, b)
        }

        let segments: [Segment] = [
            (p1, startDimExtended),
            (p2, endDimExtended),
            (startDim, endDim),
            tick(at: startDim),
            tick(at: endDim)
        ]
        let labelAnchor = NSPoint(
            x: (startDim.x + endDim.x) * 0.5 + normal.x * style.labelOffset,
            y: (startDim.y + endDim.y) * 0.5 + normal.y * style.labelOffset
        )
        return DimensionGeometry(segments: segments, labelAnchor: labelAnchor)
    }

    private func hideCalloutPreview() {
        calloutTextBoxPreviewLayer.isHidden = true
        calloutTextBoxPreviewLayer.path = nil
        dragPreviewLayer.isHidden = true
        dragPreviewLayer.path = nil
        dragPreviewLayer.lineDashPattern = nil
    }

    private func updatePolylinePreview(at locationInView: NSPoint?, orthogonal: Bool) {
        guard toolMode == .polyline,
              let page = pendingPolylinePage,
              !pendingPolylinePointsInPage.isEmpty else {
            return
        }

        let path = CGMutablePath()
        let startInView = convert(pendingPolylinePointsInPage[0], from: page)
        path.move(to: startInView)
        for point in pendingPolylinePointsInPage.dropFirst() {
            path.addLine(to: convert(point, from: page))
        }
        if let anchor = pendingPolylinePointsInPage.last,
           let typedTarget = typedLengthPreviewTargetInView(
                on: page,
                from: anchor,
                fallbackLocationInView: locationInView,
                orthogonal: orthogonal
           ) {
            path.addLine(to: typedTarget)
        } else if let locationInView,
           self.page(for: locationInView, nearest: true) == page {
            let snappedCurrent = snapPointInViewIfNeeded(locationInView, on: page)
            if orthogonal, let last = pendingPolylinePointsInPage.last {
                let lastInView = convert(last, from: page)
                let orthogonalPoint = orthogonalSnapPoint(anchor: lastInView, current: snappedCurrent)
                path.addLine(to: snapPointInViewIfNeeded(orthogonalPoint, on: page))
            } else {
                path.addLine(to: snappedCurrent)
            }
        }

        dragPreviewLayer.strokeColor = penColor.cgColor
        dragPreviewLayer.fillColor = NSColor.clear.cgColor
        dragPreviewLayer.lineWidth = penLineWidth
        dragPreviewLayer.lineDashPattern = [5, 4]
        dragPreviewLayer.path = path
        dragPreviewLayer.isHidden = false
    }

    private func updateCalloutPreview(at locationInView: NSPoint) {
        guard toolMode == .callout,
              let page = pendingCalloutPage ?? page(for: locationInView, nearest: true),
              pendingCalloutPage == nil || pendingCalloutPage === page,
              let tipInPage = pendingCalloutTipInPage else {
            hideCalloutPreview()
            return
        }

        let hoverInPage = snapPointInPageIfNeeded(convert(locationInView, to: page), on: page)
        let tipInView = convert(tipInPage, from: page)
        let hoverInView = convert(hoverInPage, from: page)

        let path = NSBezierPath()
        if let elbowInPage = pendingCalloutElbowInPage {
            let elbowInView = convert(elbowInPage, from: page)
            let textRectInPage = calloutTextAnnotationBounds(forAnchorInPage: hoverInPage, on: page)
            let textRect = rectInView(fromPageRect: textRectInPage, on: page)
            let anchor = nearestPointOnRectBoundary(textRect, toward: elbowInView)
            let textPath = CGMutablePath()
            textPath.addRect(textRect)
            calloutTextBoxPreviewLayer.strokeColor = calloutStrokeColor.cgColor
            calloutTextBoxPreviewLayer.fillColor = textBackgroundColor.cgColor
            calloutTextBoxPreviewLayer.lineWidth = max(0.0, textOutlineWidth)
            calloutTextBoxPreviewLayer.strokeColor = textOutlineColor.cgColor
            calloutTextBoxPreviewLayer.path = textPath
            calloutTextBoxPreviewLayer.isHidden = false
            path.move(to: anchor)
            path.line(to: elbowInView)
            path.line(to: tipInView)
            addArrowDecoration(
                to: path,
                tip: tipInView,
                from: elbowInView,
                style: calloutArrowStyle,
                lineWidth: calloutLineWidth,
                headSize: calloutArrowHeadSize
            )
        } else {
            calloutTextBoxPreviewLayer.isHidden = true
            calloutTextBoxPreviewLayer.path = nil
            path.move(to: hoverInView)
            path.line(to: tipInView)
            addArrowDecoration(
                to: path,
                tip: tipInView,
                from: hoverInView,
                style: calloutArrowStyle,
                lineWidth: calloutLineWidth,
                headSize: calloutArrowHeadSize
            )
        }

        dragPreviewLayer.strokeColor = calloutStrokeColor.cgColor
        dragPreviewLayer.fillColor = NSColor.clear.cgColor
        dragPreviewLayer.lineDashPattern = [6, 4]
        dragPreviewLayer.lineWidth = calloutLineWidth
        dragPreviewLayer.path = cgPath(from: path)
        dragPreviewLayer.isHidden = false
    }

    private func updateTextPreview(at locationInView: NSPoint) {
        calloutTextBoxPreviewLayer.isHidden = true
        calloutTextBoxPreviewLayer.path = nil
        guard inlineTextField == nil,
              let page = page(for: locationInView, nearest: true) else {
            hideTextPreview()
            return
        }
        let anchorInPage = snapPointInPageIfNeeded(convert(locationInView, to: page), on: page)
        let pageRect = calloutTextAnnotationBounds(forAnchorInPage: anchorInPage, on: page)
        let textRect = rectInView(fromPageRect: pageRect, on: page)
        let path = CGMutablePath()
        path.addRect(textRect)
        dragPreviewLayer.strokeColor = textBackgroundColor.cgColor
        dragPreviewLayer.fillColor = textBackgroundColor.cgColor
        dragPreviewLayer.strokeColor = textOutlineColor.cgColor
        dragPreviewLayer.lineWidth = max(0.0, textOutlineWidth)
        dragPreviewLayer.lineDashPattern = nil
        dragPreviewLayer.path = path
        dragPreviewLayer.isHidden = false
    }

    private func hideTextPreview() {
        guard inlineTextField == nil else { return }
        dragPreviewLayer.isHidden = true
        dragPreviewLayer.path = nil
        dragPreviewLayer.lineDashPattern = nil
    }

    private func calloutTextAnnotationBounds(forAnchorInPage anchor: NSPoint, on page: PDFPage) -> NSRect {
        let size = max(6.0, textFontSize)
        let visualWidth = max(260.0, size * 16.0)
        let visualHeight = max(56.0, size * 3.6)
        let pageRotation = ((page.rotation % 360) + 360) % 360
        let shouldSwap = (pageRotation == 90 || pageRotation == 270)
        let width = shouldSwap ? visualHeight : visualWidth
        let height = shouldSwap ? visualWidth : visualHeight
        return NSRect(
            x: anchor.x,
            y: anchor.y - (height * 0.35),
            width: width,
            height: height
        )
    }

    private func rectInView(fromPageRect pageRect: NSRect, on page: PDFPage) -> NSRect {
        let v1 = convert(pageRect.origin, from: page)
        let v2 = convert(NSPoint(x: pageRect.maxX, y: pageRect.maxY), from: page)
        return normalizedRect(from: v1, to: v2)
    }

    private func addArrowDecoration(to path: NSBezierPath, tip: NSPoint, from base: NSPoint, style: ArrowEndStyle, lineWidth: CGFloat, headSize: CGFloat) {
        let dx = tip.x - base.x
        let dy = tip.y - base.y
        let dist = hypot(dx, dy)
        guard dist > 0.001 else { return }
        let ux = dx / dist
        let uy = dy / dist
        let length = max(4.0, headSize * 2.0, lineWidth * 2.0)
        let halfAngle = CGFloat.pi / 7.0
        let left = NSPoint(
            x: tip.x - length * (ux * cos(halfAngle) - uy * sin(halfAngle)),
            y: tip.y - length * (uy * cos(halfAngle) + ux * sin(halfAngle))
        )
        let right = NSPoint(
            x: tip.x - length * (ux * cos(-halfAngle) - uy * sin(-halfAngle)),
            y: tip.y - length * (uy * cos(-halfAngle) + ux * sin(-halfAngle))
        )
        switch style {
        case .solidArrow:
            path.move(to: left)
            path.line(to: tip)
            path.line(to: right)
            path.line(to: left)
        case .openArrow:
            path.move(to: left)
            path.line(to: tip)
            path.line(to: right)
        case .filledTriangle:
            path.move(to: left)
            path.line(to: tip)
            path.line(to: right)
            path.line(to: left)
        case .openTriangle:
            path.move(to: left)
            path.line(to: tip)
            path.line(to: right)
            path.line(to: left)
        case .filledDot, .openDot:
            let radius = max(1.0, headSize * 0.5, lineWidth * 0.75)
            let dotRect = NSRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2.0, height: radius * 2.0)
            path.appendOval(in: dotRect)
        case .filledSquare, .openSquare:
            let side = max(2.0, headSize)
            let squareRect = NSRect(x: tip.x - side * 0.5, y: tip.y - side * 0.5, width: side, height: side)
            path.appendRect(squareRect)
        }
    }

    private func normalizedRect(from p1: NSPoint, to p2: NSPoint) -> NSRect {
        let x = min(p1.x, p2.x)
        let y = min(p1.y, p2.y)
        return NSRect(x: x, y: y, width: abs(p1.x - p2.x), height: abs(p1.y - p2.y))
    }

    private func nearestAnnotation(to point: NSPoint, on page: PDFPage, maxDistance: CGFloat) -> PDFAnnotation? {
        // Prefer visible vector snapshot overlays directly under the cursor.
        for annotation in page.annotations.reversed() {
            guard annotation.shouldDisplay else { continue }
            if annotation is PDFSnapshotAnnotation, annotation.bounds.contains(point) {
                return annotation
            }
        }

        var best: PDFAnnotation?
        var bestDistance = maxDistance
        for annotation in page.annotations.reversed() {
            guard annotation.shouldDisplay else { continue }
            if isTextOutlineAnnotation(annotation) { continue }
            let annotationType = (annotation.type ?? "").lowercased()
            let isInkLike = annotationType.contains("ink")
            let d: CGFloat
            if isInkLike, let strokeDistance = distanceToInkStroke(point, annotation: annotation) {
                d = strokeDistance
            } else if isInkLike {
                d = distanceToRectPerimeter(point, rect: annotation.bounds)
            } else {
                d = distanceToRect(point, rect: annotation.bounds)
            }
            if d <= bestDistance {
                bestDistance = d
                best = annotation
            }
        }
        if let best {
            return best
        }

        // Fallback: for thin/complex paths where stroke extraction can miss, accept
        // an expanded-bounds hit and prefer the closest perimeter in topmost order.
        var fallback: PDFAnnotation?
        var fallbackDistance = maxDistance
        for annotation in page.annotations.reversed() {
            guard annotation.shouldDisplay else { continue }
            if isTextOutlineAnnotation(annotation) { continue }
            let expanded = annotation.bounds.insetBy(dx: -maxDistance, dy: -maxDistance)
            guard expanded.contains(point) else { continue }
            let d = distanceToRectPerimeter(point, rect: annotation.bounds)
            if d <= fallbackDistance {
                fallbackDistance = d
                fallback = annotation
            }
        }
        if let fallback {
            return fallback
        }
        return best
    }

    private func selectionHitDistanceInPage() -> CGFloat {
        // Keep click hit-target roughly constant on-screen across zoom levels.
        let zoom = max(0.05, scaleFactor)
        let viewPixels: CGFloat = 16.0
        return min(72.0, max(8.0, viewPixels / zoom))
    }

    private func distanceToRect(_ point: NSPoint, rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private func distanceToRectPerimeter(_ point: NSPoint, rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        if dx > 0 || dy > 0 {
            return hypot(dx, dy)
        }
        let toLeft = abs(point.x - rect.minX)
        let toRight = abs(point.x - rect.maxX)
        let toBottom = abs(point.y - rect.minY)
        let toTop = abs(point.y - rect.maxY)
        return min(toLeft, toRight, toBottom, toTop)
    }

    private func distanceToInkStroke(_ pointInPage: NSPoint, annotation: PDFAnnotation) -> CGFloat? {
        guard let paths = annotation.value(forKey: "paths") as? [NSBezierPath], !paths.isEmpty else {
            return nil
        }
        var best = CGFloat.greatestFiniteMagnitude
        for path in paths {
            let d = distanceToBezierPath(pointInPage, path: path, in: annotation.bounds.origin)
            best = min(best, d)
        }
        return best.isFinite ? best : nil
    }

    private func distanceToBezierPath(_ point: NSPoint, path: NSBezierPath, in origin: NSPoint) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        var points = [NSPoint](repeating: .zero, count: 3)
        var previous: NSPoint?
        var subpathStart: NSPoint?

        for idx in 0..<path.elementCount {
            let element = path.element(at: idx, associatedPoints: &points)
            switch element {
            case .moveTo:
                previous = points[0]
                subpathStart = points[0]
            case .lineTo:
                if let prev = previous {
                    best = min(best, distancePointToSegment(point, a: translated(prev, by: origin), b: translated(points[0], by: origin)))
                }
                previous = points[0]
            case .curveTo:
                if let prev = previous {
                    var last = prev
                    for step in 1...16 {
                        let t = CGFloat(step) / 16.0
                        let p = cubicPoint(
                            t: t,
                            p0: prev,
                            p1: points[0],
                            p2: points[1],
                            p3: points[2]
                        )
                        best = min(best, distancePointToSegment(point, a: translated(last, by: origin), b: translated(p, by: origin)))
                        last = p
                    }
                }
                previous = points[2]
            case .cubicCurveTo:
                if let prev = previous {
                    var last = prev
                    for step in 1...16 {
                        let t = CGFloat(step) / 16.0
                        let p = cubicPoint(
                            t: t,
                            p0: prev,
                            p1: points[0],
                            p2: points[1],
                            p3: points[2]
                        )
                        best = min(best, distancePointToSegment(point, a: translated(last, by: origin), b: translated(p, by: origin)))
                        last = p
                    }
                }
                previous = points[2]
            case .quadraticCurveTo:
                if let prev = previous {
                    var last = prev
                    for step in 1...16 {
                        let t = CGFloat(step) / 16.0
                        let p = quadraticPoint(
                            t: t,
                            p0: prev,
                            p1: points[0],
                            p2: points[1]
                        )
                        best = min(best, distancePointToSegment(point, a: translated(last, by: origin), b: translated(p, by: origin)))
                        last = p
                    }
                }
                previous = points[1]
            case .closePath:
                if let prev = previous, let start = subpathStart {
                    best = min(best, distancePointToSegment(point, a: translated(prev, by: origin), b: translated(start, by: origin)))
                }
            @unknown default:
                break
            }
        }

        return best
    }

    private func distancePointToSegment(_ p: NSPoint, a: NSPoint, b: NSPoint) -> CGFloat {
        let vx = b.x - a.x
        let vy = b.y - a.y
        let wx = p.x - a.x
        let wy = p.y - a.y
        let c1 = vx * wx + vy * wy
        if c1 <= 0 {
            return hypot(p.x - a.x, p.y - a.y)
        }
        let c2 = vx * vx + vy * vy
        if c2 <= c1 {
            return hypot(p.x - b.x, p.y - b.y)
        }
        let t = c1 / c2
        let px = a.x + t * vx
        let py = a.y + t * vy
        return hypot(p.x - px, p.y - py)
    }

    private func cubicPoint(t: CGFloat, p0: NSPoint, p1: NSPoint, p2: NSPoint, p3: NSPoint) -> NSPoint {
        let mt = 1 - t
        let a = mt * mt * mt
        let b = 3 * mt * mt * t
        let c = 3 * mt * t * t
        let d = t * t * t
        return NSPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                       y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    private func quadraticPoint(t: CGFloat, p0: NSPoint, p1: NSPoint, p2: NSPoint) -> NSPoint {
        let mt = 1 - t
        let a = mt * mt
        let b = 2 * mt * t
        let c = t * t
        return NSPoint(x: a * p0.x + b * p1.x + c * p2.x,
                       y: a * p0.y + b * p1.y + c * p2.y)
    }

    private func translated(_ point: NSPoint, by offset: NSPoint) -> NSPoint {
        NSPoint(x: point.x + offset.x, y: point.y + offset.y)
    }

    private func cgPath(from bezierPath: NSBezierPath) -> CGPath {
        let path = CGMutablePath()
        let pointCount = 3
        var points = [NSPoint](repeating: .zero, count: pointCount)
        for index in 0..<bezierPath.elementCount {
            let element = bezierPath.element(at: index, associatedPoints: &points)
            switch element {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            case .closePath:
                path.closeSubpath()
            @unknown default:
                break
            }
        }
        return path
    }

    private func orthogonalSnapPoint(anchor: NSPoint, current: NSPoint) -> NSPoint {
        let dx = current.x - anchor.x
        let dy = current.y - anchor.y
        if abs(dx) >= abs(dy) {
            return NSPoint(x: current.x, y: anchor.y)
        }
        return NSPoint(x: anchor.x, y: current.y)
    }

    private func addCloudAnnotation(on page: PDFPage, in rect: NSRect) {
        let cloudBounds = rect.insetBy(dx: -10, dy: -10)
        let localBounds = NSRect(origin: .zero, size: cloudBounds.size)
        let bumpAmplitude: CGFloat = max(4, min(localBounds.width, localBounds.height) * 0.06)
        let baseRect = localBounds.insetBy(dx: bumpAmplitude + 2, dy: bumpAmplitude + 2)
        let scallopStep: CGFloat = max(16, bumpAmplitude * 2.8)
        let path = NSBezierPath()
        path.lineJoinStyle = .round
        path.lineCapStyle = .round

        func edgePoints(from start: NSPoint, to end: NSPoint, step: CGFloat) -> [NSPoint] {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length >= 1 else { return [start, end] }
            let segments = max(1, Int(round(length / step)))
            return (0...segments).map { idx in
                let t = CGFloat(idx) / CGFloat(segments)
                return NSPoint(x: start.x + dx * t, y: start.y + dy * t)
            }
        }

        let top = edgePoints(
            from: NSPoint(x: baseRect.minX, y: baseRect.maxY),
            to: NSPoint(x: baseRect.maxX, y: baseRect.maxY),
            step: scallopStep
        )
        let right = edgePoints(
            from: NSPoint(x: baseRect.maxX, y: baseRect.maxY),
            to: NSPoint(x: baseRect.maxX, y: baseRect.minY),
            step: scallopStep
        )
        let bottom = edgePoints(
            from: NSPoint(x: baseRect.maxX, y: baseRect.minY),
            to: NSPoint(x: baseRect.minX, y: baseRect.minY),
            step: scallopStep
        )
        let left = edgePoints(
            from: NSPoint(x: baseRect.minX, y: baseRect.minY),
            to: NSPoint(x: baseRect.minX, y: baseRect.maxY),
            step: scallopStep
        )

        let outline = top + right.dropFirst() + bottom.dropFirst() + left.dropFirst()
        guard outline.count >= 3 else { return }
        path.move(to: outline[0])

        for idx in 0..<outline.count {
            let a = outline[idx]
            let b = outline[(idx + 1) % outline.count]
            let midpoint = NSPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5)

            let outward: NSPoint
            if abs(a.y - baseRect.maxY) < 0.5 && abs(b.y - baseRect.maxY) < 0.5 {
                outward = NSPoint(x: 0, y: 1)
            } else if abs(a.x - baseRect.maxX) < 0.5 && abs(b.x - baseRect.maxX) < 0.5 {
                outward = NSPoint(x: 1, y: 0)
            } else if abs(a.y - baseRect.minY) < 0.5 && abs(b.y - baseRect.minY) < 0.5 {
                outward = NSPoint(x: 0, y: -1)
            } else {
                outward = NSPoint(x: -1, y: 0)
            }

            let control = NSPoint(
                x: midpoint.x + outward.x * bumpAmplitude,
                y: midpoint.y + outward.y * bumpAmplitude
            )
            path.curve(to: b, controlPoint1: control, controlPoint2: control)
        }
        path.close()

        let annotation = PDFAnnotation(bounds: cloudBounds, forType: .ink, withProperties: nil)
        annotation.color = NSColor.systemCyan
        path.lineWidth = 2.0
        assignLineWidth(2.0, to: annotation)
        annotation.contents = "Cloud"
        annotation.add(path)
        page.addAnnotation(annotation)
        onAnnotationAdded?(page, annotation, "Add Cloud")
    }

    private func addCalloutLeader(on page: PDFPage, textAnnotation: PDFAnnotation, elbow: NSPoint, tip: NSPoint) {
        let rebuilt = makeCalloutLeaderAnnotations(
            on: page,
            textAnnotation: textAnnotation,
            elbow: elbow,
            tip: tip,
            style: calloutArrowStyle,
            lineWidth: calloutLineWidth,
            headSize: calloutArrowHeadSize,
            strokeColor: calloutStrokeColor,
            groupID: calloutGroupID(for: textAnnotation)
        )
        page.addAnnotation(rebuilt.leader)
        onAnnotationAdded?(page, rebuilt.leader, "Add Callout")
        if let endpoint = rebuilt.endpoint {
            page.addAnnotation(endpoint)
            onAnnotationAdded?(page, endpoint, "Add Callout")
        }
    }

    func calloutGroupID(for annotation: PDFAnnotation) -> String? {
        guard let userName = annotation.userName,
              userName.hasPrefix(Self.calloutGroupPrefix) else {
            return nil
        }
        let value = String(userName.dropFirst(Self.calloutGroupPrefix.count))
        return value.isEmpty ? nil : value
    }

    private func isTextOutlineAnnotation(_ annotation: PDFAnnotation) -> Bool {
        (annotation.contents ?? "") == Self.textOutlineMarker
    }

    func syncTextOutlineGeometry(for textAnnotation: PDFAnnotation) {
        guard isEditableTextAnnotation(textAnnotation),
              let page = textAnnotation.page,
              let userName = textAnnotation.userName else { return }
        let outlines = page.annotations.filter { $0.userName == userName && isTextOutlineAnnotation($0) }
        for outline in outlines {
            outline.bounds = textAnnotation.bounds
        }
    }

    func textOutlineStyle(for textAnnotation: PDFAnnotation) -> (color: NSColor, width: CGFloat)? {
        guard isEditableTextAnnotation(textAnnotation),
              let page = textAnnotation.page,
              let userName = textAnnotation.userName else { return nil }
        guard let outline = page.annotations.first(where: { $0.userName == userName && isTextOutlineAnnotation($0) }) else {
            return nil
        }
        return (outline.color, max(0.0, outline.border?.lineWidth ?? 0.0))
    }

    func syncTextOutlineAppearance(for textAnnotation: PDFAnnotation, outlineColor: NSColor, outlineWidth: CGFloat) {
        guard isEditableTextAnnotation(textAnnotation),
              let page = textAnnotation.page else { return }

        if textAnnotation.userName == nil {
            textAnnotation.userName = Self.textGroupPrefix + UUID().uuidString
        }
        guard let userName = textAnnotation.userName else { return }

        let outlines = page.annotations.filter { $0.userName == userName && isTextOutlineAnnotation($0) }
        let normalizedWidth = max(0.0, outlineWidth)
        if normalizedWidth <= 0.01 {
            for outline in outlines {
                page.removeAnnotation(outline)
            }
            return
        }

        let outline: PDFAnnotation
        if let first = outlines.first {
            outline = first
            for extra in outlines.dropFirst() {
                page.removeAnnotation(extra)
            }
        } else {
            outline = PDFAnnotation(bounds: textAnnotation.bounds, forType: .square, withProperties: nil)
            outline.userName = userName
            outline.contents = Self.textOutlineMarker
            outline.shouldPrint = textAnnotation.shouldPrint
            outline.shouldDisplay = textAnnotation.shouldDisplay
            page.addAnnotation(outline)
        }

        outline.bounds = textAnnotation.bounds
        outline.color = outlineColor
        outline.interiorColor = .clear
        assignLineWidth(normalizedWidth, to: outline)
    }

    func calloutArrowStyle(for annotation: PDFAnnotation) -> ArrowEndStyle? {
        guard let contents = annotation.contents else { return nil }
        if let range = contents.range(of: "Arrow:") {
            let raw = contents[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let token = raw.split(separator: "|", maxSplits: 1).first.map(String.init) ?? String(raw)
            if let value = Int(token), let style = ArrowEndStyle(rawValue: value) {
                return style
            }
        }
        if contents.lowercased().contains("callout leader") {
            return .solidArrow
        }
        return nil
    }

    private func isCalloutEndpointAnnotation(_ annotation: PDFAnnotation) -> Bool {
        let contents = (annotation.contents ?? "").lowercased()
        return contents.contains("callout arrow dot") || contents.contains("callout arrow square")
    }

    func calloutArrowHeadSize(for annotation: PDFAnnotation) -> CGFloat? {
        guard let contents = annotation.contents else { return nil }
        if let range = contents.range(of: "Head:") {
            let raw = contents[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let token = raw.split(separator: "|", maxSplits: 1).first.map(String.init) ?? String(raw)
            if let value = Double(token) {
                return max(1.0, CGFloat(value))
            }
        }
        return nil
    }

    func linkedCalloutLeader(for annotation: PDFAnnotation) -> PDFAnnotation? {
        guard let page = annotation.page else { return nil }
        if let groupID = calloutGroupID(for: annotation) {
            return page.annotations.first(where: {
                calloutGroupID(for: $0) == groupID && looksLikeCalloutLeaderAnnotation($0)
            })
        }
        if looksLikeCalloutLeaderAnnotation(annotation) {
            return annotation
        }
        guard isEditableTextAnnotation(annotation) else { return nil }
        return nearestCalloutLeader(to: annotation, on: page)
    }

    @discardableResult
    func updateCalloutLeaderAppearance(
        for annotation: PDFAnnotation,
        style: ArrowEndStyle,
        headSize: CGFloat,
        lineWidth: CGFloat,
        strokeColor: NSColor
    ) -> Bool {
        guard let page = annotation.page else { return false }
        guard let leader = linkedCalloutLeader(for: annotation),
              let geometry = calloutLeaderGeometry(for: leader) else {
            return false
        }
        let textAnnotation: PDFAnnotation
        if isEditableTextAnnotation(annotation) {
            textAnnotation = annotation
        } else if let groupID = calloutGroupID(for: leader),
                  let groupedText = page.annotations.first(where: {
                      calloutGroupID(for: $0) == groupID && isEditableTextAnnotation($0)
                  }) {
            textAnnotation = groupedText
        } else if let nearby = nearestCalloutText(to: leader, on: page) {
            textAnnotation = nearby
        } else {
            return false
        }

        let groupID = calloutGroupID(for: textAnnotation) ?? calloutGroupID(for: leader)
        let endpoint = page.annotations.first(where: {
            calloutGroupID(for: $0) == groupID && isCalloutEndpointAnnotation($0)
        })
        page.removeAnnotation(leader)
        if let endpoint {
            page.removeAnnotation(endpoint)
        }
        let rebuilt = makeCalloutLeaderAnnotations(
            on: page,
            textAnnotation: textAnnotation,
            elbow: geometry.elbow,
            tip: geometry.tip,
            style: style,
            lineWidth: max(0.1, lineWidth),
            headSize: max(1.0, headSize),
            strokeColor: strokeColor,
            groupID: groupID
        )
        page.addAnnotation(rebuilt.leader)
        if let newEndpoint = rebuilt.endpoint {
            page.addAnnotation(newEndpoint)
        }
        return true
    }

    private func isCalloutLeaderAnnotation(_ annotation: PDFAnnotation) -> Bool {
        (annotation.contents ?? "").lowercased().contains("callout leader")
    }

    private func looksLikeCalloutLeaderAnnotation(_ annotation: PDFAnnotation) -> Bool {
        if isCalloutLeaderAnnotation(annotation) {
            return true
        }
        let type = (annotation.type ?? "").lowercased()
        guard type.contains("ink") else { return false }
        return calloutLeaderGeometry(for: annotation) != nil
    }

    private func nearestCalloutLeader(to textAnnotation: PDFAnnotation, on page: PDFPage) -> PDFAnnotation? {
        let searchRect = textAnnotation.bounds.insetBy(dx: -30, dy: -30)
        return page.annotations
            .filter { candidate in
                guard looksLikeCalloutLeaderAnnotation(candidate) else { return false }
                let center = NSPoint(x: candidate.bounds.midX, y: candidate.bounds.midY)
                return candidate.bounds.intersects(searchRect) || searchRect.contains(center)
            }
            .min(by: { centerDistance($0.bounds, textAnnotation.bounds) < centerDistance($1.bounds, textAnnotation.bounds) })
    }

    private func nearestCalloutText(to leaderAnnotation: PDFAnnotation, on page: PDFPage) -> PDFAnnotation? {
        let searchRect = leaderAnnotation.bounds.insetBy(dx: -30, dy: -30)
        return page.annotations
            .filter { candidate in
                guard isEditableTextAnnotation(candidate) else { return false }
                let center = NSPoint(x: candidate.bounds.midX, y: candidate.bounds.midY)
                return candidate.bounds.intersects(searchRect) || searchRect.contains(center)
            }
            .min(by: { centerDistance($0.bounds, leaderAnnotation.bounds) < centerDistance($1.bounds, leaderAnnotation.bounds) })
    }

    private func centerDistance(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let ac = NSPoint(x: a.midX, y: a.midY)
        let bc = NSPoint(x: b.midX, y: b.midY)
        return hypot(ac.x - bc.x, ac.y - bc.y)
    }

    private func makeArrowEndpointAnnotation(
        tip: NSPoint,
        style: ArrowEndStyle,
        lineWidth: CGFloat,
        strokeColor: NSColor,
        headSize: CGFloat,
        groupID: String?,
        isCallout: Bool
    ) -> PDFAnnotation? {
        let normalizedHead = max(1.0, headSize)
        let normalizedLine = max(1.0, lineWidth)
        let prefix = isCallout ? "Callout Arrow" : "Arrow"

        switch style {
        case .filledDot, .openDot:
            let radius = max(1.0, normalizedHead * 0.5)
            let bounds = NSRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2.0, height: radius * 2.0)
            let dot = PDFAnnotation(bounds: bounds, forType: .circle, withProperties: nil)
            dot.color = strokeColor
            dot.interiorColor = (style == .filledDot) ? strokeColor : .clear
            assignLineWidth(normalizedLine, to: dot)
            dot.contents = "\(prefix) Dot|Arrow:\(style.rawValue)|Head:\(encodedHeadSize(normalizedHead))"
            if let groupID {
                dot.userName = Self.calloutGroupPrefix + groupID
            }
            return dot
        case .filledSquare, .openSquare:
            let side = max(2.0, normalizedHead)
            let bounds = NSRect(x: tip.x - side * 0.5, y: tip.y - side * 0.5, width: side, height: side)
            let square = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
            square.color = strokeColor
            square.interiorColor = (style == .filledSquare) ? strokeColor : .clear
            assignLineWidth(normalizedLine, to: square)
            square.contents = "\(prefix) Square|Arrow:\(style.rawValue)|Head:\(encodedHeadSize(normalizedHead))"
            if let groupID {
                square.userName = Self.calloutGroupPrefix + groupID
            }
            return square
        case .solidArrow, .openArrow, .filledTriangle, .openTriangle:
            return nil
        }
    }

    private func nearestPointOnRectBoundary(_ rect: NSRect, toward point: NSPoint) -> NSPoint {
        let candidates = [
            NSPoint(x: rect.minX, y: min(max(point.y, rect.minY), rect.maxY)),
            NSPoint(x: rect.maxX, y: min(max(point.y, rect.minY), rect.maxY)),
            NSPoint(x: min(max(point.x, rect.minX), rect.maxX), y: rect.minY),
            NSPoint(x: min(max(point.x, rect.minX), rect.maxX), y: rect.maxY)
        ]
        var best = candidates[0]
        var bestDistance = hypot(best.x - point.x, best.y - point.y)
        for candidate in candidates.dropFirst() {
            let d = hypot(candidate.x - point.x, candidate.y - point.y)
            if d < bestDistance {
                bestDistance = d
                best = candidate
            }
        }
        return best
    }

    func selectAllInlineTextIfEditing() -> Bool {
        guard let field = inlineTextField else { return false }
        if let editor = window?.fieldEditor(true, for: field) as? NSTextView {
            editor.selectAll(nil)
            return true
        }
        field.selectText(nil)
        return true
    }

    @discardableResult
    func handleTypedDistanceKey(_ event: NSEvent) -> Bool {
        let noCommandModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: [.command, .option, .control])
        guard noCommandModifiers,
              toolMode == .line || (toolMode == .polyline && pendingPolylinePage != nil && !pendingPolylinePointsInPage.isEmpty) else {
            return false
        }
        let ortho = isOrthoConstraintActive(for: event)
        if event.keyCode == 36 || event.keyCode == 76 {
            return commitTypedDistanceIfPossible(orthogonal: ortho)
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            if !typedDistanceBuffer.isEmpty {
                typedDistanceBuffer.removeLast()
                refreshTypedDistancePreview(orthogonal: ortho)
                return true
            }
            return false
        }
        if let chars = event.charactersIgnoringModifiers,
           !chars.isEmpty {
            let allowed = CharacterSet(charactersIn: "0123456789./'\"- ")
            let filtered = String(chars.unicodeScalars.filter { allowed.contains($0) })
            if !filtered.isEmpty {
                typedDistanceBuffer.append(filtered)
                refreshTypedDistancePreview(orthogonal: ortho)
                return true
            }
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
        if handleTypedDistanceKey(event) {
            return
        }
        let noCommandModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: [.command, .option, .control])
        if noCommandModifiers {
            switch event.keyCode {
            case 123, 126: // Left / Up
                onPageNavigationShortcut?(-1)
                return
            case 124, 125: // Right / Down
                onPageNavigationShortcut?(1)
                return
            default:
                break
            }
        }
        if noCommandModifiers,
           (event.keyCode == 51 || event.keyCode == 117) {
            onDeleteKeyPressed?()
            return
        }
        let disallowed: NSEvent.ModifierFlags = [.command, .option, .control]
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: disallowed),
           let chars = event.charactersIgnoringModifiers?.lowercased(),
           let mode = shortcutMode(for: chars, isShift: event.modifierFlags.contains(.shift)) {
            onToolShortcut?(mode)
            return
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        handleWheelZoom(event)
    }

    func handleWheelZoom(_ event: NSEvent) {
        guard document != nil else {
            super.scrollWheel(with: event)
            return
        }

        let delta = event.scrollingDeltaY
        if delta == 0 {
            super.scrollWheel(with: event)
            return
        }

        let zoomIn = delta > 0
        let isTrackpadLike = event.hasPreciseScrollingDeltas
        let normalizedDelta = abs(delta)

        // Tune zoom feel by input device:
        // - Mouse wheel: more aggressive per notch.
        // - Trackpad: finer increments with smooth acceleration.
        let step = isTrackpadLike ? (1.0 + min(0.035, normalizedDelta * 0.0045))
                                   : (1.0 + min(0.16, normalizedDelta * 0.03))
        let factor = zoomIn ? step : (1.0 / step)

        autoScales = false
        let targetScale = min(max(minScaleFactor, scaleFactor * factor), maxScaleFactor)
        guard targetScale != scaleFactor else { return }

        let locationInView = convert(event.locationInWindow, from: nil)
        if let page = page(for: locationInView, nearest: true) {
            let anchorPagePoint = convert(locationInView, to: page)
            scaleFactor = targetScale

            // Keep the exact PDF point under cursor fixed while zooming.
            let pageUnderCursorAfterZoom = convert(locationInView, to: page)
            let deltaX = anchorPagePoint.x - pageUnderCursorAfterZoom.x
            let deltaY = anchorPagePoint.y - pageUnderCursorAfterZoom.y
            let base = currentDestination?.point ?? convert(NSPoint(x: bounds.midX, y: bounds.midY), to: page)
            let destination = NSPoint(x: base.x + deltaX, y: base.y + deltaY)
            go(to: PDFDestination(page: page, at: destination))
            updateGridOverlayIfNeeded()
            onViewportChanged?()
        } else {
            scaleFactor = targetScale
            updateGridOverlayIfNeeded()
            onViewportChanged?()
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        middlePanLastWindowPoint = event.locationInWindow
        NSCursor.closedHand.push()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2,
              let lastWindowPoint = middlePanLastWindowPoint,
              let page = currentPage else {
            super.otherMouseDragged(with: event)
            return
        }

        let lastView = convert(lastWindowPoint, from: nil)
        let currentView = convert(event.locationInWindow, from: nil)
        let lastPagePoint = convert(lastView, to: page)
        let currentPagePoint = convert(currentView, to: page)
        let dx = currentPagePoint.x - lastPagePoint.x
        let dy = currentPagePoint.y - lastPagePoint.y

        let anchor = currentDestination?.point ?? convert(NSPoint(x: bounds.midX, y: bounds.midY), to: page)
        let destination = PDFDestination(page: page, at: NSPoint(x: anchor.x - dx, y: anchor.y - dy))
        go(to: destination)
        middlePanLastWindowPoint = event.locationInWindow
        updateGridOverlayIfNeeded()
        onViewportChanged?()
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        middlePanLastWindowPoint = nil
        NSCursor.pop()
    }

    private func shortcutMode(for chars: String, isShift: Bool) -> ToolMode? {
        switch chars {
        case "v":
            return .select
        case "g":
            return .grab
        case "d":
            return .pen
        case "l":
            return .line
        case "p":
            return .polyline
        case "h":
            return .highlighter
        case "c":
            return .cloud
        case "r":
            return .rectangle
        case "t":
            return .text
        case "q":
            return .callout
        case "a":
            return isShift ? .area : .arrow
        case "m":
            return .measure
        case "k":
            return .calibrate
        default:
            return nil
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard droppedPDFURL(from: sender) != nil || droppedImageURL(from: sender) != nil else {
            return []
        }
        dropHighlightLayer.isHidden = false
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHighlightLayer.isHidden = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropHighlightLayer.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropHighlightLayer.isHidden = true }
        if let pdfURL = droppedPDFURL(from: sender) {
            onOpenDroppedPDF?(pdfURL)
            return true
        }
        guard let imageURL = droppedImageURL(from: sender),
              let document,
              let image = NSImage(contentsOf: imageURL) else {
            return false
        }

        let locationInView = convert(sender.draggingLocation, from: nil)
        guard let page = page(for: locationInView, nearest: true) else {
            return false
        }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return false }

        let pagePoint = convert(locationInView, to: page)
        let initialBounds = initialImageBounds(for: image, dropPoint: pagePoint, on: page)
        let annotation = ImageMarkupAnnotation(bounds: initialBounds, imageURL: imageURL)
        page.addAnnotation(annotation)
        onAnnotationAdded?(page, annotation, "Add Image")
        onImageDropped?(page, annotation, initialBounds)
        return true
    }

    private func droppedPDFURL(from sender: NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return nil
        }
        return urls.first(where: { $0.pathExtension.lowercased() == "pdf" || UTType(filenameExtension: $0.pathExtension)?.conforms(to: .pdf) == true })
    }

    private func droppedImageURL(from sender: NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return nil
        }
        return urls.first(where: { url in
            guard url.pathExtension.isEmpty == false else { return false }
            if let type = UTType(filenameExtension: url.pathExtension.lowercased()) {
                return type.conforms(to: .image)
            }
            return false
        })
    }

    private func initialImageBounds(for image: NSImage, dropPoint: NSPoint, on page: PDFPage) -> NSRect {
        let imageSize = image.size
        let pageBounds = page.bounds(for: displayBox)
        let maxWidth = min(pageBounds.width * 0.48, 360)
        let maxHeight = min(pageBounds.height * 0.48, 360)
        let widthScale = maxWidth / max(imageSize.width, 1)
        let heightScale = maxHeight / max(imageSize.height, 1)
        let scale = min(1.0, widthScale, heightScale)
        let width = max(36, imageSize.width * scale)
        let height = max(36, imageSize.height * scale)

        var rect = NSRect(
            x: dropPoint.x - width * 0.5,
            y: dropPoint.y - height * 0.5,
            width: width,
            height: height
        )

        if rect.minX < pageBounds.minX { rect.origin.x = pageBounds.minX }
        if rect.maxX > pageBounds.maxX { rect.origin.x = pageBounds.maxX - rect.width }
        if rect.minY < pageBounds.minY { rect.origin.y = pageBounds.minY }
        if rect.maxY > pageBounds.maxY { rect.origin.y = pageBounds.maxY - rect.height }
        return rect
    }
}
