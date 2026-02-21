import AppKit
import PDFKit
import UniformTypeIdentifiers

final class MarkupPDFView: PDFView, NSTextFieldDelegate {
    private typealias Segment = (start: NSPoint, end: NSPoint)
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
    enum ArrowEndStyle: Int {
        case solidArrow = 0
        case openArrow = 1
        case filledDot = 2
        case openDot = 3
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
    var textFontName: String = ".SFNS-Regular"
    var textFontSize: CGFloat = 15.0
    var calloutStrokeColor: NSColor = .systemRed
    var calloutLineWidth: CGFloat = 2.0
    var calloutArrowStyle: ArrowEndStyle = .solidArrow
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
    private var inlineEditingExistingAnnotation = false
    private var inlineOriginalTextContents: String?
    private var movingAnnotation: PDFAnnotation?
    private var movingAnnotationPage: PDFPage?
    private var movingAnnotationStartBounds: NSRect?
    private var movingStartPointInPage: NSPoint?
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
    private var pendingAreaPage: PDFPage?
    private var pendingAreaPointsInPage: [NSPoint] = []
    private var pendingMeasurePage: PDFPage?
    private var pendingMeasureStartInPage: NSPoint?
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
    private var isGridVisible = false
    private let gridSpacingInPoints: CGFloat = 24.0
    private let maxGridLinesPerAxis = 400

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(gridOverlayLayer)
        layer?.addSublayer(dragPreviewLayer)
        layer?.addSublayer(dropHighlightLayer)
        autoScales = true
        displayMode = .singlePage
        displayDirection = .vertical
        displaysPageBreaks = true
        backgroundColor = NSColor.windowBackgroundColor
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        let spacing = max(8.0, gridSpacingInPoints * scaleFactor)
        guard spacing.isFinite, spacing > 0 else {
            gridOverlayLayer.isHidden = true
            gridOverlayLayer.path = nil
            return
        }
        let xStart = floor(pageRectInView.minX / spacing) * spacing
        let yStart = floor(pageRectInView.minY / spacing) * spacing
        let xLineEstimate = Int(ceil(pageRectInView.width / spacing)) + 2
        let yLineEstimate = Int(ceil(pageRectInView.height / spacing)) + 2
        guard xLineEstimate <= maxGridLinesPerAxis, yLineEstimate <= maxGridLinesPerAxis else {
            // Avoid extreme path sizes on atypical documents/zoom levels.
            gridOverlayLayer.isHidden = true
            gridOverlayLayer.path = nil
            return
        }

        var i = 0
        var x = xStart
        while x <= pageRectInView.maxX, i <= maxGridLinesPerAxis {
            path.move(to: CGPoint(x: x, y: pageRectInView.minY))
            path.addLine(to: CGPoint(x: x, y: pageRectInView.maxY))
            if i % majorEvery == 0 {
                path.move(to: CGPoint(x: x + 0.25, y: pageRectInView.minY))
                path.addLine(to: CGPoint(x: x + 0.25, y: pageRectInView.maxY))
            }
            x += spacing
            i += 1
        }

