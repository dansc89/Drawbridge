import AppKit
import PDFKit
import UniformTypeIdentifiers

private final class PDFOverscrollClipView: NSClipView {
    private let overscrollFactor: CGFloat = 0.35
    private let minimumOverscroll: CGFloat = 160

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        guard let documentView else {
            return super.constrainBoundsRect(proposedBounds)
        }

        let documentFrame = documentView.frame.standardized
        guard !documentFrame.isEmpty else {
            return super.constrainBoundsRect(proposedBounds)
        }

        let paddedBounds = documentFrame.insetBy(
            dx: -max(minimumOverscroll, proposedBounds.width * overscrollFactor),
            dy: -max(minimumOverscroll, proposedBounds.height * overscrollFactor)
        )

        var constrained = proposedBounds
        constrained.origin.x = constrainedOrigin(
            proposedOrigin: proposedBounds.origin.x,
            visibleLength: proposedBounds.width,
            minimumOrigin: paddedBounds.minX,
            maximumOrigin: paddedBounds.maxX
        )
        constrained.origin.y = constrainedOrigin(
            proposedOrigin: proposedBounds.origin.y,
            visibleLength: proposedBounds.height,
            minimumOrigin: paddedBounds.minY,
            maximumOrigin: paddedBounds.maxY
        )
        return constrained
    }

    private func constrainedOrigin(
        proposedOrigin: CGFloat,
        visibleLength: CGFloat,
        minimumOrigin: CGFloat,
        maximumOrigin: CGFloat
    ) -> CGFloat {
        let maxOrigin = maximumOrigin - visibleLength
        guard maxOrigin >= minimumOrigin else {
            return (minimumOrigin + maximumOrigin - visibleLength) * 0.5
        }
        return min(max(proposedOrigin, minimumOrigin), maxOrigin)
    }
}

final class MarkupPDFView: PDFView, NSTextFieldDelegate {
    let rectangleMarkup = RectangleMarkupController()
    override var document: PDFDocument? { didSet { rectangleMarkup.bind(to: document) } }

    enum ReorderAction {
        case sendToBack
        case bringForward
        case sendBackward
        case bringToFront
    }

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
    private enum LineEndpointHandle {
        case start
        case end
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
    private struct ViewportHistoryEntry {
        let pageIndex: Int
        let point: NSPoint
        let scale: CGFloat
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

    enum RectangleHatchStyle: Int, CaseIterable {
        case none = 0
        case solid = 1
        case concrete = 2
        case earth = 3
        case metal = 4
        case woodVeneer = 5
        case diagonal = 6
        case crosshatch = 7
        case brick = 8
        case insulation = 9
        case stone = 10

        var displayName: String {
            switch self {
            case .none: return "None"
            case .solid: return "Solid"
            case .concrete: return "Concrete"
            case .earth: return "Earth"
            case .metal: return "Metal"
            case .woodVeneer: return "Wood Veneer"
            case .diagonal: return "Diagonal"
            case .crosshatch: return "Crosshatch"
            case .brick: return "Brick"
            case .insulation: return "Insulation"
            case .stone: return "Stone"
            }
        }

        var metadataToken: String {
            switch self {
            case .none: return "clear"
            case .solid: return "solid"
            case .concrete: return "concrete"
            case .earth: return "earth"
            case .metal: return "metal"
            case .woodVeneer: return "wood_veneer"
            case .diagonal: return "diagonal"
            case .crosshatch: return "crosshatch"
            case .brick: return "brick"
            case .insulation: return "insulation"
            case .stone: return "stone"
            }
        }

        static func from(metadataToken: String) -> RectangleHatchStyle {
            switch metadataToken.lowercased() {
            case "clear": return .none
            case "none", "solid": return .solid
            case "concrete": return .concrete
            case "earth": return .earth
            case "metal": return .metal
            case "wood_veneer": return .woodVeneer
            case "diagonal": return .diagonal
            case "crosshatch": return .crosshatch
            case "brick": return .brick
            case "insulation": return .insulation
            case "stone": return .stone
            default: return .solid
            }
        }
    }

    var toolMode: ToolMode = .select {
        didSet {
            if !toolMode.isEnabledInScratchReset { toolMode = .select }
            guard oldValue != toolMode else { return }
            window?.invalidateCursorRects(for: self)
            if toolMode != .text {
                hideTextPreview()
            }
        }
    }
    var rectangleFillColor: NSColor = .systemYellow
    var rectangleHatchBackgroundColor: NSColor = .white
    var rectangleHatchStyle: RectangleHatchStyle = .solid
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
    var measurementUnitsPerPoint: CGFloat = 1.0
    var measurementUnitLabel: String = "pt"
    var onAnnotationAdded: ((PDFPage, PDFAnnotation, String) -> Void)?
    var onAnnotationTextEdited: ((PDFPage, PDFAnnotation, String) -> Void)?
    var onAnnotationClicked: ((PDFPage, PDFAnnotation, Bool) -> Void)?
    var onAnnotationsBoxSelected: ((PDFPage, [PDFAnnotation]) -> Void)?
    var onOpenDroppedPDF: ((URL) -> Void)?
    var onToolShortcut: ((ToolMode) -> Void)?
    var onPageNavigationShortcut: ((Int) -> Void)?
    var onViewportChanged: (() -> Void)?
    var onRegionCaptured: ((PDFPage, NSRect) -> Void)?
    var shouldBeginMarkupInteraction: (() -> Bool)?
    var polygonVertexEditModeEnabled = false

    private var middlePanLastWindowPoint: NSPoint?
    private var regionCaptureStartInView: NSPoint?
    private var regionCapturePage: PDFPage?
    private var isRegionCaptureModeEnabled = false
    private var didPushRegionCaptureCursor = false
    private var inlineTextField: NSTextField?
    private var inlineTextPage: PDFPage?
    private var inlineTextAnchorInPage: NSPoint?
    private var inlineLiveTextAnnotation: PDFAnnotation?
    private var inlineAnnotationWasDisplayed = true
    private var inlineEditingExistingAnnotation = false
    private var inlineOriginalTextContents: String?
    private var navigationSelectionStart: (page: PDFPage, point: NSPoint)?
    private var navigationBackStack: [ViewportHistoryEntry] = []
    private var navigationForwardStack: [ViewportHistoryEntry] = []
    private var applyingHistoryNavigation = false
    private let navigationHistoryLimit = 300
    private var navigationHistoryDocumentID: ObjectIdentifier?
    private var pendingCalloutPage: PDFPage?
    private var pendingCalloutTipInPage: NSPoint?
    private var pendingCalloutElbowInPage: NSPoint?
    private var pendingCalloutGroupID: String?
    private var pendingPolylinePage: PDFPage?
    private var pendingPolylinePointsInPage: [NSPoint] = []
    private var pendingPolygonPage: PDFPage?
    private var pendingPolygonPointsInPage: [NSPoint] = []
    private var pendingArrowPage: PDFPage?
    private var pendingArrowStartInPage: NSPoint?
    private var pendingLinePage: PDFPage?
    private var pendingLineStartInPage: NSPoint?
    private var pendingCirclePage: PDFPage?
    private var pendingCircleCenterInPage: NSPoint?
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
    private let hyperlinkOverlayLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.strokeColor = NSColor.clear.cgColor
        layer.fillColor = NSColor.clear.cgColor
        layer.lineWidth = 0
        layer.lineJoin = .round
        layer.zPosition = 6
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
    private var textEditCaretTimer: Timer?
    private weak var observedClipView: NSClipView?
    private weak var overscrollScrollView: NSScrollView?
    private var isGridVisible = false
    private var areHyperlinkHighlightsVisible = false
    private var pendingInteractiveViewportFeedbackWorkItem: DispatchWorkItem?
    private var lastInteractiveViewportFeedbackAt: CFAbsoluteTime = 0
    private var zoomAnchorGeneration: UInt = 0
    private var didInstallViewportObservers = false
    private var isOrthoSnapEnabled = true
    private var isEndpointSnapEnabled = true
    private var isMidpointSnapEnabled = true
    private var isIntersectionSnapEnabled = true
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
        layer?.addSublayer(hyperlinkOverlayLayer)
        layer?.addSublayer(calloutTextBoxPreviewLayer)
        layer?.addSublayer(dragPreviewLayer)
        layer?.addSublayer(dropHighlightLayer)
        layer?.addSublayer(textEditCaretLayer)
        layer?.addSublayer(typedDistanceHUDBackgroundLayer)
        layer?.addSublayer(typedDistanceHUDTextLayer)
        autoScales = true
        displayMode = .singlePage
        displayDirection = .vertical
        displaysPageBreaks = true
        refreshAppearanceColors()
        registerForDraggedTypes([.fileURL])
        installViewportObserversIfNeeded()
        rectangleMarkup.install(on: self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearanceColors()
    }