        i = 0
        var y = yStart
        while y <= pageRectInView.maxY, i <= maxGridLinesPerAxis {
            path.move(to: CGPoint(x: pageRectInView.minX, y: y))
            path.addLine(to: CGPoint(x: pageRectInView.maxX, y: y))
            if i % majorEvery == 0 {
                path.move(to: CGPoint(x: pageRectInView.minX, y: y + 0.25))
                path.addLine(to: CGPoint(x: pageRectInView.maxX, y: y + 0.25))
            }
            y += spacing
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
        if toolMode == .measure {
            updateMeasurePreview(with: event)
            return
        }
        if toolMode == .polyline {
            let locationInView = convert(event.locationInWindow, from: nil)
            updatePolylinePreview(at: locationInView, orthogonal: event.modifierFlags.contains(.shift))
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
        guard toolMode == .callout else {
            super.mouseMoved(with: event)
            return
        }
        let locationInView = convert(event.locationInWindow, from: nil)
        updateCalloutPreview(at: locationInView)
    }

    override func mouseDown(with event: NSEvent) {
        let locationInView = convert(event.locationInWindow, from: nil)
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
            if let hit = nearestAnnotation(to: pointInPage, on: page, maxDistance: 10) {
                onAnnotationClicked?(page, hit)
                if event.clickCount >= 2, isEditableTextAnnotation(hit) {
                    beginInlineTextEditing(for: hit, on: page)
                    return
                }
                movingAnnotation = hit
                movingAnnotationPage = page
                movingAnnotationStartBounds = hit.bounds
                movingStartPointInPage = pointInPage
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
            let pointInPage = convert(locationInView, to: page)
            if pendingArrowPage == nil || pendingArrowPage !== page || pendingArrowStartInPage == nil {
                pendingArrowPage = page
                pendingArrowStartInPage = pointInPage
                updateArrowPreview(at: locationInView, orthogonal: event.modifierFlags.contains(.shift))
            } else if let start = pendingArrowStartInPage {
                let endInPage: NSPoint
                if event.modifierFlags.contains(.shift) {
                    let startInView = convert(start, from: page)
                    let snapped = orthogonalSnapPoint(anchor: startInView, current: locationInView)
                    endInPage = convert(snapped, to: page)
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
            dragStartInView = locationInView
            dragPage = page
            let path = CGMutablePath()
            path.move(to: locationInView)
            path.addLine(to: locationInView)
            dragPreviewLayer.strokeColor = penColor.cgColor
            dragPreviewLayer.fillColor = NSColor.clear.cgColor
            dragPreviewLayer.lineWidth = penLineWidth
            dragPreviewLayer.path = path
            dragPreviewLayer.isHidden = false
        case .polyline:
            if inlineTextField != nil {
                _ = commitInlineTextEditor(cancel: false)
            }
            guard let page = page(for: locationInView, nearest: true) else {
                super.mouseDown(with: event)
                return
            }
            let pointInPage = convert(locationInView, to: page)
            let constrainedPointInPage: NSPoint
            if event.modifierFlags.contains(.shift),
               pendingPolylinePage === page,
               let last = pendingPolylinePointsInPage.last {
                let lastInView = convert(last, from: page)
                let currentInView = convert(pointInPage, from: page)
                constrainedPointInPage = convert(orthogonalSnapPoint(anchor: lastInView, current: currentInView), to: page)
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
            updatePolylinePreview(at: locationInView, orthogonal: event.modifierFlags.contains(.shift))
        case .area:
            if inlineTextField != nil {
                _ = commitInlineTextEditor(cancel: false)
            }
            guard let page = page(for: locationInView, nearest: true) else {
                super.mouseDown(with: event)
                return
            }
            let pointInPage = convert(locationInView, to: page)
            let constrainedPointInPage: NSPoint
            if event.modifierFlags.contains(.shift),
               pendingAreaPage === page,
               let last = pendingAreaPointsInPage.last {
                let lastInView = convert(last, from: page)
                let currentInView = convert(pointInPage, from: page)
                constrainedPointInPage = convert(orthogonalSnapPoint(anchor: lastInView, current: currentInView), to: page)
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
            updateAreaPreview(at: locationInView, orthogonal: event.modifierFlags.contains(.shift))
        case .cloud, .rectangle:
            if inlineTextField != nil {
                _ = commitInlineTextEditor(cancel: false)
            }
            guard let page = page(for: locationInView, nearest: true) else {
                super.mouseDown(with: event)
                return
            }
            dragStartInView = locationInView
            dragPage = page
            dragPreviewLayer.isHidden = false
            dragPreviewLayer.path = CGPath(rect: NSRect(origin: locationInView, size: .zero), transform: nil)
        case .text:
            beginInlineTextEditing(at: locationInView)
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
                let pointInPage = convert(locationInView, to: page)
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
                dragStartInView = locationInView
                dragPage = page
                dragPreviewLayer.strokeColor = calibrationStrokeColor.cgColor
                dragPreviewLayer.fillColor = NSColor.clear.cgColor
                dragPreviewLayer.lineWidth = measurementLineWidth
                dragPreviewLayer.path = CGPath(rect: NSRect(origin: locationInView, size: .zero), transform: nil)
                dragPreviewLayer.isHidden = false
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
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
            guard let annotation = movingAnnotation,
                  let page = movingAnnotationPage,
                  let startBounds = movingAnnotationStartBounds,
                  let startPoint = movingStartPointInPage else {
                return
            }

            let locationInView = convert(event.locationInWindow, from: nil)
            let currentPoint = convert(locationInView, to: page)
            let dx = currentPoint.x - startPoint.x
            let dy = currentPoint.y - startPoint.y
            if abs(dx) < 0.01, abs(dy) < 0.01 {
                return
            }
            didMoveAnnotation = true
            annotation.bounds = startBounds.offsetBy(dx: dx, dy: dy)
            needsDisplay = true
            onViewportChanged?()
            return
        }

        if toolMode == .polyline {
            let locationInView = convert(event.locationInWindow, from: nil)
            updatePolylinePreview(at: locationInView, orthogonal: event.modifierFlags.contains(.shift))
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

        guard (toolMode == .pen || toolMode == .highlighter || toolMode == .line || toolMode == .cloud || toolMode == .rectangle || toolMode == .calibrate || toolMode == .grab) else {
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
        } else if toolMode == .line {
            let current = convert(event.locationInWindow, from: nil)
            guard let start = dragStartInView else { return }
            let target = event.modifierFlags.contains(.shift) ? orthogonalSnapPoint(anchor: start, current: current) : current
            let path = CGMutablePath()
            path.move(to: start)
            path.addLine(to: target)
            dragPreviewLayer.strokeColor = penColor.cgColor
            dragPreviewLayer.fillColor = NSColor.clear.cgColor
            dragPreviewLayer.lineWidth = penLineWidth
            dragPreviewLayer.path = path
        } else if toolMode == .cloud || toolMode == .rectangle || toolMode == .grab {
            let current = convert(event.locationInWindow, from: nil)
            guard let start = dragStartInView else { return }
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
            let current = convert(event.locationInWindow, from: nil)
            guard let start = dragStartInView else { return }
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
            didMoveAnnotation = false
            fenceStartInView = nil
            fencePage = nil
            if (toolMode != .measure || pendingMeasureStartInPage == nil) &&
                !(toolMode == .arrow && pendingArrowStartInPage != nil) &&
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
                guard rectInView.width > 4, rectInView.height > 4 else { return }
                let p1 = convert(rectInView.origin, to: page)
                let p2 = convert(NSPoint(x: rectInView.maxX, y: rectInView.maxY), to: page)
                let box = normalizedRect(from: p1, to: p2)
                let hits = page.annotations.filter { $0.bounds.intersects(box) }
                onAnnotationsBoxSelected?(page, hits)
                return
            }
            guard didMoveAnnotation,
                  let page = movingAnnotationPage,
                  let annotation = movingAnnotation,
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

        if toolMode == .line,
           let start = dragStartInView,
           let page = dragPage {
            let endRaw = convert(event.locationInWindow, from: nil)
            let end = event.modifierFlags.contains(.shift) ? orthogonalSnapPoint(anchor: start, current: endRaw) : endRaw
            let startInPage = convert(start, to: page)
            let endInPage = convert(end, to: page)
            addLineAnnotation(from: startInPage, to: endInPage, on: page, actionName: "Add Line", contents: "Line")
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

        let end = convert(event.locationInWindow, from: nil)
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

        let dx = localEnd.x - localStart.x
        let dy = localEnd.y - localStart.y
        let len = hypot(dx, dy)
        if len > 0.001 {
            let ux = dx / len
            let uy = dy / len
            let arrowLength = max(10.0, arrowLineWidth * 3.0)
            let halfAngle = CGFloat.pi / 7.0
            let left = NSPoint(
                x: localEnd.x - arrowLength * (ux * cos(halfAngle) - uy * sin(halfAngle)),
                y: localEnd.y - arrowLength * (uy * cos(halfAngle) + ux * sin(halfAngle))
            )
            let right = NSPoint(
                x: localEnd.x - arrowLength * (ux * cos(-halfAngle) - uy * sin(-halfAngle)),
                y: localEnd.y - arrowLength * (uy * cos(-halfAngle) + ux * sin(-halfAngle))
            )
            switch calloutArrowStyle {
            case .solidArrow, .openArrow:
                path.move(to: left)
                path.line(to: localEnd)
                path.line(to: right)
                if calloutArrowStyle == .solidArrow {
                    path.line(to: left)
                }
            case .filledDot, .openDot:
                break
            }
        }

        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        annotation.color = arrowStrokeColor
        path.lineWidth = arrowLineWidth
        assignLineWidth(arrowLineWidth, to: annotation)
        annotation.contents = "Arrow|Style:\(calloutArrowStyle.rawValue)"
        annotation.add(path)
        page.addAnnotation(annotation)
        onAnnotationAdded?(page, annotation, "Add Arrow")

        if calloutArrowStyle == .filledDot || calloutArrowStyle == .openDot {
            let radius = max(3.0, arrowLineWidth * 1.8)
            let dotBounds = NSRect(x: end.x - radius, y: end.y - radius, width: radius * 2.0, height: radius * 2.0)
            let dot = PDFAnnotation(bounds: dotBounds, forType: .circle, withProperties: nil)
            dot.color = arrowStrokeColor
            dot.interiorColor = (calloutArrowStyle == .filledDot) ? arrowStrokeColor : .clear
            assignLineWidth(max(1.0, arrowLineWidth), to: dot)
            dot.contents = "Arrow Dot|Style:\(calloutArrowStyle.rawValue)"
            page.addAnnotation(dot)
            onAnnotationAdded?(page, dot, "Add Arrow")
        }
    }

    private func assignLineWidth(_ lineWidth: CGFloat, to annotation: PDFAnnotation) {
        let normalized = max(0.1, lineWidth)
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
            targetInView = orthogonal ? orthogonalSnapPoint(anchor: startInView, current: locationInView) : locationInView
        } else {
            targetInView = startInView
        }

        let path = CGMutablePath()
        path.move(to: startInView)
        path.addLine(to: targetInView)
        addArrowDecoration(to: path, tip: targetInView, from: startInView, style: calloutArrowStyle, lineWidth: arrowLineWidth)

        dragPreviewLayer.strokeColor = arrowStrokeColor.cgColor
        dragPreviewLayer.fillColor = NSColor.clear.cgColor
        dragPreviewLayer.lineWidth = arrowLineWidth
        dragPreviewLayer.lineDashPattern = [6, 4]
        dragPreviewLayer.path = path
        dragPreviewLayer.isHidden = false
    }

    private func clearPendingArrow() {
        pendingArrowPage = nil
        pendingArrowStartInPage = nil
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

        // Use an offscreen capture field so typing updates only the live PDF annotation.
        let field = NSTextField(frame: NSRect(x: -10_000, y: -10_000, width: 1, height: 1))
        let resolvedFont = NSFont(name: textFontName, size: max(6.0, textFontSize))
            ?? NSFont.systemFont(ofSize: max(6.0, textFontSize), weight: .regular)
        field.font = resolvedFont
        field.textColor = .clear
        field.drawsBackground = false
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.delegate = self
        field.placeholderString = nil

        addSubview(field)
        inlineTextField = field
        inlineTextPage = page
        inlineTextAnchorInPage = convert(locationInView, to: page)
        inlineEditingExistingAnnotation = false
        inlineOriginalTextContents = nil

        let anchor = inlineTextAnchorInPage!
        let bounds = calloutTextAnnotationBounds(forAnchorInPage: anchor)
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = " "
        annotation.font = resolvedFont
        annotation.fontColor = textForegroundColor
        annotation.color = textBackgroundColor
        annotation.alignment = .left
        if toolMode == .callout, let calloutGroupID = pendingCalloutGroupID {
            annotation.userName = Self.calloutGroupPrefix + calloutGroupID
        }
        page.addAnnotation(annotation)
        inlineLiveTextAnnotation = annotation

        window?.makeFirstResponder(field)
    }

    private func beginInlineTextEditing(for annotation: PDFAnnotation, on page: PDFPage) {
        _ = commitInlineTextEditor(cancel: false)
        guard isEditableTextAnnotation(annotation) else {
            NSSound.beep()
            return
        }

        let field = NSTextField(frame: NSRect(x: -10_000, y: -10_000, width: 1, height: 1))
        let size = max(6.0, annotation.font?.pointSize ?? textFontSize)
        let resolvedFont = NSFont(name: textFontName, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .regular)
        field.font = resolvedFont
        field.textColor = .clear
        field.drawsBackground = false
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.delegate = self
        field.stringValue = annotation.contents ?? ""

        addSubview(field)
        inlineTextField = field
        inlineTextPage = page
        inlineTextAnchorInPage = nil
        inlineLiveTextAnnotation = annotation
        inlineEditingExistingAnnotation = true
        inlineOriginalTextContents = annotation.contents ?? ""

        window?.makeFirstResponder(field)
        if let editor = window?.fieldEditor(true, for: field) as? NSTextView {
            editor.selectAll(nil)
        }
    }

    private func commitInlineTextEditor(cancel: Bool) -> PDFAnnotation? {
        guard let field = inlineTextField else { return nil }
        let wasEditingExisting = inlineEditingExistingAnnotation
        let originalText = inlineOriginalTextContents
        defer {
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
            } else {
                page.removeAnnotation(annotation)
            }
            return nil
        }
        annotation.contents = text
        if wasEditingExisting {
            let previousText = originalText ?? ""
            if previousText != text {
                onAnnotationTextEdited?(page, annotation, previousText)
            }
        } else {
            onAnnotationAdded?(page, annotation, "Add Text")
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
        return type.contains("freetext")
    }

    private func handleCalloutClick(at locationInView: NSPoint) {
        guard let page = page(for: locationInView, nearest: true) else {
            NSSound.beep()
            return
        }
        let pointInPage = convert(locationInView, to: page)

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
            updateCalloutPreview(at: locationInView)
            return
        }

        if pendingCalloutTipInPage == nil {
            pendingCalloutTipInPage = pointInPage
            updateCalloutPreview(at: locationInView)
            return
        }
        if pendingCalloutElbowInPage == nil {
            pendingCalloutElbowInPage = pointInPage
            updateCalloutPreview(at: locationInView)
            return
        }

        hideCalloutPreview()
        beginInlineTextEditing(at: locationInView)
    }

    private func clearPendingCallout() {
        pendingCalloutPage = nil
        pendingCalloutTipInPage = nil
        pendingCalloutElbowInPage = nil
        pendingCalloutGroupID = nil
        hideCalloutPreview()
    }

    func cancelPendingCallout() {
        clearPendingCallout()
    }

    func cancelPendingMeasurement() {
        pendingMeasurePage = nil
        pendingMeasureStartInPage = nil
        if toolMode == .measure {
            dragPreviewLayer.isHidden = true
            dragPreviewLayer.path = nil
        }
    }

    private func updateMeasurePreview(with event: NSEvent) {
        guard toolMode == .measure,
              let page = pendingMeasurePage,
              let start = pendingMeasureStartInPage else {
            return
        }
        let locationInView = convert(event.locationInWindow, from: nil)
        guard self.page(for: locationInView, nearest: true) == page else { return }
        let endInPage = convert(locationInView, to: page)
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
        if let locationInView,
           self.page(for: locationInView, nearest: true) == page {
            if orthogonal, let last = pendingPolylinePointsInPage.last {
                let lastInView = convert(last, from: page)
                path.addLine(to: orthogonalSnapPoint(anchor: lastInView, current: locationInView))
            } else {
                path.addLine(to: locationInView)
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

        let hoverInPage = convert(locationInView, to: page)
        let tipInView = convert(tipInPage, from: page)
        let hoverInView = convert(hoverInPage, from: page)

        let path = CGMutablePath()
        if let elbowInPage = pendingCalloutElbowInPage {
            let elbowInView = convert(elbowInPage, from: page)
            let textRectInPage = calloutTextAnnotationBounds(forAnchorInPage: hoverInPage)
            let textRect = rectInView(fromPageRect: textRectInPage, on: page)
            let anchor = nearestPointOnRectBoundary(textRect, toward: elbowInView)
            path.addRect(textRect.integral)
            path.move(to: anchor)
            path.addLine(to: elbowInView)
            path.addLine(to: tipInView)
            addArrowDecoration(to: path, tip: tipInView, from: elbowInView, style: calloutArrowStyle, lineWidth: calloutLineWidth)
        } else {
            path.move(to: hoverInView)
            path.addLine(to: tipInView)
            addArrowDecoration(to: path, tip: tipInView, from: hoverInView, style: calloutArrowStyle, lineWidth: calloutLineWidth)
        }

        dragPreviewLayer.strokeColor = calloutStrokeColor.cgColor
        dragPreviewLayer.fillColor = NSColor.clear.cgColor
        dragPreviewLayer.lineWidth = calloutLineWidth
        dragPreviewLayer.lineDashPattern = [6, 4]
        dragPreviewLayer.path = path
        dragPreviewLayer.isHidden = false
    }

    private func calloutTextAnnotationBounds(forAnchorInPage anchor: NSPoint) -> NSRect {
        let size = max(6.0, textFontSize)
        let width = max(240.0, size * 12.0)
        let height = max(42.0, size * 2.2)
        return NSRect(x: anchor.x, y: anchor.y - (height * 0.75), width: width, height: height)
    }

    private func rectInView(fromPageRect pageRect: NSRect, on page: PDFPage) -> NSRect {
        let v1 = convert(pageRect.origin, from: page)
        let v2 = convert(NSPoint(x: pageRect.maxX, y: pageRect.maxY), from: page)
        return normalizedRect(from: v1, to: v2)
    }

    private func addArrowDecoration(to path: CGMutablePath, tip: NSPoint, from base: NSPoint, style: ArrowEndStyle, lineWidth: CGFloat) {
        let dx = tip.x - base.x
        let dy = tip.y - base.y
        let dist = hypot(dx, dy)
        guard dist > 0.001 else { return }
        let ux = dx / dist
        let uy = dy / dist
        let length = max(10.0, lineWidth * 3.0)
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
        case .solidArrow, .openArrow:
            path.move(to: left)
            path.addLine(to: tip)
            path.addLine(to: right)
            if style == .solidArrow {
                path.addLine(to: left)
            }
        case .filledDot, .openDot:
            let radius = max(3.0, lineWidth * 1.8)
            let dotRect = NSRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2.0, height: radius * 2.0)
            path.addEllipse(in: dotRect)
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
        for annotation in page.annotations {
            guard annotation.shouldDisplay else { continue }
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
        return best
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
        let anchor = nearestPointOnRectBoundary(textAnnotation.bounds, toward: elbow)
        let points = [anchor, elbow, tip]

        let minX = points.map(\.x).min() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let pad = max(6.0, calloutLineWidth * 2.0)
        let bounds = NSRect(x: minX - pad, y: minY - pad, width: (maxX - minX) + pad * 2.0, height: (maxY - minY) + pad * 2.0)

        let path = NSBezierPath()
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: anchor.x - bounds.origin.x, y: anchor.y - bounds.origin.y))
        path.line(to: NSPoint(x: elbow.x - bounds.origin.x, y: elbow.y - bounds.origin.y))
        path.line(to: NSPoint(x: tip.x - bounds.origin.x, y: tip.y - bounds.origin.y))

        let dx = tip.x - elbow.x
        let dy = tip.y - elbow.y
        let length = hypot(dx, dy)
        if length > 0.001 {
            let ux = dx / length
            let uy = dy / length
            let arrowLength = max(10.0, calloutLineWidth * 3.0)
            let halfAngle = CGFloat.pi / 7.0
            let left = NSPoint(
                x: tip.x - arrowLength * (ux * cos(halfAngle) - uy * sin(halfAngle)),
                y: tip.y - arrowLength * (uy * cos(halfAngle) + ux * sin(halfAngle))
            )
            let right = NSPoint(
                x: tip.x - arrowLength * (ux * cos(-halfAngle) - uy * sin(-halfAngle)),
                y: tip.y - arrowLength * (uy * cos(-halfAngle) + ux * sin(-halfAngle))
            )
            switch calloutArrowStyle {
            case .solidArrow, .openArrow:
                path.move(to: NSPoint(x: left.x - bounds.origin.x, y: left.y - bounds.origin.y))
                path.line(to: NSPoint(x: tip.x - bounds.origin.x, y: tip.y - bounds.origin.y))
                path.line(to: NSPoint(x: right.x - bounds.origin.x, y: right.y - bounds.origin.y))
                if calloutArrowStyle == .solidArrow {
                    path.line(to: NSPoint(x: left.x - bounds.origin.x, y: left.y - bounds.origin.y))
                }
            case .filledDot, .openDot:
                break
            }
        }

        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        annotation.color = calloutStrokeColor
        path.lineWidth = calloutLineWidth
        assignLineWidth(calloutLineWidth, to: annotation)
        annotation.contents = "Callout Leader|Arrow:\(calloutArrowStyle.rawValue)"
        if let calloutGroupID = calloutGroupID(for: textAnnotation) {
            annotation.userName = Self.calloutGroupPrefix + calloutGroupID
        }
        annotation.add(path)
        page.addAnnotation(annotation)
        onAnnotationAdded?(page, annotation, "Add Callout")

        if calloutArrowStyle == .filledDot || calloutArrowStyle == .openDot {
            let radius = max(3.0, calloutLineWidth * 1.8)
            let dotBounds = NSRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2.0, height: radius * 2.0)
            let dot = PDFAnnotation(bounds: dotBounds, forType: .circle, withProperties: nil)
            dot.color = calloutStrokeColor
            dot.interiorColor = (calloutArrowStyle == .filledDot) ? calloutStrokeColor : .clear
            assignLineWidth(max(1.0, calloutLineWidth), to: dot)
            dot.contents = "Callout Arrow Dot|Arrow:\(calloutArrowStyle.rawValue)"
            if let calloutGroupID = calloutGroupID(for: textAnnotation) {
                dot.userName = Self.calloutGroupPrefix + calloutGroupID
            }
            page.addAnnotation(dot)
            onAnnotationAdded?(page, dot, "Add Callout")
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

    func calloutArrowStyle(for annotation: PDFAnnotation) -> ArrowEndStyle? {
        guard let contents = annotation.contents else { return nil }
        if let range = contents.range(of: "Arrow:") {
            let raw = contents[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int(raw), let style = ArrowEndStyle(rawValue: value) {
                return style
            }
        }
        if contents.lowercased().contains("callout leader") {
            return .solidArrow
        }
        return nil
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

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: [.command, .option, .control]) {
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
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: [.command, .option, .control]),
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