    func refreshAppearanceColors() {
        backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1.0)
    }

    private func installOverscrollClipViewIfNeeded() {
        guard let scrollView = descendantScrollView(of: self) else { return }
        overscrollScrollView = scrollView
        guard !(scrollView.contentView is PDFOverscrollClipView) else { return }

        let originalClipView = scrollView.contentView
        let overscrollClipView = PDFOverscrollClipView(frame: originalClipView.frame)
        overscrollClipView.autoresizingMask = originalClipView.autoresizingMask
        overscrollClipView.drawsBackground = originalClipView.drawsBackground
        overscrollClipView.backgroundColor = originalClipView.backgroundColor
        overscrollClipView.documentCursor = originalClipView.documentCursor
        overscrollClipView.documentView = originalClipView.documentView
        scrollView.contentView = overscrollClipView
        scrollView.reflectScrolledClipView(overscrollClipView)
    }

    private func descendantScrollView(of view: NSView) -> NSScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView {
                return scrollView
            }
            if let scrollView = descendantScrollView(of: subview) {
                return scrollView
            }
        }
        return nil
    }

    private var contentClipView: NSClipView? {
        if let contentView = overscrollScrollView?.contentView {
            return contentView
        }
        return descendantScrollView(of: self)?.contentView
    }

    private func scrollContentClipView(to origin: NSPoint) {
        guard let clipView = contentClipView else { return }
        clipView.scroll(to: origin)
        clipView.enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    @discardableResult
    private func guardOrBeep(_ condition: @autoclosure () -> Bool) -> Bool {
        guard condition() else {
            beep()
            return false
        }
        return true
    }

    private func beep() {
        NSSound.beep()
    }

    override func layout() {
        super.layout()
        installOverscrollClipViewIfNeeded()
        let insetBounds = bounds.insetBy(dx: 24, dy: 24)
        dropHighlightLayer.path = CGPath(roundedRect: insetBounds, cornerWidth: 14, cornerHeight: 14, transform: nil)
        installClipViewObserverIfNeeded()
        updateGridOverlayIfNeeded()
        updateHyperlinkOverlayIfNeeded()
        rectangleMarkup.refresh()
    }

    func setGridVisible(_ visible: Bool) {
        isGridVisible = visible
        updateGridOverlayIfNeeded()
    }

    func setHyperlinkHighlightsVisible(_ visible: Bool) {
        areHyperlinkHighlightsVisible = visible
        updateHyperlinkOverlayIfNeeded(forceHideWhenDisabled: true)
    }

    func refreshHyperlinkHighlights() {
        updateHyperlinkOverlayIfNeeded()
        rectangleMarkup.refresh()
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

    private func installViewportObserversIfNeeded() {
        guard !didInstallViewportObservers else { return }
        didInstallViewportObservers = true
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .PDFViewPageChanged,
            .PDFViewScaleChanged,
            .PDFViewDocumentChanged
        ]
        for name in names {
            center.addObserver(self, selector: #selector(handlePDFViewportChangedNotification(_:)), name: name, object: self)
        }
    }

    private func installClipViewObserverIfNeeded() {
        guard let clipView = enclosingScrollView?.contentView else { return }
        if observedClipView === clipView {
            return
        }
        if let observedClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedClipView
            )
        }
        observedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleClipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    @objc private func handlePDFViewportChangedNotification(_ notification: Notification) {
        _ = notification
        updateHyperlinkOverlayIfNeeded()
        rectangleMarkup.refresh()
    }

    @objc private func handleClipViewBoundsDidChange(_ notification: Notification) {
        _ = notification
        updateHyperlinkOverlayIfNeeded()
        rectangleMarkup.refresh()
    }

    private func updateHyperlinkOverlayIfNeeded(forceHideWhenDisabled: Bool = false) {
        guard areHyperlinkHighlightsVisible else {
            if forceHideWhenDisabled {
                hyperlinkOverlayLayer.path = nil
                hyperlinkOverlayLayer.isHidden = true
            }
            return
        }
        guard document != nil else {
            hyperlinkOverlayLayer.path = nil
            hyperlinkOverlayLayer.isHidden = true
            return
        }

        let pagesToRender: [PDFPage] = {
            if !visiblePages.isEmpty {
                return visiblePages
            }
            if let currentPage { return [currentPage] }
            return []
        }()
        guard !pagesToRender.isEmpty else {
            hyperlinkOverlayLayer.path = nil
            hyperlinkOverlayLayer.isHidden = true
            return
        }

        let expandedVisibleBounds = bounds.insetBy(dx: -24, dy: -24)
        let path = CGMutablePath()
        var hasAny = false
        for page in pagesToRender {
            for annotation in page.annotations where annotation.shouldDisplay && isLinkAnnotation(annotation) {
                let rectInView = convert(annotation.bounds, from: page).standardized
                guard !rectInView.isEmpty, rectInView.intersects(expandedVisibleBounds) else { continue }
                path.addRect(rectInView)
                hasAny = true
            }
        }

        hyperlinkOverlayLayer.path = hasAny ? path : nil
        hyperlinkOverlayLayer.isHidden = !hasAny
    }

    private func annotationSegmentsInPage(for annotation: PDFAnnotation) -> [(NSPoint, NSPoint)] {
        let allPaths = annotation.paths ?? []
        guard !allPaths.isEmpty else { return [] }
        let origin = annotation.bounds.origin
        var segments: [(NSPoint, NSPoint)] = []
        segments.reserveCapacity(max(1, allPaths.reduce(0) { $0 + max(0, $1.elementCount - 1) }))

        for path in allPaths {
            guard path.elementCount > 0 else { continue }
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
        }
        return segments
    }

    private struct SnapSegmentInView {
        let start: NSPoint
        let end: NSPoint
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
        rectangleMarkup.pointerMoved(at:convert(event.locationInWindow,from:nil))
        lastPointerInView = convert(event.locationInWindow, from: nil)
        super.mouseMoved(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "PDF")
        let copyItem = menu.addItem(withTitle: "Copy Text", action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        let selectItem = menu.addItem(withTitle: "Select All Text", action: #selector(selectAll(_:)), keyEquivalent: "")
        selectItem.target = self
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        lastPointerInView = location
        navigationSelectionStart = nil
        guard let page = page(for: location, nearest: false) else { return }
        if isRegionCaptureModeEnabled {
            regionCaptureStartInView = location
            regionCapturePage = page
            dragPreviewLayer.strokeColor = NSColor.systemBlue.cgColor
            dragPreviewLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
            dragPreviewLayer.lineWidth = 1.5
            dragPreviewLayer.lineDashPattern = [6, 4]
            dragPreviewLayer.path = CGPath(rect: NSRect(origin: location, size: .zero), transform: nil)
            dragPreviewLayer.isHidden = false
            return
        }
        if rectangleMarkup.pointerDown(at: location, clickCount:event.clickCount) { return }
        let point = convert(location, to: page)
        if event.clickCount == 1, let link = linkAnnotation(at: point, on: page) {
            if followLinkIfPossible(link) { return }
            if let action = link.action as? PDFActionURL {
                perform(action)
                return
            }
            if let action = link.action as? PDFActionRemoteGoTo {
                perform(action)
                return
            }
            if let action = link.action as? PDFActionNamed {
                perform(action)
                return
            }
        }
        // Text selection never invokes PDFKit's annotation/widget editing path.
        // Existing annotations stay visible and cannot be moved, resized or edited.
        if event.clickCount > 1 {
            setCurrentSelection(page.selectionForWord(at: point), animate: false)
        } else {
            setCurrentSelection(nil, animate: false)
            navigationSelectionStart = (page, point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        lastPointerInView = location
        if isRegionCaptureModeEnabled {
            guard let start = regionCaptureStartInView else { return }
            dragPreviewLayer.path = CGPath(rect: normalizedRect(from: start, to: location), transform: nil)
            return
        }
        if rectangleMarkup.pointerDragged(at: location) { return }
        guard let start = navigationSelectionStart else { return }
        let end = convert(location, to: start.page)
        setCurrentSelection(start.page.selection(from: start.point, to: end), animate: false)
    }

    override func mouseUp(with event: NSEvent) {
        navigationSelectionStart = nil
        if !isRegionCaptureModeEnabled, rectangleMarkup.pointerUp(at: convert(event.locationInWindow, from: nil)) { return }
        guard isRegionCaptureModeEnabled else { return }
        defer {
            regionCaptureStartInView = nil
            regionCapturePage = nil
            dragPreviewLayer.isHidden = true
            dragPreviewLayer.path = nil
            dragPreviewLayer.lineDashPattern = nil
        }
        guard let start = regionCaptureStartInView, let page = regionCapturePage else { return }
        let end = convert(event.locationInWindow, from: nil)
        let rect = normalizedRect(from: convert(start, to: page), to: convert(end, to: page))
        guard rect.width > 2, rect.height > 2 else { return }
        cancelRegionCaptureMode()
        onRegionCaptured?(page, rect)
    }

    private func assignLineWidth(_ lineWidth: CGFloat, to annotation: PDFAnnotation) {
        AnnotationStyleMutations.assignLineWidth(lineWidth, to: annotation)
    }

    private func clearPendingPolyline() {
        pendingPolylinePage = nil
        pendingPolylinePointsInPage = []
        typedDistanceBuffer = ""
        hideTypedDistanceHUD()
        dragPreviewLayer.path = nil
        dragPreviewLayer.isHidden = true
    }

    private func clearPendingPolygon() {
        pendingPolygonPage = nil
        pendingPolygonPointsInPage = []
        typedDistanceBuffer = ""
        hideTypedDistanceHUD()
        dragPreviewLayer.path = nil
        dragPreviewLayer.isHidden = true
    }

    func cancelPendingPolyline() {
        clearPendingPolyline()
    }

    func cancelPendingPolygon() {
        clearPendingPolygon()
    }

    private func normalizedPolygonPoints(_ points: [NSPoint]) -> [NSPoint] {
        guard !points.isEmpty else { return [] }
        var normalized: [NSPoint] = []
        normalized.reserveCapacity(points.count)
        for point in points {
            if let last = normalized.last,
               hypot(last.x - point.x, last.y - point.y) <= 0.5 {
                continue
            }
            normalized.append(point)
        }
        if normalized.count >= 2,
           let first = normalized.first,
           let last = normalized.last,
           hypot(first.x - last.x, first.y - last.y) <= 0.5 {
            normalized.removeLast()
        }
        return normalized
    }

    private func polygonPointsFromPaths(for annotation: PDFAnnotation) -> [NSPoint]? {
        let directPaths = annotation.paths ?? []
        let paths: [NSBezierPath]
        if !directPaths.isEmpty {
            paths = directPaths
        } else if let kvcPaths = annotation.value(forKey: "paths") as? [NSBezierPath], !kvcPaths.isEmpty {
            paths = kvcPaths
        } else {
            return nil
        }
        var collected: [NSPoint] = []
        for path in paths {
            var points = [NSPoint](repeating: .zero, count: 3)
            var subpathStart: NSPoint?
            for idx in 0..<path.elementCount {
                let element = path.element(at: idx, associatedPoints: &points)
                switch element {
                case .moveTo:
                    let point = translated(points[0], by: annotation.bounds.origin)
                    collected.append(point)
                    subpathStart = point
                case .lineTo:
                    collected.append(translated(points[0], by: annotation.bounds.origin))
                case .closePath:
                    if let start = subpathStart {
                        collected.append(start)
                    }
                default:
                    break
                }
            }
        }
        let normalized = normalizedPolygonPoints(collected)
        return normalized.count >= 3 ? normalized : nil
    }

    private func polygonPoints(for annotation: PDFAnnotation) -> [NSPoint]? {
        if let fromPaths = polygonPointsFromPaths(for: annotation) {
            return fromPaths
        }
        if let page = annotation.page,
           let grouped = groupedPolygonPoints(for: annotation, on: page),
           grouped.count >= 3 {
            return grouped
        }
        if let token = polygonPointsToken(for: annotation),
           let decoded = decodedPolygonPointsToken(token) {
            let normalized = normalizedPolygonPoints(decoded)
            return normalized.count >= 3 ? normalized : nil
        }
        return nil
    }

    private func groupedPolygonPoints(for annotation: PDFAnnotation, on page: PDFPage) -> [NSPoint]? {
        guard let groupID = polygonGroupID(for: annotation), !groupID.isEmpty else { return nil }
        let members = page.annotations.filter { candidate in
            !isHatchOverlayAnnotation(candidate) &&
                isPolygonMarkup(candidate) &&
                polygonGroupID(for: candidate) == groupID
        }
        guard members.count >= 2 else { return nil }

        var rawSegments: [(NSPoint, NSPoint)] = []
        for member in members {
            rawSegments.append(contentsOf: annotationSegmentsInPage(for: member).filter {
                hypot($0.1.x - $0.0.x, $0.1.y - $0.0.y) > 0.5
            })
        }
        guard rawSegments.count >= 3 else { return nil }

        var vertices: [NSPoint] = []
        var adjacency: [Int: Set<Int>] = [:]
        var seenEdges = Set<String>()

        func vertexIndex(for point: NSPoint) -> Int {
            for (idx, existing) in vertices.enumerated() {
                if hypot(existing.x - point.x, existing.y - point.y) <= 0.05 {
                    return idx
                }
            }
            vertices.append(point)
            return vertices.count - 1
        }

        for segment in rawSegments {
            let a = vertexIndex(for: segment.0)
            let b = vertexIndex(for: segment.1)
            if a == b { continue }
            let lo = min(a, b)
            let hi = max(a, b)
            let edgeKey = "\(lo):\(hi)"
            if !seenEdges.insert(edgeKey).inserted { continue }
            adjacency[a, default: []].insert(b)
            adjacency[b, default: []].insert(a)
        }

        guard vertices.count >= 3 else { return nil }
        guard vertices.indices.allSatisfy({ adjacency[$0]?.count == 2 }) else {
            return fallbackPolygonFromSegments(rawSegments)
        }

        guard let start = vertices.indices.min(by: {
            if abs(vertices[$0].x - vertices[$1].x) > 0.001 {
                return vertices[$0].x < vertices[$1].x
            }
            return vertices[$0].y < vertices[$1].y
        }) else { return nil }

        var orderedIndices: [Int] = [start]
        var previous: Int? = nil
        var current = start
        var safety = 0
        while safety < (vertices.count + 2) {
            safety += 1
            guard let neighbors = adjacency[current], !neighbors.isEmpty else {
                return fallbackPolygonFromSegments(rawSegments)
            }
            let next = neighbors.first(where: { $0 != previous }) ?? neighbors.first!
            if next == start { break }
            if orderedIndices.contains(next) {
                return fallbackPolygonFromSegments(rawSegments)
            }
            orderedIndices.append(next)
            previous = current
            current = next
        }
        guard orderedIndices.count >= 3 else {
            return fallbackPolygonFromSegments(rawSegments)
        }

        let points = orderedIndices.map { vertices[$0] }
        let normalized = normalizedPolygonPoints(points)
        if normalized.count >= 3 {
            return normalized
        }
        return fallbackPolygonFromSegments(rawSegments)
    }

    private func fallbackPolygonFromSegments(_ segments: [(NSPoint, NSPoint)]) -> [NSPoint]? {
        var points: [NSPoint] = []
        points.reserveCapacity(segments.count * 2)
        for segment in segments {
            points.append(segment.0)
            points.append(segment.1)
        }
        let hull = convexHull(points)
        let normalized = normalizedPolygonPoints(hull)
        return normalized.count >= 3 ? normalized : nil
    }

    private func convexHull(_ points: [NSPoint]) -> [NSPoint] {
        guard points.count >= 3 else { return points }
        let sorted = points
            .sorted {
                if abs($0.x - $1.x) > 0.0001 { return $0.x < $1.x }
                return $0.y < $1.y
            }
            .reduce(into: [NSPoint]()) { acc, point in
                if let last = acc.last, hypot(last.x - point.x, last.y - point.y) <= 0.05 {
                    return
                }
                acc.append(point)
            }
        guard sorted.count >= 3 else { return sorted }

        func cross(_ o: NSPoint, _ a: NSPoint, _ b: NSPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [NSPoint] = []
        for point in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }

        var upper: [NSPoint] = []
        for point in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }

        lower.removeLast()
        upper.removeLast()
        let hull = lower + upper
        return hull.count >= 3 ? hull : sorted
    }

    private func isPolygonMarkup(_ annotation: PDFAnnotation) -> Bool {
        guard let type = annotation.type?.lowercased(), type.contains("ink") else { return false }
        let contents = (annotation.contents ?? "").lowercased()
        return contents.contains("polygon")
    }

    func polygonVerticesInPage(for annotation: PDFAnnotation) -> [NSPoint]? {
        guard isPolygonMarkup(annotation) else { return nil }
        guard let points = polygonPoints(for: annotation), points.count >= 3 else { return nil }
        return points
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

    private func clearPendingCircle() {
        pendingCirclePage = nil
        pendingCircleCenterInPage = nil
        typedDistanceBuffer = ""
        hideTypedDistanceHUD()
        dragPreviewLayer.path = nil
        dragPreviewLayer.isHidden = true
    }

    func cancelPendingCircle() {
        clearPendingCircle()
    }

    func rectangleHatchStyle(for annotation: PDFAnnotation) -> RectangleHatchStyle? {
        let type = (annotation.type ?? "").lowercased()
        guard type.contains("square") || type.contains("circle") else { return nil }
        let metadata = annotation.userName ?? ""
        guard let markerRange = metadata.range(of: "DrawbridgeRectHatch:", options: .caseInsensitive) else {
            // Legacy fallback: previous behavior was effectively solid fill.
            return RectangleHatchStyle.solid
        }
        let tokenStart = metadata[markerRange.upperBound...]
        let token = tokenStart
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return RectangleHatchStyle.from(metadataToken: token)
    }

    private func polygonGroupID(for annotation: PDFAnnotation) -> String? {
        let metadata = annotation.userName ?? ""
        if let markerRange = metadata.range(of: "DrawbridgePolygonGroup:", options: .caseInsensitive) {
            let tokenStart = metadata[markerRange.upperBound...]
            return tokenStart
                .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init)
        }
        if let markerRange = metadata.range(of: "DrawbridgePolylineGroup:", options: .caseInsensitive) {
            let tokenStart = metadata[markerRange.upperBound...]
            return tokenStart
                .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init)
        }
        return nil
    }

    private func polygonPointsToken(for annotation: PDFAnnotation) -> String? {
        let metadata = annotation.userName ?? ""
        if let markerRange = metadata.range(of: "DrawbridgePolygonPts:", options: .caseInsensitive) {
            let tokenStart = metadata[markerRange.upperBound...]
            return tokenStart
                .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init)
        }
        if let markerRange = metadata.range(of: "DrawbridgePolylinePts:", options: .caseInsensitive) {
            let tokenStart = metadata[markerRange.upperBound...]
            return tokenStart
                .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init)
        }
        return nil
    }

    private func decodedPolygonPointsToken(_ token: String) -> [NSPoint]? {
        let pairs = token.split(separator: ";")
        guard pairs.count >= 3 else { return nil }
        var points: [NSPoint] = []
        points.reserveCapacity(pairs.count)
        for pair in pairs {
            let comps = pair.split(separator: ",")
            guard comps.count == 2,
                  let x = Double(comps[0]),
                  let y = Double(comps[1]) else {
                return nil
            }
            points.append(NSPoint(x: x, y: y))
        }
        return points.count >= 3 ? points : nil
    }

    func isHatchOverlayAnnotation(_ annotation: PDFAnnotation) -> Bool {
        let contents = (annotation.contents ?? "").lowercased()
        return contents.hasPrefix("drawbridgehatchoverlay|")
    }

    func rectangleFillColor(for annotation: PDFAnnotation) -> NSColor? {
        let type = (annotation.type ?? "").lowercased()
        guard type.contains("square") || type.contains("circle") else { return nil }
        let metadata = annotation.userName ?? ""
        if let markerRange = metadata.range(of: "DrawbridgeRectFill:", options: .caseInsensitive) {
            let tokenStart = metadata[markerRange.upperBound...]
            let token = tokenStart
                .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? ""
            if let parsed = parseRectFillToken(token) {
                return parsed
            }
        }
        if let interior = annotation.interiorColor {
            if interior.type == .pattern {
                return nil
            }
            return interior
        }
        return nil
    }

    func rectangleHatchBackgroundColor(for annotation: PDFAnnotation) -> NSColor? {
        let type = (annotation.type ?? "").lowercased()
        guard type.contains("square") || type.contains("circle") else { return nil }
        let metadata = annotation.userName ?? ""
        if let markerRange = metadata.range(of: "DrawbridgeRectBg:", options: .caseInsensitive) {
            let tokenStart = metadata[markerRange.upperBound...]
            let token = tokenStart
                .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? ""
            if let parsed = parseRectFillToken(token) {
                return parsed
            }
        }
        if let interior = annotation.interiorColor, interior.type != .pattern {
            return interior
        }
        return nil
    }

    private func parseRectFillToken(_ token: String) -> NSColor? {
        let comps = token.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? -1 }
        guard comps.count == 4 else { return nil }
        guard comps.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return NSColor(
            calibratedRed: CGFloat(comps[0]) / 255.0,
            green: CGFloat(comps[1]) / 255.0,
            blue: CGFloat(comps[2]) / 255.0,
            alpha: CGFloat(comps[3]) / 255.0
        )
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

    private func clearPendingArea() {
        pendingAreaPage = nil
        pendingAreaPointsInPage = []
        typedDistanceBuffer = ""
        hideTypedDistanceHUD()
        dragPreviewLayer.path = nil
        dragPreviewLayer.isHidden = true
    }

    func cancelPendingArea() {
        clearPendingArea()
    }

    func addHighlightForCurrentSelection() {
        addTextMarkupForCurrentSelection(
            type: .highlight,
            color: NSColor.systemYellow.withAlphaComponent(0.45),
            actionName: "Add Highlight"
        )
    }

    func addUnderlineForCurrentSelection() {
        addTextMarkupForCurrentSelection(
            type: .underline,
            color: NSColor.systemRed.withAlphaComponent(0.85),
            actionName: "Add Underline"
        )
    }

    func addStrikethroughForCurrentSelection() {
        addTextMarkupForCurrentSelection(
            type: .strikeOut,
            color: NSColor.systemRed.withAlphaComponent(0.85),
            actionName: "Add Strikethrough"
        )
    }

    private func addTextMarkupForCurrentSelection(
        type: PDFAnnotationSubtype,
        color: NSColor,
        actionName: String
    ) {
        // Compatibility entry point: annotation authoring is unavailable.
    }

    private func beginInlineTextEditing(at locationInView: NSPoint) {
        _ = commitInlineTextEditor(cancel: false)

        guard let page = page(for: locationInView, nearest: true) else {
            beep()
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
        guard guardOrBeep(isEditableTextAnnotation(annotation)) else { return }

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
        }
        if selectCommittedAnnotation {
            onAnnotationClicked?(page, annotation, false)
        } else {
            onAnnotationsBoxSelected?(page, [])
        }
        return annotation
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
            commandSelector == #selector(NSResponder.insertLineBreak(_:)) ||
            commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
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

    private func isLineEndpointEditable(_ annotation: PDFAnnotation) -> Bool {
        guard let type = annotation.type?.lowercased(), type.contains("ink") else { return false }
        let contents = (annotation.contents ?? "").lowercased()
        return contents.contains("line") || contents.contains("polyline")
    }

    private func lineSegmentInPage(for annotation: PDFAnnotation) -> Segment? {
        guard isLineEndpointEditable(annotation) else { return nil }
        let segments = annotationSegmentsInPage(for: annotation)
        guard !segments.isEmpty else { return nil }

        var endpoints: [NSPoint] = []
        endpoints.reserveCapacity(segments.count * 2)
        for segment in segments {
            endpoints.append(segment.0)
            endpoints.append(segment.1)
        }
        guard endpoints.count >= 2 else {
            return (start: segments[0].0, end: segments[0].1)
        }

        var bestPair: (NSPoint, NSPoint)?
        var bestDistanceSquared: CGFloat = -1
        for i in 0..<(endpoints.count - 1) {
            for j in (i + 1)..<endpoints.count {
                let dx = endpoints[j].x - endpoints[i].x
                let dy = endpoints[j].y - endpoints[i].y
                let d2 = dx * dx + dy * dy
                if d2 > bestDistanceSquared {
                    bestDistanceSquared = d2
                    bestPair = (endpoints[i], endpoints[j])
                }
            }
        }
        guard let pair = bestPair else { return nil }
        return (start: pair.0, end: pair.1)
    }

    func primaryLineSegmentInPage(for annotation: PDFAnnotation) -> (NSPoint, NSPoint)? {
        guard let segment = lineSegmentInPage(for: annotation) else { return nil }
        return (segment.start, segment.end)
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

    private func hideCalloutPreview() {
        calloutTextBoxPreviewLayer.isHidden = true
        calloutTextBoxPreviewLayer.path = nil
        dragPreviewLayer.isHidden = true
        dragPreviewLayer.path = nil
        dragPreviewLayer.lineDashPattern = nil
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

    private func isLinkAnnotation(_ annotation: PDFAnnotation) -> Bool {
        let type = (annotation.type ?? "").lowercased()
        if type == PDFAnnotationSubtype.link.rawValue.lowercased() {
            return true
        }
        if annotation.destination != nil {
            return true
        }
        if annotation.value(forAnnotationKey: .destination) as? PDFDestination != nil {
            return true
        }
        if annotation.action as? PDFActionGoTo != nil {
            return true
        }
        let marker = "DrawbridgeAutoSheetLink"
        if (annotation.userName?.contains(marker) ?? false) || (annotation.contents?.contains(marker) ?? false) {
            return true
        }
        return false
    }

    private func linkAnnotation(at pointInPage: NSPoint, on page: PDFPage) -> PDFAnnotation? {
        if let direct = page.annotation(at: pointInPage), isLinkAnnotation(direct) {
            return direct
        }
        let expandedHitInset: CGFloat = max(1.5, selectionHitDistanceInPage() * 0.35)
        var nearest: (annotation: PDFAnnotation, distance: CGFloat)?
        for annotation in page.annotations.reversed() {
            guard isLinkAnnotation(annotation) else { continue }
            let directBounds = annotation.bounds
            if directBounds.contains(pointInPage) {
                return annotation
            }
            let expandedBounds = directBounds.insetBy(dx: -expandedHitInset, dy: -expandedHitInset)
            guard expandedBounds.contains(pointInPage) else { continue }
            let distance = distanceToRect(pointInPage, rect: directBounds)
            if let currentNearest = nearest {
                if distance < currentNearest.distance {
                    nearest = (annotation, distance)
                }
            } else {
                nearest = (annotation, distance)
            }
        }
        return nearest?.annotation
    }

    @discardableResult
    private func followLinkIfPossible(_ annotation: PDFAnnotation) -> Bool {
        let destinationPageIndex = destinationPageIndexFromLinkMetadata(annotation)
        if let destinationPageIndex,
           let document,
           destinationPageIndex >= 0,
           destinationPageIndex < document.pageCount,
           let page = document.page(at: destinationPageIndex) {
            navigateToLinkTarget(page: page, destination: nil, fitWholePage: true)
            onViewportChanged?()
            return true
        }
        if let destination = annotation.destination,
           let resolved = destinationIfValidInCurrentDocument(destination) {
            navigateToLinkTarget(
                page: resolved.page,
                destination: resolved,
                fitWholePage: destinationPageIndex != nil || destinationRequestsWholePageFit(destination)
            )
            onViewportChanged?()
            return true
        }
        if let destination = annotation.value(forAnnotationKey: .destination) as? PDFDestination,
           let resolved = destinationIfValidInCurrentDocument(destination) {
            navigateToLinkTarget(
                page: resolved.page,
                destination: resolved,
                fitWholePage: destinationPageIndex != nil || destinationRequestsWholePageFit(destination)
            )
            onViewportChanged?()
            return true
        }
        if let action = annotation.action as? PDFActionGoTo,
           let resolved = destinationIfValidInCurrentDocument(action.destination) {
            navigateToLinkTarget(
                page: resolved.page,
                destination: resolved,
                fitWholePage: destinationPageIndex != nil || destinationRequestsWholePageFit(action.destination)
            )
            onViewportChanged?()
            return true
        }
        return false
    }

    private func destinationRequestsWholePageFit(_ destination: PDFDestination) -> Bool {
        let unspecified = kPDFDestinationUnspecifiedValue
        return destination.point.x == unspecified
            && destination.point.y == unspecified
            && destination.zoom == unspecified
    }

    private func navigateToLinkTarget(page: PDFPage?, destination: PDFDestination?, fitWholePage: Bool) {
        guard let page else {
            if let destination {
                navigateToDestinationWithHistory(destination)
            }
            return
        }
        if fitWholePage {
            navigateToPageFittingWholePageWithHistory(page)
            return
        }
        if let destination {
            navigateToDestinationWithHistory(destination)
        } else {
            navigateToPageWithHistory(page)
        }
    }

    /// Navigates to a page and fits its complete crop box in the viewport.
    ///
    /// PDFKit can report `scaleFactorForSizeToFit` using the previous page's
    /// layout immediately after a page change. Let automatic scaling establish
    /// the target page first, then lock in and reassert the target page's fit
    /// scale over the next layout passes.
    func navigateToPageFittingWholePageWithHistory(_ page: PDFPage) {
        if !applyingHistoryNavigation {
            pushBackHistoryCurrentLocation()
            navigationForwardStack.removeAll(keepingCapacity: true)
        }

        zoomAnchorGeneration &+= 1
        let generation = zoomAnchorGeneration
        autoScales = true
        go(to: page)
        forceZoomLayout()
        applyWholePageFit(page)
        scheduleWholePageFitCorrection(page: page, generation: generation, remainingPasses: 3)
        onViewportChanged?()
    }

    private func applyWholePageFit(_ page: PDFPage) {
        guard currentPage === page else { return }
        forceZoomLayout()
        let fitScale = scaleFactorForSizeToFit
        guard fitScale.isFinite, fitScale > 0 else { return }
        autoScales = false
        scaleFactor = min(max(minScaleFactor, fitScale), maxScaleFactor)
        forceZoomLayout()
        go(to: page)
        forceZoomLayout()
        centerWholePageInViewport(page)
    }

    func fitCurrentPageWidth() {
        guard let page = currentPage, let clip = contentClipView else { return }
        zoomAnchorGeneration &+= 1
        let anchor = normalizedVisibleCenter(on: page) ?? (x: 0.5, y: 0.5)
        autoScales = false
        forceZoomLayout()
        let pageRect = convert(page.bounds(for: displayBox), from: page).standardized
        guard pageRect.width > 0, clip.bounds.width > 8 else { return }
        let target = scaleFactor * (clip.bounds.width - 8) / pageRect.width
        guard target.isFinite, target > 0 else { return }
        if !applyingHistoryNavigation {
            pushBackHistoryCurrentLocation()
            navigationForwardStack.removeAll(keepingCapacity: true)
        }
        scaleFactor = min(max(minScaleFactor, target), maxScaleFactor)
        forceZoomLayout()
        let previousHistoryState = applyingHistoryNavigation
        applyingHistoryNavigation = true
        navigateToPageWithHistory(page, preservingNormalizedViewportCenter: anchor)
        applyingHistoryNavigation = previousHistoryState
        onViewportChanged?()
    }

    private func centerWholePageInViewport(_ page: PDFPage) {
        guard let clipView = contentClipView,
              let documentView else { return }
        let pageRectInPDFView = convert(page.bounds(for: displayBox), from: page).standardized
        let pageRectInDocumentView = documentView.convert(pageRectInPDFView, from: self).standardized
        let centeredOrigin = NSPoint(
            x: pageRectInDocumentView.midX - clipView.bounds.width * 0.5,
            y: pageRectInDocumentView.midY - clipView.bounds.height * 0.5
        )
        scrollContentClipView(to: centeredOrigin)
    }

    private func scheduleWholePageFitCorrection(
        page: PDFPage,
        generation: UInt,
        remainingPasses: Int
    ) {
        guard remainingPasses > 0 else { return }
        DispatchQueue.main.async { [weak self, weak page] in
            guard let self,
                  let page,
                  self.zoomAnchorGeneration == generation,
                  self.currentPage === page else { return }
            self.applyWholePageFit(page)
            self.scheduleWholePageFitCorrection(
                page: page,
                generation: generation,
                remainingPasses: remainingPasses - 1
            )
            self.onViewportChanged?()
        }
    }

    private func resetNavigationHistoryIfNeeded() {
        guard let document else {
            navigationBackStack.removeAll(keepingCapacity: true)
            navigationForwardStack.removeAll(keepingCapacity: true)
            navigationHistoryDocumentID = nil
            return
        }
        let docID = ObjectIdentifier(document)
        guard navigationHistoryDocumentID != docID else { return }
        navigationBackStack.removeAll(keepingCapacity: true)
        navigationForwardStack.removeAll(keepingCapacity: true)
        navigationHistoryDocumentID = docID
    }

    private func currentViewportHistoryEntry() -> ViewportHistoryEntry? {
        guard let document,
              let page = currentPage else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return nil }
        let point = currentDestination?.point ?? convert(NSPoint(x: bounds.midX, y: bounds.midY), to: page)
        return ViewportHistoryEntry(pageIndex: pageIndex, point: point, scale: scaleFactor)
    }

    private func isSameHistoryEntry(_ lhs: ViewportHistoryEntry, _ rhs: ViewportHistoryEntry) -> Bool {
        if lhs.pageIndex != rhs.pageIndex { return false }
        if abs(lhs.scale - rhs.scale) > 0.0005 { return false }
        return abs(lhs.point.x - rhs.point.x) <= 1.0 && abs(lhs.point.y - rhs.point.y) <= 1.0
    }

    private func pushBackHistoryCurrentLocation() {
        resetNavigationHistoryIfNeeded()
        guard let entry = currentViewportHistoryEntry() else { return }
        if let last = navigationBackStack.last, isSameHistoryEntry(last, entry) {
            return
        }
        navigationBackStack.append(entry)
        if navigationBackStack.count > navigationHistoryLimit {
            navigationBackStack.removeFirst(navigationBackStack.count - navigationHistoryLimit)
        }
    }

    private func applyHistoryEntry(_ entry: ViewportHistoryEntry) -> Bool {
        guard let document,
              entry.pageIndex >= 0,
              entry.pageIndex < document.pageCount,
              let page = document.page(at: entry.pageIndex) else {
            return false
        }
        zoomAnchorGeneration &+= 1
        applyingHistoryNavigation = true
        defer { applyingHistoryNavigation = false }
        autoScales = false
        let clampedScale = min(max(minScaleFactor, entry.scale), maxScaleFactor)
        scaleFactor = clampedScale
        go(to: PDFDestination(page: page, at: entry.point))
        onViewportChanged?()
        return true
    }

    func navigateToDestinationWithHistory(_ destination: PDFDestination) {
        if !applyingHistoryNavigation {
            pushBackHistoryCurrentLocation()
            navigationForwardStack.removeAll(keepingCapacity: true)
        }
        go(to: destination)
        onViewportChanged?()
    }

    func navigateToPageWithHistory(_ page: PDFPage) {
        if !applyingHistoryNavigation {
            pushBackHistoryCurrentLocation()
            navigationForwardStack.removeAll(keepingCapacity: true)
        }
        go(to: page)
        onViewportChanged?()
    }

    func navigateToPageWithHistory(
        _ page: PDFPage,
        preservingNormalizedViewportCenter anchor: (x: CGFloat, y: CGFloat)
    ) {
        if !applyingHistoryNavigation {
            pushBackHistoryCurrentLocation()
            navigationForwardStack.removeAll(keepingCapacity: true)
        }

        let pageBounds = page.bounds(for: displayBox)
        let targetPagePoint = NSPoint(
            x: pageBounds.minX + pageBounds.width * min(max(anchor.x, 0), 1),
            y: pageBounds.minY + pageBounds.height * min(max(anchor.y, 0), 1)
        )
        let desiredWindowPoint: NSPoint
        if let clipView = contentClipView {
            desiredWindowPoint = clipView.convert(
                NSPoint(x: clipView.bounds.midX, y: clipView.bounds.midY),
                to: nil
            )
        } else {
            desiredWindowPoint = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        }

        go(to: page)
        forceZoomLayout()
        zoomAnchorGeneration &+= 1
        let generation = zoomAnchorGeneration
        correctZoomAnchor(page: page, pagePoint: targetPagePoint, desiredWindowPoint: desiredWindowPoint)
        scheduleZoomAnchorCorrection(
            page: page,
            pagePoint: targetPagePoint,
            desiredWindowPoint: desiredWindowPoint,
            targetScale: scaleFactor,
            generation: generation,
            remainingPasses: 3
        )
        onViewportChanged?()
    }

    func navigateToSelectionWithHistory(_ selection: PDFSelection) {
        if !applyingHistoryNavigation {
            pushBackHistoryCurrentLocation()
            navigationForwardStack.removeAll(keepingCapacity: true)
        }
        go(to: selection)
        onViewportChanged?()
    }

    var canNavigateBackInHistory: Bool { resetNavigationHistoryIfNeeded(); return !navigationBackStack.isEmpty }
    var canNavigateForwardInHistory: Bool { resetNavigationHistoryIfNeeded(); return !navigationForwardStack.isEmpty }

    @discardableResult
    func navigateBackInHistory() -> Bool {
        resetNavigationHistoryIfNeeded()
        guard let target = navigationBackStack.popLast() else { return false }
        if let current = currentViewportHistoryEntry() {
            navigationForwardStack.append(current)
            if navigationForwardStack.count > navigationHistoryLimit {
                navigationForwardStack.removeFirst(navigationForwardStack.count - navigationHistoryLimit)
            }
        }
        return applyHistoryEntry(target)
    }

    @discardableResult
    func navigateForwardInHistory() -> Bool {
        resetNavigationHistoryIfNeeded()
        guard let target = navigationForwardStack.popLast() else { return false }
        if let current = currentViewportHistoryEntry() {
            navigationBackStack.append(current)
            if navigationBackStack.count > navigationHistoryLimit {
                navigationBackStack.removeFirst(navigationBackStack.count - navigationHistoryLimit)
            }
        }
        return applyHistoryEntry(target)
    }

    private func destinationIfValidInCurrentDocument(_ destination: PDFDestination) -> PDFDestination? {
        guard let page = destination.page else { return nil }
        guard let document else { return destination }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return nil }
        if let resolvedPage = document.page(at: pageIndex) {
            return PDFDestination(page: resolvedPage, at: destination.point)
        }
        return destination
    }

    private func destinationPageIndexFromLinkMetadata(_ annotation: PDFAnnotation) -> Int? {
        let candidates = [annotation.userName, annotation.contents]
        for candidate in candidates {
            guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            let marker = "DrawbridgeAutoSheetLink:"
            if raw.hasPrefix(marker) {
                let suffix = raw.dropFirst(marker.count)
                if let index = Int(suffix) {
                    return index
                }
            }
        }
        return nil
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

    private func translated(_ point: NSPoint, by offset: NSPoint) -> NSPoint {
        NSPoint(x: point.x + offset.x, y: point.y + offset.y)
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

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .option, .control]) else { return }
        if rectangleMarkup.handleToolShortcut(event) { return }
        switch event.keyCode {
        case 36, 76: _ = rectangleMarkup.finishPolyline()
        case 123, 126: onPageNavigationShortcut?(-1)
        case 124, 125: onPageNavigationShortcut?(1)
        case 51, 117: rectangleMarkup.deleteSelected()
        case 53:
            rectangleMarkup.escape()
            cancelRegionCaptureMode()
            setCurrentSelection(nil, animate: false)
        default:
            // Inherited PDFKit keyboard handling can focus editable form widgets.
            // PDF canvas keys only navigate; AppKit text fields retain normal editing.
            break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        handleWheelZoom(event)
    }

    private func emitInteractiveViewportFeedback(force: Bool = false) {
        let minInterval: CFAbsoluteTime = 1.0 / 45.0
        let now = CFAbsoluteTimeGetCurrent()

        let fireImmediately = force || (now - lastInteractiveViewportFeedbackAt) >= minInterval
        if fireImmediately {
            pendingInteractiveViewportFeedbackWorkItem?.cancel()
            pendingInteractiveViewportFeedbackWorkItem = nil
            lastInteractiveViewportFeedbackAt = now
            updateGridOverlayIfNeeded()
            rectangleMarkup.refresh()
            onViewportChanged?()
            return
        }

        let delay = max(0.001, minInterval - (now - lastInteractiveViewportFeedbackAt))
        guard pendingInteractiveViewportFeedbackWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingInteractiveViewportFeedbackWorkItem = nil
            self.lastInteractiveViewportFeedbackAt = CFAbsoluteTimeGetCurrent()
            self.updateGridOverlayIfNeeded()
            self.onViewportChanged?()
        }
        pendingInteractiveViewportFeedbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    @discardableResult
    func zoom(by factor: CGFloat, anchoredAtWindowPoint windowPoint: NSPoint? = nil) -> Bool {
        guard document != nil, factor > 0 else { return false }

        autoScales = false
        let targetScale = min(max(minScaleFactor, scaleFactor * factor), maxScaleFactor)
        guard targetScale != scaleFactor else { return false }

        let anchorPointInView = clampPointToBounds(resolvedZoomAnchorPoint(fromWindowPoint: windowPoint))
        guard contentClipView != nil else {
            scaleFactor = targetScale
            emitInteractiveViewportFeedback()
            return true
        }

        // Keep the pointer's position in the viewport, rather than its position in
        // PDFView's document coordinates. The latter changes while PDFKit lays out
        // the newly scaled page.
        let desiredAnchorPointInWindow = windowPoint ?? convert(anchorPointInView, to: nil)
        let anchorPage = page(for: anchorPointInView, nearest: false)
            ?? page(for: anchorPointInView, nearest: true)
        let anchorPagePoint = anchorPage.map { convert(anchorPointInView, to: $0) }
        zoomAnchorGeneration &+= 1
        let generation = zoomAnchorGeneration

        scaleFactor = targetScale
        forceZoomLayout()

        if let anchorPage, let anchorPagePoint {
            correctZoomAnchor(page: anchorPage, pagePoint: anchorPagePoint, desiredWindowPoint: desiredAnchorPointInWindow)
            scheduleZoomAnchorCorrection(
                page: anchorPage,
                pagePoint: anchorPagePoint,
                desiredWindowPoint: desiredAnchorPointInWindow,
                targetScale: targetScale,
                generation: generation,
                remainingPasses: 3
            )
        }
        emitInteractiveViewportFeedback()
        return true
    }

    private func forceZoomLayout() {
        layoutSubtreeIfNeeded()
        contentClipView?.enclosingScrollView?.layoutSubtreeIfNeeded()
        documentView?.layoutSubtreeIfNeeded()
    }

    private func scheduleZoomAnchorCorrection(
        page: PDFPage,
        pagePoint: NSPoint,
        desiredWindowPoint: NSPoint,
        targetScale: CGFloat,
        generation: UInt,
        remainingPasses: Int
    ) {
        guard remainingPasses > 0 else { return }
        // PDFKit may relayout its document view over several main-loop turns.
        // Reassert the anchor after each pass; a newer wheel event invalidates
        // this chain through zoomAnchorGeneration.
        DispatchQueue.main.async { [weak self, weak page] in
            guard let self,
                  let page,
                  self.zoomAnchorGeneration == generation,
                  abs(self.scaleFactor - targetScale) < 0.000_001 else { return }
            self.forceZoomLayout()
            self.correctZoomAnchor(
                page: page,
                pagePoint: pagePoint,
                desiredWindowPoint: desiredWindowPoint
            )
            self.scheduleZoomAnchorCorrection(
                page: page,
                pagePoint: pagePoint,
                desiredWindowPoint: desiredWindowPoint,
                targetScale: targetScale,
                generation: generation,
                remainingPasses: remainingPasses - 1
            )
            self.emitInteractiveViewportFeedback()
        }
    }

    private func correctZoomAnchor(page: PDFPage, pagePoint: NSPoint, desiredWindowPoint: NSPoint) {
        guard let clipView = contentClipView else { return }
        let anchoredPointInView = convert(pagePoint, from: page)
        let anchoredPointInWindow = convert(anchoredPointInView, to: nil)
        // NSClipView's coordinate scale changes with PDFView.scaleFactor. Convert
        // the screen-space error after scaling so the scroll delta uses the clip
        // view's current coordinate system.
        let anchoredPointInClip = clipView.convert(anchoredPointInWindow, from: nil)
        let desiredPointInClip = clipView.convert(desiredWindowPoint, from: nil)
        let deltaX = anchoredPointInClip.x - desiredPointInClip.x
        let deltaY = anchoredPointInClip.y - desiredPointInClip.y
        guard abs(deltaX) > 0.01 || abs(deltaY) > 0.01 else { return }

        let origin = clipView.bounds.origin
        scrollContentClipView(to: NSPoint(x: origin.x + deltaX, y: origin.y + deltaY))
    }

    private func resolvedZoomAnchorPoint(fromWindowPoint windowPoint: NSPoint?) -> NSPoint {
        if let windowPoint {
            return convert(windowPoint, from: nil)
        }
        if let window {
            let mouseInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            return convert(mouseInWindow, from: nil)
        }
        return NSPoint(x: bounds.midX, y: bounds.midY)
    }

    private func clampPointToBounds(_ point: NSPoint) -> NSPoint {
        guard !bounds.isEmpty else { return point }
        return NSPoint(
            x: min(max(bounds.minX, point.x), bounds.maxX),
            y: min(max(bounds.minY, point.y), bounds.maxY)
        )
    }

    func normalizedVisibleCenter(on page: PDFPage) -> (x: CGFloat, y: CGFloat)? {
        let pageBounds = page.bounds(for: displayBox)
        guard pageBounds.width > 0.01, pageBounds.height > 0.01 else { return nil }

        let centerInView: NSPoint
        if let clipView = contentClipView {
            let centerInClip = NSPoint(x: clipView.bounds.midX, y: clipView.bounds.midY)
            centerInView = convert(centerInClip, from: clipView)
        } else {
            centerInView = NSPoint(x: bounds.midX, y: bounds.midY)
        }
        let pagePoint = convert(centerInView, to: page)
        return (
            x: min(max((pagePoint.x - pageBounds.minX) / pageBounds.width, 0), 1),
            y: min(max((pagePoint.y - pageBounds.minY) / pageBounds.height, 0), 1)
        )
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

        let isTrackpadLike = event.hasPreciseScrollingDeltas
        if isTrackpadLike, event.momentumPhase != [] {
            return
        }

        let magnitude = abs(delta)
        let stepMagnitude: CGFloat
        if isTrackpadLike {
            // Trackpad: smoother and less jumpy under rapid tiny deltas.
            let capped = min(20.0, magnitude)
            stepMagnitude = pow(1.0045, capped)
        } else {
            // Mouse wheel: still decisive, but less abrupt between steps.
            let notches = max(1.0, min(6.0, magnitude))
            stepMagnitude = pow(1.09, notches)
        }

        let factor = delta > 0 ? stepMagnitude : (1.0 / stepMagnitude)
        _ = zoom(by: factor, anchoredAtWindowPoint: event.locationInWindow)
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
              let lastWindowPoint = middlePanLastWindowPoint else {
            super.otherMouseDragged(with: event)
            return
        }

        let lastView = convert(lastWindowPoint, from: nil)
        let currentView = convert(event.locationInWindow, from: nil)
        if let clipView = contentClipView {
            let lastClipPoint = clipView.convert(lastView, from: self)
            let currentClipPoint = clipView.convert(currentView, from: self)
            let dx = currentClipPoint.x - lastClipPoint.x
            let dy = currentClipPoint.y - lastClipPoint.y
            let origin = clipView.bounds.origin
            scrollContentClipView(to: NSPoint(x: origin.x - dx, y: origin.y - dy))
        }
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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard droppedPDFURL(from: sender) != nil else {
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
        guard let pdfURL = droppedPDFURL(from: sender) else { return false }
        onOpenDroppedPDF?(pdfURL)
        return true
    }

    private func droppedPDFURL(from sender: NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return nil
        }
        return urls.first(where: { $0.pathExtension.lowercased() == "pdf" || UTType(filenameExtension: $0.pathExtension)?.conforms(to: .pdf) == true })
    }

}
