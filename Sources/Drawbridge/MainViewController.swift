import AppKit
import ImageIO
@preconcurrency
import PDFKit
import UniformTypeIdentifiers
import Vision

private final class NavigationResizeHandleView: NSView {
    private var trackingAreaRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaRef = tracking
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }
}

@MainActor
final class MainViewController: NSViewController, NSToolbarDelegate, NSMenuItemValidation, NSSplitViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    struct PDFPageStoredGeometry {
        let rotation: Int
        let mediaBox: NSRect
        let cropBox: NSRect
        let bleedBox: NSRect
        let trimBox: NSRect
        let artBox: NSRect

        init(page: PDFPage) {
            rotation = page.rotation
            mediaBox = page.bounds(for: .mediaBox)
            cropBox = page.bounds(for: .cropBox)
            bleedBox = page.bounds(for: .bleedBox)
            trimBox = page.bounds(for: .trimBox)
            artBox = page.bounds(for: .artBox)
        }

        func apply(to page: PDFPage) {
            page.rotation = rotation
            page.setBounds(mediaBox, for: .mediaBox)
            page.setBounds(cropBox, for: .cropBox)
            page.setBounds(bleedBox, for: .bleedBox)
            page.setBounds(trimBox, for: .trimBox)
            page.setBounds(artBox, for: .artBox)
        }
    }

    struct PDFDocumentBox: @unchecked Sendable {
        let document: PDFDocument
    }
    private struct NormalizedPageRect {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }
    private struct AutoNamedSheet {
        let pageIndex: Int
        let sheetNumber: String
        let sheetTitle: String
    }
    private struct OCRLineHit {
        let text: String
        let rectInPage: NSRect
    }
    private struct ZoneDetectionCandidate {
        let rectInPage: NSRect
        let strategy: String
        let allowOCR: Bool
        let usedFallback: Bool
    }
    private struct ZoneDetectionResult {
        let tokens: [String]
        let rawText: String
        let strategy: String
        let usedFallback: Bool
    }
    private struct BatchLinkZonePageDiagnostic {
        let pageIndex: Int
        let pageLabel: String
        let detectedToken: String?
        let strategy: String
        let rawTextPreview: String
        let failureReason: String?
        let usedFallback: Bool
    }
    enum AnnotationReorderAction: String {
        case bringToFront
        case sendToBack
        case bringForward
        case sendBackward

        var undoTitle: String {
            switch self {
            case .bringToFront: return "Bring Markup to Front"
            case .sendToBack: return "Send Markup to Back"
            case .bringForward: return "Bring Markup Forward"
            case .sendBackward: return "Send Markup Backward"
            }
        }
    }
    private enum AutoNameCapturePhase {
        case sheetNumber
        case sheetTitle
    }
    struct ToolSettingsState {
        var strokeColor: NSColor
        var fillColor: NSColor
        var outlineColor: NSColor = .clear
        var opacity: CGFloat
        var lineWeightLevel: Int
        var outlineWidth: CGFloat = 0
        var fontName: String
        var fontSize: CGFloat
        var calloutArrowStyleRawValue: Int
        var arrowHeadSize: CGFloat
        var rectangleHatchStyleRawValue: Int
        var hatchBackgroundColor: NSColor
    }
    enum SearchHit {
        case document(selection: PDFSelection, pageIndex: Int, preview: String)
        case markup(pageIndex: Int, annotation: PDFAnnotation, preview: String)
    }
    struct MarkupClipboardRecord: Codable {
        let pageIndex: Int
        let archivedAnnotation: Data
        let lineWidth: CGFloat?
    }
    struct MarkupClipboardPayload: Codable {
        let sourceDocumentPageCount: Int
        let records: [MarkupClipboardRecord]
    }

    let lineWeightLevels = Array(1...10)
    let standardFontSizes = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 60, 72]
    private let autosaveIntervalSeconds: TimeInterval = 120
    let snapshotStore = ProjectSnapshotStore()
    let markupClipboardPasteboardType = NSPasteboard.PasteboardType("com.drawbridge.markups")
    private let chromeBackgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
    private let panelBackgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1.0)
    private let sidebarBackgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1.0)
    let snapshotLayerOptions = [
        "DEFAULT",
        "ARCHITECTURAL",
        "STRUCTURAL",
        "MECHANICAL",
        "ELECTRICAL",
        "PLUMBING",
        "CIVL",
        "LANDSCAPE"
    ]

    static let defaultsAdaptiveIndexCapEnabledKey = "DrawbridgeAdaptiveIndexCapEnabled"
    static let defaultsIndexCapKey = "DrawbridgeIndexCap"
    static let defaultsWatchdogEnabledKey = "DrawbridgeWatchdogEnabled"
    static let defaultsWatchdogThresholdSecondsKey = "DrawbridgeWatchdogThresholdSeconds"
    static let defaultsHyperlinkHighlightsVisibleKey = "DrawbridgeHyperlinkHighlightsVisible"
    static let defaultsHyperlinkHighlightsDefaultMigrationKey = "DrawbridgeHyperlinkHighlightsDefaultMigrationV1"
    private static let markupCopyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyMMdd"
        return formatter
    }()

    private let rulerThickness: CGFloat = 22
    private let showNavigationPane = true
    let pdfView = MarkupPDFView(frame: .zero)
    private let pdfCanvasContainer = StartupDropView(frame: .zero)
    private let bookmarksContainer = NSView(frame: .zero)
    private let navigationResizeHandle = NavigationResizeHandleView(frame: .zero)
    private let navigationTitleLabel = NSTextField(labelWithString: "Navigation")
    private let navigationModeControl = NSSegmentedControl(labels: ["Pages", "Bookmarks"], trackingMode: .selectOne, target: nil, action: nil)
    private let addPageButton = NSButton(title: "", target: nil, action: nil)
    private let pagesTableView = NSTableView(frame: .zero)
    private let thumbnailView = PDFThumbnailView(frame: .zero)
    private let thumbnailScrollView = NSScrollView(frame: .zero)
    private let thumbnailsEmptyLabel = NSTextField(labelWithString: "No Pages")
    private let bookmarksScrollView = NSScrollView(frame: .zero)
    private let bookmarksOutlineView = NSOutlineView(frame: .zero)
    private let bookmarksEmptyLabel = NSTextField(labelWithString: "No Bookmarks")
    private let pdfContentsTitleLabel = NSTextField(labelWithString: "PDF Contents")
    private let pdfContentsSummaryLabel = NSTextField(labelWithString: "No PDF loaded")
    private let horizontalRuler = PDFRulerView(orientation: .horizontal)
    private let verticalRuler = PDFRulerView(orientation: .vertical)
    private let rulerCornerView = NSView(frame: .zero)
    private let splitView = NSSplitView(frame: .zero)
    private let emptyStateView = StartupDropView(frame: .zero)
    private let emptyStateTitle = NSTextField(labelWithString: "Open or create a PDF to start marking up")
    private let emptyStateOpenButton = NSButton(title: "Open PDF", target: nil, action: nil)
    private let emptyStateRecentButton = NSButton(title: "Open Recent", target: nil, action: nil)
    private let emptyStateSampleButton = NSButton(title: "Create New", target: nil, action: nil)
    private let emptyStateBatchMobileButton = NSButton(title: "Batch Export to iPhone / iPad", target: nil, action: nil)
    let markupsTable = NSTableView(frame: .zero)
    private let markupsCountLabel = NSTextField(labelWithString: "0 items")
    private let markupFilterField = NSSearchField(frame: .zero)
    let measurementScaleField = NSTextField(frame: .zero)
    let measurementUnitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let applyScaleButton = NSButton(title: "Apply Scale", target: nil, action: nil)
    private let actionsPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let autoNameSheetsButton = NSButton(title: "", target: nil, action: nil)
    private let batchLinkSheetsButton = NSButton(title: "", target: nil, action: nil)
    private let flattenPDFButton = NSButton(title: "", target: nil, action: nil)
    private let reduceFileSizeButton = NSButton(title: "", target: nil, action: nil)
    private let highlightButton = NSButton(title: "Highlight Selection", target: nil, action: nil)
    private let exportButton = NSButton(title: "Save As PDF", target: nil, action: nil)
    private let gridToggleButton = NSButton(title: "", target: nil, action: nil)
    private let refreshMarkupsButton = NSButton(title: "Refresh Markups", target: nil, action: nil)
    private let deleteMarkupButton = NSButton(title: "Delete Markup", target: nil, action: nil)
    private let editMarkupButton = NSButton(title: "Edit Markup Text", target: nil, action: nil)
    let pageJumpField = ClickOnlyTextField(frame: .zero)
    let scalePresetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let measureLabel = NSTextField(labelWithString: "Measure:")
    private let toolbarControlsStack = NSStackView(frame: .zero)
    private let secondaryToolbarControlsStack = NSStackView(frame: .zero)
    private let toolbarModeGroupsStack = NSStackView(frame: .zero)
    private let toolbarQuickControlsStack = NSStackView(frame: .zero)
    let toolbarSearchField = NSSearchField(frame: .zero)
    let toolbarSearchPrevButton = NSButton(title: "", target: nil, action: nil)
    let toolbarSearchNextButton = NSButton(title: "", target: nil, action: nil)
    let toolbarSearchCountLabel = NSTextField(labelWithString: "")
    var searchPanel: NSPanel?
    private let documentTabsBar = NSView(frame: .zero)
    private let documentTabsScrollView = NSScrollView(frame: .zero)
    private let documentTabsStack = NSStackView(frame: .zero)
    private let statusBar = NSView(frame: .zero)
    private let busyOverlayView = NSView(frame: .zero)
    private let captureToastView = NSView(frame: .zero)
    private let captureToastLabel = NSTextField(labelWithString: "Captured")
    private lazy var captureSound: NSSound? = {
        let grabPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        let shutterPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif"
        if FileManager.default.fileExists(atPath: grabPath) {
            return NSSound(contentsOfFile: grabPath, byReference: true)
        }
        if FileManager.default.fileExists(atPath: shutterPath) {
            return NSSound(contentsOfFile: shutterPath, byReference: true)
        }
        return nil
    }()
    private let busyStatusLabel = NSTextField(labelWithString: "Working…")
    private let busyDetailLabel = NSTextField(labelWithString: "")
    private let busySubdetailLabel = NSTextField(labelWithString: "")
    private let busyProgressIndicator = NSProgressIndicator(frame: .zero)
    private let busyCancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var busyCancelHandler: (() -> Void)?
    private var isJPEGExportCancellationRequested = false
    private var isBatchJPEGExportCancellationRequested = false
    private let statusToolLabel = NSTextField(labelWithString: "Tool: Pen")
    let statusToolsHintLabel = NSTextField(labelWithString: "Shortcuts customizable in Drawbridge > Keyboard Shortcuts…")
    private let statusPageSizeLabel = NSTextField(labelWithString: "Size: -")
    private let statusPageLabel = NSTextField(labelWithString: "Page: -")
    private let statusZoomLabel = NSTextField(labelWithString: "Zoom: 100%")
    private let statusScaleLabel = NSTextField(labelWithString: "Scale: 1.0 ft")
    private let measurementCountLabel = NSTextField(labelWithString: "Measurements: 0")
    private let measurementTotalLabel = NSTextField(labelWithString: "Total Length: 0")
    private let toolSettingsSectionButton = NSButton(title: "Tool Settings", target: nil, action: nil)
    private let toolSettingsSidebarToggleButton = NSButton(title: "", target: nil, action: nil)
    private let collapsedSidebarRevealButton = NSButton(title: "", target: nil, action: nil)
    private let toolSettingsSectionContent = NSStackView(frame: .zero)
    private let snapSectionButton = NSButton(title: "", target: nil, action: nil)
    private let snapSectionContent = NSStackView(frame: .zero)
    private let snapRowsStack = NSStackView(frame: .zero)
    private let layersSectionButton = NSButton(title: "", target: nil, action: nil)
    let layersSectionContent = NSStackView(frame: .zero)
    let layersRowsStack = NSStackView(frame: .zero)
    let toolSettingsToolLabel = NSTextField(labelWithString: "Active Tool: Pen")
    let toolSettingsStrokeTitleLabel = NSTextField(labelWithString: "Color:")
    let toolSettingsFillTitleLabel = NSTextField(labelWithString: "Fill:")
    let toolSettingsStrokeColorWell = NSColorWell(frame: .zero)
    let toolSettingsFillColorWell = NSColorWell(frame: .zero)
    let toolSettingsOutlineTitleLabel = NSTextField(labelWithString: "Outline:")
    let toolSettingsOutlineColorWell = NSColorWell(frame: .zero)
    let toolSettingsOutlineWidthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let toolSettingsFontTitleLabel = NSTextField(labelWithString: "Text Size:")
    let toolSettingsFontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let toolSettingsFontSizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let toolSettingsArrowTitleLabel = NSTextField(labelWithString: "Arrow End:")
    let toolSettingsArrowPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let toolSettingsArrowSizeTitleLabel = NSTextField(labelWithString: "Arrow Size:")
    let toolSettingsArrowSizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let toolSettingsHatchTitleLabel = NSTextField(labelWithString: "Hatch:")
    let toolSettingsHatchPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let toolSettingsHatchBackgroundTitleLabel = NSTextField(labelWithString: "Background:")
    let toolSettingsHatchBackgroundColorWell = NSColorWell(frame: .zero)
    let toolSettingsLineWidthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let toolSettingsOpacitySlider = NSSlider(value: 0.8, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    let toolSettingsOpacityValueLabel = NSTextField(labelWithString: "80%")
    let snapshotColorizeButton = NSButton(title: "Colorize Black -> Red", target: nil, action: nil)
    let toolSettingsFillRow = NSStackView(frame: .zero)
    let toolSettingsOutlineRow = NSStackView(frame: .zero)
    let toolSettingsFontRow = NSStackView(frame: .zero)
    let toolSettingsArrowRow = NSStackView(frame: .zero)
    let toolSettingsArrowSizeRow = NSStackView(frame: .zero)
    let toolSettingsHatchRow = NSStackView(frame: .zero)
    let toolSettingsHatchBackgroundRow = NSStackView(frame: .zero)
    let toolSettingsWidthRow = NSStackView(frame: .zero)
    private let selectedMarkupOverlayLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.strokeColor = NSColor.systemOrange.cgColor
        layer.fillColor = NSColor.clear.cgColor
        layer.lineWidth = 2
        layer.lineDashPattern = [6, 4]
        layer.zPosition = 20
        layer.isHidden = true
        layer.actions = [
            "path": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()
    private let selectedTextOverlayLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.strokeColor = NSColor.systemBlue.cgColor
        layer.fillColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        layer.lineWidth = 2.25
        layer.zPosition = 21
        layer.isHidden = true
        layer.actions = [
            "path": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()
    private let selectedLineEndpointOverlayLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.strokeColor = NSColor.white.cgColor
        layer.fillColor = NSColor.systemPurple.withAlphaComponent(0.98).cgColor
        layer.lineWidth = 2.4
        layer.zPosition = 23
        layer.isHidden = true
        layer.actions = [
            "path": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()
    private let selectedLineEndpointHaloLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.strokeColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer.fillColor = NSColor.white.withAlphaComponent(0.95).cgColor
        layer.lineWidth = 2.0
        layer.zPosition = 22
        layer.isHidden = true
        layer.actions = [
            "path": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()
    var markupItems: [MarkupItem] = []
    var flattenedPDFItems: [(page: PDFPage, annotation: PDFAnnotation)] = []
    private var markupsTimer: Timer?
    var scrollEventMonitor: Any?
    var keyEventMonitor: Any?
    var flagsEventMonitor: Any?
    private var markupFilterText = ""
    var pendingCalibrationDistanceInPoints: CGFloat?
    private var busyOperationDepth = 0
    var markupChangeVersion = 0
    var lastAutosavedChangeVersion = 0
    var openDocumentURL: URL?
    var sessionDocumentURLs: [URL] = []
    var autosaveURL: URL?
    lazy var persistenceCoordinator = DocumentPersistenceCoordinator(autosaveInterval: autosaveIntervalSeconds)
    var pendingMarkupsRefreshWorkItem: DispatchWorkItem?
    var pendingSearchWorkItem: DispatchWorkItem?
    private var pendingChromeRefreshWorkItem: DispatchWorkItem?
    var searchHits: [SearchHit] = []
    var searchHitIndex: Int = -1
    var markupsScanGeneration = 0
    private var cachedMarkupDocumentID: ObjectIdentifier?
    private var pageMarkupCache: [Int: [PDFAnnotation]] = [:]
    private var pageMarkupSearchIndex: [Int: [ObjectIdentifier: String]] = [:]
    private var pendingSearchIndexWarmupWorkItem: DispatchWorkItem?
    private var searchIndexWarmupGeneration = 0
    private var cachedMarkupAnnotationCount = 0
    private var measurementSummaryByPage: [Int: (count: Int, totalPoints: CGFloat)] = [:]
    private var cachedMeasurementCount = 0
    private var cachedMeasurementTotalPoints: CGFloat = 0
    private var dirtyMarkupPageIndexes: Set<Int> = []
    let minimumIndexedMarkupItems = 5_000
    let maximumIndexedMarkupItems = 200_000
    private var lastKnownTotalMatchingMarkups = 0
    private var isMarkupListTruncated = false
    private var watchdog: MainThreadWatchdog?
    var lastAutosaveAt: Date = .distantPast
    var lastMarkupEditAt: Date = .distantPast
    var lastUserInteractionAt: Date = .distantPast
    var escapePressTracker = EscapePressTracker()
    private var saveProgressTimer: Timer?
    private var saveOperationStartedAt: CFAbsoluteTime?
    private var savePhase: String?
    var saveGenerateElapsed: Double = 0
    var isSavingDocumentOperation = false
    var queuedFastEmbeddedSave = false
    var lastEmbeddedSaveCompletedVersion = 0
    var deferredEmbeddedSaveRequestedVersion = 0
    var deferredEmbeddedSaveWorkItem: DispatchWorkItem?
    private var busyInteractionLocked = false
    private var captureToastHideWorkItem: DispatchWorkItem?
    private var grabClipboardPDFData: Data?
    private var grabClipboardPageRect: NSRect?
    private var grabClipboardSnapshotURL: URL?
    private var grabClipboardCaptureID = UUID()
    private var grabClipboardTintBlendStyle: PDFSnapshotAnnotation.TintBlendStyle = .screen
    private var grabSnapshotPreferredLayer = "ARCHITECTURAL"
    weak var lastDirectlySelectedAnnotation: PDFAnnotation?
    private var groupedPasteDragPageID: ObjectIdentifier?
    private var groupedPasteDragAnnotationIDs: Set<ObjectIdentifier> = []
    private var cachedMarkupPasteboardChangeCount = -1
    private var cachedMarkupPasteboardPayload: MarkupClipboardPayload?
    private var sidebarCurrentPageIndex: Int = -1
    private var bookmarkLabelOverrides: [String: String] = [:]
    private var pageLabelOverrides: [Int: String] = [:]
    var hasPromptedForInitialMarkupSaveCopy = false
    var isPresentingInitialMarkupSaveCopyPrompt = false
    var isGridVisible = false
    var isHyperlinkHighlightsVisible = false
    var isPolygonVertexEditModeEnabled = false
    var isOrthoModifierKeyDown = false
    var isOrthoSnapEnabled = true
    private var isEndpointSnapEnabled = true
    private var isMidpointSnapEnabled = true
    private var isIntersectionSnapEnabled = true
    private var suppressScaleReminderForSession = false
    private var autoNameCapturePhase: AutoNameCapturePhase?
    private var autoNameReferencePageIndex: Int?
    private var pendingSheetNumberZone: NormalizedPageRect?
    private var pendingSheetTitleZone: NormalizedPageRect?
    private var autoNamePreviousToolMode: ToolMode?
    private var autoLinkCaptureReferencePageIndex: Int?
    private var autoLinkPreviousToolMode: ToolMode?
    private var shouldChainAutoNameAfterBatchLink = false
    private var pendingExportToIPadTemporaryURL: URL?
    private var pendingExportToIPadSuggestedFilename: String?
    private let autoSheetLinkAnnotationMarker = "DrawbridgeAutoSheetLink"
    var displayPageGeometryOverrides: [Int: PDFPageStoredGeometry] = [:]
    var pageScaleLocks: [Int: PageScaleLock] = [:]
    var lastScaleLockAppliedPageIndex: Int = -1
    var lastExplicitScaleSetDocumentID: ObjectIdentifier?
    var lastExplicitScaleSetPageIndex: Int = -1
    var explicitScaleSetDocumentID: ObjectIdentifier?
    var explicitScaleSetPageIndexes: Set<Int> = []
    var pendingScaleReminderSuppressionDocumentID: ObjectIdentifier?
    var pendingScaleReminderSuppressionPageIndex: Int = -1
    var pendingScaleReminderSuppressionOneShot = false
    var toolSettingsByTool: [ToolMode: ToolSettingsState] = [:]
    var shortcutBindings: [ShortcutAction: ShortcutBinding] = [:]
    var layerVisibilityByName: [String: Bool] = [:]
    var layerTintColorByName: [String: NSColor] = [:]
    var layerVisibilityButtons: [String: NSButton] = [:]
    var layerTintColorWells: [String: NSButton] = [:]
    var activeLayerTintSelection: String?
    var onDocumentOpened: ((URL) -> Void)?
    private var sidebarContainerView: NSView?
    private var lastSidebarExpandedWidth: CGFloat = 240
    private var isSidebarCollapsed = false
    private let markupsSectionButton = NSButton(title: "", target: nil, action: nil)
    private let summarySectionButton = NSButton(title: "", target: nil, action: nil)
    private let markupsSectionContent = NSStackView(frame: .zero)
    private let summarySectionContent = NSStackView(frame: .zero)
    private let toolSelector: NSSegmentedControl = {
        let control = NSSegmentedControl(labels: ["Select"], trackingMode: .selectOne, target: nil, action: nil)
        control.selectedSegment = 0
        return control
    }()
    private let takeoffSelector: NSSegmentedControl = {
        let control = NSSegmentedControl(labels: ["Takeoff"], trackingMode: .selectOne, target: nil, action: nil)
        control.selectedSegment = -1
        return control
    }()
    private let newDocumentSizes: [(name: String, widthInches: CGFloat, heightInches: CGFloat)] = [
        ("ARCH E 36\" x 48\"", 36.0, 48.0),
        ("ARCH E1 30\" x 42\"", 30.0, 42.0),
        ("ARCH D 24\" x 36\"", 24.0, 36.0),
        ("ARCH C 18\" x 24\"", 18.0, 24.0),
        ("ARCH B 12\" x 18\"", 12.0, 18.0),
        ("ANSI E 34\" x 44\"", 34.0, 44.0),
        ("ANSI D 22\" x 34\"", 22.0, 34.0),
        ("ANSI C 17\" x 22\"", 17.0, 22.0),
        ("11\" x 17\"", 11.0, 17.0),
        ("8.5\" x 11\"", 8.5, 11.0),
        ("A1 594 x 841 mm", 23.3858, 33.1102),
        ("A2 420 x 594 mm", 16.5354, 23.3858),
        ("A3 297 x 420 mm", 11.6929, 16.5354),
        ("A4 210 x 297 mm", 8.2677, 11.6929)
    ]
    let drawingScalePresets: [(label: String, drawingInches: Double, realFeet: Double)] = [
        ("Scale: Not Set", 0.0, 0.0),
        ("3\" = 1'-0\"", 3.0, 1.0),
        ("1 1/2\" = 1'-0\"", 1.5, 1.0),
        ("1\" = 1'-0\"", 1.0, 1.0),
        ("3/4\" = 1'-0\"", 0.75, 1.0),
        ("1/2\" = 1'-0\"", 0.5, 1.0),
        ("3/8\" = 1'-0\"", 0.375, 1.0),
        ("1/4\" = 1'-0\"", 0.25, 1.0),
        ("3/16\" = 1'-0\"", 0.1875, 1.0),
        ("1/8\" = 1'-0\"", 0.125, 1.0),
        ("3/32\" = 1'-0\"", 0.09375, 1.0),
        ("1/16\" = 1'-0\"", 0.0625, 1.0),
        ("3/64\" = 1'-0\"", 0.046875, 1.0),
        ("1/32\" = 1'-0\"", 0.03125, 1.0),
        ("1\" = 2'-0\"", 1.0, 2.0),
        ("1\" = 4'-0\"", 1.0, 4.0),
        ("1\" = 8'-0\"", 1.0, 8.0),
        ("1\" = 10'-0\"", 1.0, 10.0),
        ("1\" = 20'-0\"", 1.0, 20.0),
        ("1\" = 30'-0\"", 1.0, 30.0),
        ("1\" = 40'-0\"", 1.0, 40.0),
        ("1\" = 50'-0\"", 1.0, 50.0),
        ("1\" = 60'-0\"", 1.0, 60.0),
        ("1\" = 80'-0\"", 1.0, 80.0),
        ("1\" = 100'-0\"", 1.0, 100.0),
        ("1\" = 200'-0\"", 1.0, 200.0),
        ("1\" = 300'-0\"", 1.0, 300.0),
        ("1\" = 400'-0\"", 1.0, 400.0),
        ("1\" = 500'-0\"", 1.0, 500.0),
        ("1\" = 1000'-0\"", 1.0, 1000.0),
        ("Set Scale for Multiple Pages…", -2.0, -2.0),
        ("Custom…", -1.0, -1.0)
    ]
    private weak var newDocumentPanel: NSPanel?
    private weak var newDocumentSizePopup: NSPopUpButton?
    private weak var newDocumentOrientationPopup: NSPopUpButton?
    private var newDocumentPanelCloseObserver: NSObjectProtocol?
    private var didInstallToolbarWidthConstraints = false
    private var toolSelectorWidthConstraint: NSLayoutConstraint?
    private var takeoffSelectorWidthConstraint: NSLayoutConstraint?
    private var toolbarToolButtons: [ToolMode: NSButton] = [:]
    private var toolbarQuickControlContainers: [String: NSView] = [:]
    private let toolbarQuickStrokeLabel = NSTextField(labelWithString: "Stroke")
    private let toolbarQuickStrokeColorWell = NSColorWell(frame: .zero)
    private let toolbarQuickFillLabel = NSTextField(labelWithString: "Fill")
    private let toolbarQuickFillColorWell = NSColorWell(frame: .zero)
    private let toolbarQuickWidthLabel = NSTextField(labelWithString: "Weight")
    private let toolbarQuickLineWidthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let toolbarQuickFontSizeLabel = NSTextField(labelWithString: "Text")
    private let toolbarQuickFontSizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let toolbarQuickArrowLabel = NSTextField(labelWithString: "Arrow")
    private let toolbarQuickArrowPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let toolbarQuickOpacityLabel = NSTextField(labelWithString: "Opacity")
    private let toolbarQuickOpacitySlider = NSSlider(value: 0.8, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let toolbarQuickOpacityValueLabel = NSTextField(labelWithString: "80%")
    private var isSyncingToolbarQuickControls = false
    private var bookmarksWidthConstraint: NSLayoutConstraint?
    private var navigationWidthAtDragStart: CGFloat = 220
    private var navigationWidth: CGFloat = 220
    private let navigationWidthMin: CGFloat = 160
    private let navigationWidthMax: CGFloat = 420
    private var sidebarPreferredWidthConstraint: NSLayoutConstraint?
    private var didApplyInitialSplitLayout = false

    override func loadView() {
        let rootDropView = StartupDropView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        rootDropView.wantsLayer = true
        rootDropView.layer?.backgroundColor = chromeBackgroundColor.cgColor
        rootDropView.onAppearanceChanged = { [weak self] in
            self?.applyAppearanceColors()
        }
        rootDropView.onOpenDroppedPDF = { [weak self] url in
            guard let self else { return }
            guard self.confirmDiscardUnsavedChangesIfNeeded() else { return }
            self.openDocument(at: url)
        }
        view = rootDropView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        registerDefaultPerformanceSettingsIfNeeded()
        migrateHyperlinkHighlightsDefaultIfNeeded()
        isHyperlinkHighlightsVisible = UserDefaults.standard.bool(forKey: Self.defaultsHyperlinkHighlightsVisibleKey)
        loadShortcutBindings()
        setupUI()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePDFPageChangedNotification(_:)),
            name: Notification.Name.PDFViewPageChanged,
            object: pdfView
        )
        updateShortcutHintLabel()
        configureWatchdogFromDefaults()
        startMarkupsRefreshTimer()
        updateEmptyStateVisibility()
    }

    @objc private func handlePDFPageChangedNotification(_ notification: Notification) {
        requestChromeRefresh(immediate: true)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Re-apply after attaching to a window so semantic colors resolve against the true appearance.
        applyAppearanceColors()
        watchdog?.start()
        applySplitLayoutIfPossible(force: true)
        installScrollMonitorIfNeeded()
        installKeyMonitorIfNeeded()
        installFlagsMonitorIfNeeded()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applySplitLayoutIfPossible(force: false)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        watchdog?.stop()
        stopSaveProgressTracking()
        markupsTimer?.invalidate()
        markupsTimer = nil
        if let monitor = scrollEventMonitor {
            NSEvent.removeMonitor(monitor)
            scrollEventMonitor = nil
        }
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        if let monitor = flagsEventMonitor {
            NSEvent.removeMonitor(monitor)
            flagsEventMonitor = nil
        }
    }

    private func setupUI() {
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true

        openButton.title = "Open"
        openButton.target = self
        openButton.action = #selector(openPDF)
        autoNameSheetsButton.target = self
        autoNameSheetsButton.action = #selector(commandAutoGenerateSheetNames(_:))
        batchLinkSheetsButton.target = self
        batchLinkSheetsButton.action = #selector(commandBatchLinkSheetNumbers(_:))
        flattenPDFButton.target = self
        flattenPDFButton.action = #selector(commandFlattenPDF(_:))
        reduceFileSizeButton.target = self
        reduceFileSizeButton.action = #selector(commandReduceFileSize(_:))
        emptyStateOpenButton.title = "Open Existing PDF"
        emptyStateOpenButton.target = self
        emptyStateOpenButton.action = #selector(openPDF)
        emptyStateRecentButton.target = self
        emptyStateRecentButton.action = #selector(showOpenRecentMenuFromEmptyState(_:))
        emptyStateSampleButton.target = self
        emptyStateSampleButton.action = #selector(createNewPDFAction)
        emptyStateBatchMobileButton.target = self
        emptyStateBatchMobileButton.action = #selector(commandBatchExportToMobile(_:))
        highlightButton.target = self
        highlightButton.action = #selector(highlightSelection)
        exportButton.target = self
        exportButton.action = #selector(saveCopy)
        refreshMarkupsButton.target = self
        refreshMarkupsButton.action = #selector(refreshMarkups)
        deleteMarkupButton.target = self
        deleteMarkupButton.action = #selector(deleteSelectedMarkup)
        editMarkupButton.target = self
        editMarkupButton.action = #selector(editSelectedMarkupText)
        configureMeasurementScaleState()
        initializePerToolSettings()
        ensureLayerVisibilityDefaults()
        configureActionsPopup(highlightButton: highlightButton, exportButton: exportButton, refreshMarkupsButton: refreshMarkupsButton, deleteMarkupButton: deleteMarkupButton, editMarkupButton: editMarkupButton)

        toolSelector.target = self
        toolSelector.action = #selector(changeTool)
        takeoffSelector.target = self
        takeoffSelector.action = #selector(changeTakeoffTool)
        setupToolbarControlStack()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfCanvasContainer.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        configureMarkupsSidebar()
        configureStatusBar()
        configurePDFCanvasContainer()
        configureCollapsedSidebarRevealButton()

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(pdfCanvasContainer)
        // Scratch-reset mode: remove the right-side tool/settings pane entirely.
        sidebarContainerView = nil
        isSidebarCollapsed = true
        collapsedSidebarRevealButton.isHidden = true
        configureEmptyStateView()
        pdfCanvasContainer.onOpenDroppedPDF = { [weak self] url in
            guard let self else { return }
            guard self.confirmDiscardUnsavedChangesIfNeeded() else { return }
            self.openDocument(at: url)
        }
        emptyStateView.onOpenDroppedPDF = { [weak self] url in
            guard let self else { return }
            guard self.confirmDiscardUnsavedChangesIfNeeded() else { return }
            self.openDocument(at: url)
        }
        pdfView.onOpenDroppedPDF = { [weak self] url in
            guard let self else { return }
            guard self.confirmDiscardUnsavedChangesIfNeeded() else { return }
            self.openDocument(at: url)
        }
        pdfView.onViewportChanged = { [weak self] in
            self?.lastUserInteractionAt = Date()
            self?.requestChromeRefresh()
            self?.updateSelectionOverlay()
            self?.pdfView.refreshHyperlinkHighlights()
        }
        pdfView.onCalibrationDistanceMeasured = { [weak self] distance in
            self?.showCalibrationDialog(distanceInPoints: distance)
        }
        pdfView.onToolShortcut = { [weak self] mode in
            self?.setTool(mode)
        }
        pdfView.onPageNavigationShortcut = { [weak self] delta in
            guard let self else { return }
            self.lastUserInteractionAt = Date()
            if delta < 0 {
                self.commandPreviousPage(nil)
            } else if delta > 0 {
                self.commandNextPage(nil)
            }
        }
        pdfView.onAnnotationAdded = { [weak self] page, annotation, actionName in
            self?.markPageMarkupCacheDirty(page)
            self?.registerAnnotationPresenceUndo(page: page, annotation: annotation, shouldExist: false, actionName: actionName)
            self?.markMarkupChangedAndScheduleAutosave()
            self?.scheduleMarkupsRefresh(selecting: nil)
        }
        pdfView.onAnnotationTextEdited = { [weak self] page, annotation, previousContents in
            guard let self else { return }
            let current = self.snapshot(for: annotation)
            let previous = AnnotationSnapshot(
                bounds: current.bounds,
                contents: previousContents,
                color: current.color,
                interiorColor: current.interiorColor,
                fontColor: current.fontColor,
                fontName: current.fontName,
                fontSize: current.fontSize,
                lineWidth: current.lineWidth,
                renderOpacity: current.renderOpacity,
                renderTintColor: current.renderTintColor,
                renderTintStrength: current.renderTintStrength,
                tintBlendStyleRawValue: current.tintBlendStyleRawValue,
                lineworkOnlyTint: current.lineworkOnlyTint,
                snapshotLayerName: current.snapshotLayerName
            )
            self.registerAnnotationStateUndo(annotation: annotation, previous: previous, actionName: "Edit Markup Text")
            self.markPageMarkupCacheDirty(page)
            self.markMarkupChangedAndScheduleAutosave()
            self.scheduleMarkupsRefresh(selecting: annotation)
        }
        pdfView.onAnnotationMoved = { [weak self] page, annotation, startBounds in
            guard let self else { return }
            let before = AnnotationSnapshot(
                bounds: startBounds,
                contents: annotation.contents,
                color: annotation.color,
                interiorColor: annotation.interiorColor,
                fontColor: annotation.fontColor,
                fontName: annotation.font?.fontName,
                fontSize: annotation.font?.pointSize,
                lineWidth: resolvedLineWidth(for: annotation),
                renderOpacity: (annotation as? PDFSnapshotAnnotation)?.renderOpacity,
                renderTintColor: (annotation as? PDFSnapshotAnnotation)?.renderTintColor,
                renderTintStrength: (annotation as? PDFSnapshotAnnotation)?.renderTintStrength,
                tintBlendStyleRawValue: (annotation as? PDFSnapshotAnnotation)?.tintBlendStyle.rawValue,
                lineworkOnlyTint: (annotation as? PDFSnapshotAnnotation)?.lineworkOnlyTint,
                snapshotLayerName: (annotation as? PDFSnapshotAnnotation)?.snapshotLayerName
            )
            self.registerAnnotationStateUndo(annotation: annotation, previous: before, actionName: "Move Markup")
            self.pdfView.syncTextOutlineGeometry(for: annotation)
            self.markPageMarkupCacheDirty(page)
            self.markMarkupChangedAndScheduleAutosave()
            self.scheduleMarkupsRefresh(selecting: annotation)
        }
        pdfView.onResolveDragSelection = { [weak self] page, anchor in
            guard let self else { return [anchor] }
            let polygonSiblings = self.pdfView.relatedPolygonMarkupAnnotations(for: anchor, on: page)
            if !polygonSiblings.isEmpty {
                return [anchor] + polygonSiblings
            }
            let selectedItems = self.currentSelectedMarkupItems()
            guard !selectedItems.isEmpty else {
                // No prior selection: let direct click select the clicked annotation first.
                return [anchor]
            }
            let selectedSet = Set(selectedItems.map { ObjectIdentifier($0.annotation) })
            guard selectedSet.contains(ObjectIdentifier(anchor)) else {
                // Clicking a different annotation should switch selection to that annotation.
                return [anchor]
            }
            if !self.shouldDragAsGroupedPasteSelection(on: page, selectedSet: selectedSet, anchor: anchor) {
                return [anchor]
            }
            var resolved: [PDFAnnotation] = []
            var seen = Set<ObjectIdentifier>()
            for item in selectedItems where item.annotation.page === page {
                let related = self.relatedCalloutAnnotations(for: item.annotation, on: page)
                for candidate in related {
                    let key = ObjectIdentifier(candidate)
                    if seen.insert(key).inserted {
                        resolved.append(candidate)
                    }
                }
            }
            return resolved.isEmpty ? [anchor] : resolved
        }
        pdfView.selectedAnnotationsProvider = { [weak self] page in
            guard let self else { return [] }
            return self.currentSelectedMarkupItems()
                .map(\.annotation)
                .filter { $0.page === page }
        }
        pdfView.onAnnotationClicked = { [weak self] page, annotation, additive in
            self?.selectMarkupFromPageClick(page: page, annotation: annotation, additive: additive)
        }
        pdfView.onReorderActionRequested = { [weak self] action in
            guard let self else { return }
            switch action {
            case .sendToBack:
                self.reorderSelectedMarkups(.sendToBack)
            case .bringForward:
                self.reorderSelectedMarkups(.bringForward)
            case .sendBackward:
                self.reorderSelectedMarkups(.sendBackward)
            case .bringToFront:
                self.reorderSelectedMarkups(.bringToFront)
            }
        }
        pdfView.onAssignLayerRequested = { [weak self] in
            self?.assignSnapshotLayerForCurrentSelection()
        }
        pdfView.onApplyToPagesRequested = { [weak self] in
            self?.applySelectedMarkupsToPages()
        }
        pdfView.onAnnotationsBoxSelected = { [weak self] page, annotations in
            self?.selectMarkupsFromFence(page: page, annotations: annotations)
        }
        pdfView.onDeleteKeyPressed = { [weak self] in
            self?.deleteSelectedMarkup()
        }
        pdfView.onImageDropped = { [weak self] page, annotation, baseBounds in
            self?.presentDroppedImageScaleDialog(page: page, annotation: annotation, baseBounds: baseBounds)
        }
        pdfView.onSnapshotCaptured = { [weak self] pdfData, pageRect in
            let captureID = UUID()
            self?.grabClipboardCaptureID = captureID
            self?.grabClipboardPDFData = pdfData
            self?.grabClipboardPageRect = pageRect
            self?.grabClipboardSnapshotURL = nil
            self?.grabClipboardTintBlendStyle = self?.preferredSnapshotTintBlendStyle(for: pdfData) ?? .screen
            self?.warmGrabSnapshotPersistence(pdfData, captureID: captureID)
            let board = NSPasteboard.general
            board.clearContents()
            board.setData(pdfData, forType: .pdf)
            self?.showCaptureToast("Captured - Cmd+Shift+V to paste in place")
        }
        pdfView.onRegionCaptured = { [weak self] page, rectInPage in
            guard let self else { return }
            if self.autoNameCapturePhase != nil {
                self.handleAutoNameRegionCaptured(on: page, rectInPage: rectInPage)
                return
            }
            if self.autoLinkCaptureReferencePageIndex != nil {
                self.handleAutoLinkRegionCaptured(on: page, rectInPage: rectInPage)
            }
        }
        pdfView.shouldBeginMarkupInteraction = { [weak self] in
            self?.ensureWorkingCopyBeforeFirstMarkup() ?? true
        }
        pdfView.layer?.addSublayer(selectedMarkupOverlayLayer)
        pdfView.layer?.addSublayer(selectedTextOverlayLayer)
        pdfView.layer?.addSublayer(selectedLineEndpointHaloLayer)
        pdfView.layer?.addSublayer(selectedLineEndpointOverlayLayer)
        pdfView.setHyperlinkHighlightsVisible(isHyperlinkHighlightsVisible)

        view.addSubview(splitView)
        view.addSubview(documentTabsBar)
        view.addSubview(statusBar)
        view.addSubview(busyOverlayView)
        view.addSubview(captureToastView)
        view.addSubview(collapsedSidebarRevealButton)
        configureDocumentTabsBar()
        configureBusyOverlay()
        configureCaptureToast()
        applyAppearanceColors()

        NSLayoutConstraint.activate([
            documentTabsBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            documentTabsBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            documentTabsBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            documentTabsBar.heightAnchor.constraint(equalToConstant: 34),

            splitView.topAnchor.constraint(equalTo: documentTabsBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 28),
            busyOverlayView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            busyOverlayView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            busyOverlayView.widthAnchor.constraint(equalToConstant: 420),
            captureToastView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            captureToastView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureToastView.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            collapsedSidebarRevealButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            collapsedSidebarRevealButton.centerYAnchor.constraint(equalTo: splitView.centerYAnchor),
            collapsedSidebarRevealButton.widthAnchor.constraint(equalToConstant: 28),
            collapsedSidebarRevealButton.heightAnchor.constraint(equalToConstant: 28)
        ])
        requestChromeRefresh(immediate: true)
        updateEmptyStateVisibility()
        refreshDocumentTabs()
    }

    private func applyAppearanceColors() {
        if let rootDropView = view as? StartupDropView {
            rootDropView.wantsLayer = true
            rootDropView.layer?.backgroundColor = chromeBackgroundColor.cgColor
        }
        view.layer?.backgroundColor = chromeBackgroundColor.cgColor
        pdfCanvasContainer.layer?.backgroundColor = chromeBackgroundColor.cgColor
        bookmarksContainer.layer?.backgroundColor = sidebarBackgroundColor.cgColor
        pagesTableView.backgroundColor = sidebarBackgroundColor
        bookmarksOutlineView.backgroundColor = sidebarBackgroundColor
        statusBar.layer?.backgroundColor = panelBackgroundColor.cgColor
        busyOverlayView.layer?.backgroundColor = panelBackgroundColor.cgColor
        captureToastView.layer?.backgroundColor = panelBackgroundColor.cgColor
        emptyStateView.layer?.backgroundColor = panelBackgroundColor.cgColor
        collapsedSidebarRevealButton.layer?.backgroundColor = panelBackgroundColor.cgColor
        documentTabsBar.layer?.backgroundColor = panelBackgroundColor.cgColor
        pdfView.refreshAppearanceColors()
    }

    private func applySplitLayoutIfPossible(force: Bool) {
        guard let sidebar = sidebarContainerView else { return }
        let availableWidth = splitView.bounds.width
        guard availableWidth > 500 else { return }
        if didApplyInitialSplitLayout && !force { return }

        let hasDocument = (pdfView.document != nil)
        if isSidebarCollapsed {
            sidebar.isHidden = true
            splitView.setPosition(availableWidth - 1, ofDividerAt: 0)
        } else if !hasDocument {
            // Keep startup focused on the open/create surface and constrain tool settings to a sidebar width.
            sidebar.isHidden = false
            let startupSidebarWidth: CGFloat = min(max(lastSidebarExpandedWidth, 220), 260)
            sidebarPreferredWidthConstraint?.constant = startupSidebarWidth
            splitView.setPosition(max(900, availableWidth - startupSidebarWidth), ofDividerAt: 0)
        } else {
            sidebar.isHidden = false
            let clampedSidebarWidth = min(max(lastSidebarExpandedWidth, 220), 280)
            sidebarPreferredWidthConstraint?.constant = clampedSidebarWidth
            splitView.setPosition(max(900, availableWidth - clampedSidebarWidth), ofDividerAt: 0)
        }
        didApplyInitialSplitLayout = true
    }

    private func configureMeasurementScaleState() {
        measurementUnitPopup.removeAllItems()
        measurementUnitPopup.addItems(withTitles: ["pt", "in", "ft", "m"])
        measurementUnitPopup.selectItem(withTitle: "ft")
        measurementScaleField.stringValue = "1.000000"
        applyMeasurementScale()
        scalePresetPopup.selectItem(withTitle: "Scale: Not Set")
    }

    private func configurePDFCanvasContainer() {
        if showNavigationPane {
            configureBookmarksSidebar()
        } else {
            bookmarksContainer.isHidden = true
        }
        pdfCanvasContainer.wantsLayer = true
        pdfCanvasContainer.layer?.backgroundColor = chromeBackgroundColor.cgColor
        bookmarksContainer.translatesAutoresizingMaskIntoConstraints = false
        navigationResizeHandle.translatesAutoresizingMaskIntoConstraints = false

        pdfCanvasContainer.addSubview(bookmarksContainer)
        pdfCanvasContainer.addSubview(pdfView)
        // Keep the navigation grabber above the PDF view so drag events are never blocked.
        pdfCanvasContainer.addSubview(navigationResizeHandle)

        let bookmarksWidth = bookmarksContainer.widthAnchor.constraint(equalToConstant: showNavigationPane ? navigationWidth : 0)
        NSLayoutConstraint.activate([
            bookmarksContainer.topAnchor.constraint(equalTo: pdfCanvasContainer.topAnchor),
            bookmarksContainer.leadingAnchor.constraint(equalTo: pdfCanvasContainer.leadingAnchor),
            bookmarksContainer.bottomAnchor.constraint(equalTo: pdfCanvasContainer.bottomAnchor),
            bookmarksWidth,

            navigationResizeHandle.topAnchor.constraint(equalTo: pdfCanvasContainer.topAnchor),
            navigationResizeHandle.bottomAnchor.constraint(equalTo: pdfCanvasContainer.bottomAnchor),
            navigationResizeHandle.centerXAnchor.constraint(equalTo: bookmarksContainer.trailingAnchor),
            navigationResizeHandle.widthAnchor.constraint(equalToConstant: 26),

            pdfView.topAnchor.constraint(equalTo: pdfCanvasContainer.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: bookmarksContainer.trailingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: pdfCanvasContainer.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: pdfCanvasContainer.bottomAnchor)
        ])
        bookmarksWidthConstraint = bookmarksWidth

        navigationResizeHandle.wantsLayer = true
        navigationResizeHandle.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        navigationResizeHandle.layer?.cornerRadius = 1
        let resizePan = NSPanGestureRecognizer(target: self, action: #selector(handleNavigationResizePan(_:)))
        navigationResizeHandle.addGestureRecognizer(resizePan)
        navigationResizeHandle.isHidden = !showNavigationPane
    }

    @objc private func handleNavigationResizePan(_ recognizer: NSPanGestureRecognizer) {
        guard showNavigationPane else { return }
        switch recognizer.state {
        case .began:
            navigationWidthAtDragStart = bookmarksWidthConstraint?.constant ?? navigationWidth
        case .changed:
            let deltaX = recognizer.translation(in: pdfCanvasContainer).x
            let proposed = navigationWidthAtDragStart + deltaX
            let clamped = min(max(proposed, navigationWidthMin), navigationWidthMax)
            navigationWidth = clamped
            bookmarksWidthConstraint?.constant = clamped
            view.layoutSubtreeIfNeeded()
        default:
            break
        }
    }

    private func configureBookmarksSidebar() {
        if !bookmarksContainer.subviews.isEmpty {
            return
        }

        bookmarksContainer.wantsLayer = true
        bookmarksContainer.layer?.borderWidth = 1
        bookmarksContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        bookmarksContainer.layer?.backgroundColor = sidebarBackgroundColor.cgColor

        navigationTitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        navigationTitleLabel.textColor = .secondaryLabelColor
        navigationModeControl.selectedSegment = 1
        navigationModeControl.controlSize = .small
        navigationModeControl.target = self
        navigationModeControl.action = #selector(changeNavigationMode)
        if let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Page") {
            addPageButton.image = plus
            addPageButton.title = ""
            addPageButton.imagePosition = .imageOnly
        } else {
            addPageButton.title = "+"
            addPageButton.image = nil
            addPageButton.imagePosition = .noImage
        }
        addPageButton.bezelStyle = .texturedRounded
        addPageButton.controlSize = .small
        addPageButton.toolTip = "Add Page"
        addPageButton.target = self
        addPageButton.action = #selector(addPageFromNavigation)
        addPageButton.setContentHuggingPriority(.required, for: .horizontal)
        addPageButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let pagesControlRow = NSStackView(views: [navigationModeControl, NSView(), addPageButton])
        pagesControlRow.orientation = .horizontal
        pagesControlRow.spacing = 6
        pagesControlRow.alignment = .centerY

        let pagesColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pages"))
        pagesColumn.title = "Pages"
        pagesColumn.width = 208
        pagesTableView.identifier = NSUserInterfaceItemIdentifier("pagesTable")
        pagesTableView.addTableColumn(pagesColumn)
        pagesTableView.headerView = nil
        pagesTableView.usesAlternatingRowBackgroundColors = false
        pagesTableView.rowHeight = 24
        pagesTableView.focusRingType = .none
        pagesTableView.style = .sourceList
        pagesTableView.selectionHighlightStyle = .none
        pagesTableView.allowsEmptySelection = true
        pagesTableView.allowsMultipleSelection = true
        pagesTableView.backgroundColor = sidebarBackgroundColor
        pagesTableView.gridStyleMask = []
        pagesTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        pagesTableView.delegate = self
        pagesTableView.dataSource = self
        pagesTableView.target = self
        pagesTableView.action = #selector(selectPageFromSidebar)
        pagesTableView.doubleAction = #selector(renamePageLabelFromSidebar)
        let pagesContextMenu = NSMenu(title: "Pages")
        let renamePageItem = NSMenuItem(title: "Rename Page Label…", action: #selector(renamePageLabelFromSidebar), keyEquivalent: "")
        renamePageItem.target = self
        pagesContextMenu.addItem(renamePageItem)
        pagesContextMenu.addItem(NSMenuItem.separator())
        let deletePagesItem = NSMenuItem(title: "Delete Page(s)…", action: #selector(deletePagesFromSidebar), keyEquivalent: "")
        deletePagesItem.target = self
        pagesContextMenu.addItem(deletePagesItem)
        pagesTableView.menu = pagesContextMenu

        thumbnailScrollView.borderType = .noBorder
        thumbnailScrollView.hasVerticalScroller = true
        thumbnailScrollView.autohidesScrollers = true
        thumbnailScrollView.drawsBackground = false
        thumbnailScrollView.documentView = pagesTableView
        thumbnailScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        thumbnailScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        thumbnailScrollView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bookmark"))
        column.title = "Bookmark"
        column.width = 208
        bookmarksOutlineView.addTableColumn(column)
        bookmarksOutlineView.outlineTableColumn = column
        bookmarksOutlineView.headerView = nil
        bookmarksOutlineView.rowHeight = 22
        bookmarksOutlineView.focusRingType = .none
        bookmarksOutlineView.style = .sourceList
        bookmarksOutlineView.selectionHighlightStyle = .none
        bookmarksOutlineView.backgroundColor = sidebarBackgroundColor
        bookmarksOutlineView.delegate = self
        bookmarksOutlineView.dataSource = self
        bookmarksOutlineView.target = self
        bookmarksOutlineView.action = #selector(selectBookmarkFromSidebar)
        bookmarksOutlineView.doubleAction = #selector(renameBookmarkFromSidebar)
        let bookmarksContextMenu = NSMenu(title: "Bookmarks")
        let renameBookmarkItem = NSMenuItem(title: "Rename Bookmark…", action: #selector(renameBookmarkFromSidebar), keyEquivalent: "")
        renameBookmarkItem.target = self
        bookmarksContextMenu.addItem(renameBookmarkItem)
        bookmarksOutlineView.menu = bookmarksContextMenu

        bookmarksScrollView.borderType = .noBorder
        bookmarksScrollView.hasVerticalScroller = true
        bookmarksScrollView.autohidesScrollers = true
        bookmarksScrollView.drawsBackground = false
        bookmarksScrollView.documentView = bookmarksOutlineView
        bookmarksScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        bookmarksScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        bookmarksScrollView.translatesAutoresizingMaskIntoConstraints = false
        bookmarksScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        thumbnailsEmptyLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        thumbnailsEmptyLabel.textColor = .secondaryLabelColor
        thumbnailsEmptyLabel.alignment = .center
        thumbnailsEmptyLabel.isHidden = true
        bookmarksEmptyLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        bookmarksEmptyLabel.textColor = .secondaryLabelColor
        bookmarksEmptyLabel.alignment = .center
        bookmarksEmptyLabel.isHidden = true
        pdfContentsTitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        pdfContentsTitleLabel.textColor = .secondaryLabelColor
        pdfContentsTitleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        pdfContentsSummaryLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        pdfContentsSummaryLabel.textColor = .tertiaryLabelColor
        pdfContentsSummaryLabel.maximumNumberOfLines = 0
        pdfContentsSummaryLabel.lineBreakMode = .byWordWrapping
        pdfContentsSummaryLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        let contentsSeparator = NSBox()
        contentsSeparator.boxType = .separator
        contentsSeparator.translatesAutoresizingMaskIntoConstraints = false

        let pdfContentsStack = NSStackView(views: [
            contentsSeparator,
            pdfContentsTitleLabel,
            pdfContentsSummaryLabel
        ])
        pdfContentsStack.orientation = .vertical
        pdfContentsStack.spacing = 5

        let stack = NSStackView(views: [
            navigationTitleLabel,
            pagesControlRow,
            thumbnailScrollView,
            thumbnailsEmptyLabel,
            bookmarksScrollView,
            bookmarksEmptyLabel,
            pdfContentsStack
        ])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bookmarksContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bookmarksContainer.topAnchor),
            stack.leadingAnchor.constraint(equalTo: bookmarksContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bookmarksContainer.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bookmarksContainer.bottomAnchor)
        ])
        changeNavigationMode()
    }

    private func refreshRulers() {
        if showNavigationPane {
            reloadBookmarks()
        }
    }

    @objc private func changeNavigationMode() {
        let showingPages = (navigationModeControl.selectedSegment != 1)
        thumbnailScrollView.isHidden = !showingPages
        thumbnailsEmptyLabel.isHidden = !showingPages || (pdfView.document != nil)
        bookmarksScrollView.isHidden = showingPages
        bookmarksEmptyLabel.isHidden = showingPages || !(bookmarksOutlineView.numberOfRows == 0)
        addPageButton.isHidden = !showingPages
        addPageButton.isEnabled = showingPages && (pdfView.document != nil)
    }

    @objc private func addPageFromNavigation() {
        guard ensureWorkingCopyBeforeFirstMarkup() else { return }
        guard let document = pdfView.document else { beep(); return }
        guard let targetSize = preferredPageSizeForInsertion(in: document) else {
            return
        }
        let page = makeBlankPDFPage(size: targetSize)
        document.insert(page, at: max(0, document.pageCount))
        commitMarkupMutation(selecting: nil, forceImmediateRefresh: true)
        reloadBookmarks()
        pdfView.navigateToPageWithHistory(page)
        DispatchQueue.main.async { [weak self] in
            self?.requestChromeRefresh(immediate: true)
        }
    }

    private func preferredPageSizeForInsertion(in document: PDFDocument) -> NSSize? {
        var unique: [(size: NSSize, label: String, representativeIndex: Int)] = []
        func signature(for size: NSSize) -> String {
            let w = (size.width * 10.0).rounded() / 10.0
            let h = (size.height * 10.0).rounded() / 10.0
            return "\(w)x\(h)"
        }
        var seen = Set<String>()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let size = NSSize(width: max(1.0, bounds.width), height: max(1.0, bounds.height))
            let key = signature(for: size)
            if seen.insert(key).inserted {
                let label = "Page \(index + 1): \(formatInches(size.width / 72.0)) x \(formatInches(size.height / 72.0))"
                unique.append((size: size, label: label, representativeIndex: index))
            }
        }

        if unique.isEmpty {
            return NSSize(width: 612, height: 792)
        }
        if unique.count == 1 {
            return unique[0].size
        }

        let alert = NSAlert()
        alert.messageText = "This PDF has mixed page sizes"
        alert.informativeText = "Choose the page size for the new page."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 24), pullsDown: false)
        popup.addItems(withTitles: unique.map(\.label))
        if let current = pdfView.currentPage {
            let currentIndex = max(0, document.index(for: current))
            if let preferred = unique.firstIndex(where: { $0.representativeIndex == currentIndex }) {
                popup.selectItem(at: preferred)
            }
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Add Page")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        let selected = max(0, popup.indexOfSelectedItem)
        return unique[min(selected, unique.count - 1)].size
    }

    private func makeBlankPDFPage(size: NSSize) -> PDFPage {
        let safeSize = NSSize(width: max(1, size.width), height: max(1, size.height))
        let image = NSImage(size: safeSize)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: safeSize)).fill()
        image.unlockFocus()
        if let page = PDFPage(image: image) {
            return page
        }
        let fallbackImage = NSImage(size: NSSize(width: 612, height: 792))
        fallbackImage.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 612, height: 792)).fill()
        fallbackImage.unlockFocus()
        if let fallbackPage = PDFPage(image: fallbackImage) {
            return fallbackPage
        }
        let tiny = NSImage(size: NSSize(width: 1, height: 1))
        tiny.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1, height: 1)).fill()
        tiny.unlockFocus()
        return PDFPage(image: tiny)!
    }

    private func reloadBookmarks() {
        pagesTableView.reloadData()
        updatePDFContentsSummary()
        if navigationModeControl.selectedSegment < 0 {
            navigationModeControl.selectedSegment = 1
        }
        let pageCount = pdfView.document?.pageCount ?? 0
        thumbnailsEmptyLabel.isHidden = (pageCount > 0) || (navigationModeControl.selectedSegment == 1)
        if navigationModeControl.selectedSegment == 0,
           sidebarCurrentPageIndex >= 0,
           sidebarCurrentPageIndex < pageCount {
            pagesTableView.scrollRowToVisible(sidebarCurrentPageIndex)
        }

        guard let root = pdfView.document?.outlineRoot, root.numberOfChildren > 0 else {
            bookmarksOutlineView.reloadData()
            bookmarksEmptyLabel.isHidden = (navigationModeControl.selectedSegment == 0)
            changeNavigationMode()
            return
        }
        bookmarksEmptyLabel.isHidden = true
        bookmarksOutlineView.reloadData()
        for idx in 0..<root.numberOfChildren {
            if let child = root.child(at: idx), child.isOpen {
                bookmarksOutlineView.expandItem(child)
            }
        }
        changeNavigationMode()
    }

    func updatePDFContentsSummary() {
        guard let document = pdfView.document else {
            pdfContentsSummaryLabel.stringValue = "No PDF loaded"
            return
        }

        var totalAnnotations = 0
        var extraneousAnnotations = 0
        var nonPrintAnnotations = 0
        var hiddenAnnotations = 0
        var linkAnnotations = 0
        var typeCounts: [String: Int] = [:]
        var shxSamples: [String] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                totalAnnotations += 1
                let type = (annotation.type ?? "Unknown").trimmingCharacters(in: .whitespacesAndNewlines)
                typeCounts[type.isEmpty ? "Unknown" : type, default: 0] += 1
                if isExtraneousEmbeddedPDFAnnotation(annotation) {
                    extraneousAnnotations += 1
                    if shxSamples.count < 3,
                       let contents = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !contents.isEmpty {
                        shxSamples.append(contents)
                    }
                }
                if !annotation.shouldPrint {
                    nonPrintAnnotations += 1
                }
                if !annotation.shouldDisplay {
                    hiddenAnnotations += 1
                }
                if (annotation.type ?? "").localizedCaseInsensitiveContains("link") {
                    linkAnnotations += 1
                }
            }
        }

        let topTypes = typeCounts
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .prefix(3)
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")

        var lines: [String] = [
            "Pages: \(document.pageCount)",
            "Annotations: \(totalAnnotations)",
            "Extraneous CAD boxes: \(extraneousAnnotations)",
            "Non-print items: \(nonPrintAnnotations)",
            "Hidden items: \(hiddenAnnotations)",
            "Links: \(linkAnnotations)"
        ]
        if !topTypes.isEmpty {
            lines.append("Top types:\n\(topTypes)")
        }
        if !shxSamples.isEmpty {
            lines.append("Samples:\n\(shxSamples.joined(separator: "\n"))")
        }
        pdfContentsSummaryLabel.stringValue = lines.joined(separator: "\n")
    }

    @objc private func selectPageFromSidebar() {
        let row = pagesTableView.selectedRow
        guard row >= 0, let document = pdfView.document, row < document.pageCount, let page = document.page(at: row) else {
            return
        }
        pdfView.navigateToPageWithHistory(page)
        pagesTableView.deselectAll(nil)
        requestChromeRefresh(immediate: true)
    }

    @objc private func selectBookmarkFromSidebar() {
        let row = bookmarksOutlineView.selectedRow
        guard row >= 0,
              let outline = bookmarksOutlineView.item(atRow: row) as? PDFOutline,
              let destination = outline.destination else {
            return
        }
        pdfView.navigateToDestinationWithHistory(destination)
        bookmarksOutlineView.deselectAll(nil)
        requestChromeRefresh(immediate: true)
    }

    @objc private func renameBookmarkFromSidebar() {
        let row = bookmarksOutlineView.clickedRow >= 0 ? bookmarksOutlineView.clickedRow : bookmarksOutlineView.selectedRow
        guard row >= 0,
              let outline = bookmarksOutlineView.item(atRow: row) as? PDFOutline else { return }
        let existing = displayBookmarkTitle(for: outline)
        let alert = NSAlert()
        alert.messageText = "Rename Bookmark"
        alert.informativeText = "Enter a new bookmark name."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = existing
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let updated = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.isEmpty else { return }
        outline.label = updated
        bookmarkLabelOverrides[bookmarkKey(for: outline)] = updated

        if let pageIndex = destinationPageIndex(for: outline) {
            let syncPrompt = NSAlert()
            syncPrompt.messageText = "Update matching page label too?"
            syncPrompt.informativeText = "Apply \"\(updated)\" to Page \(pageIndex + 1) in the Pages list as well?"
            syncPrompt.alertStyle = .informational
            syncPrompt.addButton(withTitle: "Update Page Label")
            syncPrompt.addButton(withTitle: "Keep Current Page Label")
            if syncPrompt.runModal() == .alertFirstButtonReturn {
                pageLabelOverrides[pageIndex] = updated
                if let document = pdfView.document {
                    applyPageLabelOverridesToDocumentIfNeeded(document)
                }
                pagesTableView.reloadData()
                updateStatusBar()
            }
        }

        bookmarksOutlineView.reloadData()
        markMarkupChangedAndScheduleAutosave()
    }

    @objc private func renamePageLabelFromSidebar() {
        let row = pagesTableView.clickedRow >= 0 ? pagesTableView.clickedRow : pagesTableView.selectedRow
        guard row >= 0, row < sidebarPageCount() else { return }
        let existing = displayPageLabel(forPageIndex: row)
        let alert = NSAlert()
        alert.messageText = "Rename Page Label"
        alert.informativeText = "Enter a new page label."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = existing
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let updated = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.isEmpty else { return }

        pageLabelOverrides[row] = updated
        if let document = pdfView.document {
            applyPageLabelOverridesToDocumentIfNeeded(document)
        }
        pagesTableView.reloadData()
        updateStatusBar()

        if let matching = firstBookmarkForPageIndex(row) {
            let syncPrompt = NSAlert()
            syncPrompt.messageText = "Update matching bookmark too?"
            syncPrompt.informativeText = "Apply \"\(updated)\" to the bookmark for Page \(row + 1) as well?"
            syncPrompt.alertStyle = .informational
            syncPrompt.addButton(withTitle: "Update Bookmark")
            syncPrompt.addButton(withTitle: "Keep Current Bookmark")
            if syncPrompt.runModal() == .alertFirstButtonReturn {
                matching.label = updated
                bookmarkLabelOverrides[bookmarkKey(for: matching)] = updated
                bookmarksOutlineView.reloadData()
            }
        }

        markMarkupChangedAndScheduleAutosave()
    }

    @objc private func deletePagesFromSidebar() {
        guard ensureWorkingCopyBeforeFirstMarkup() else { return }
        guard let document = pdfView.document else {
            beep()
            return
        }
        let pageIndexes = selectedSidebarPageIndexesForDeletion()
        guard !pageIndexes.isEmpty else {
            beep()
            return
        }

        let deletePrompt = NSAlert()
        let pageCountText = pageIndexes.count == 1 ? "page" : "pages"
        deletePrompt.messageText = "Delete \(pageIndexes.count) \(pageCountText)?"
        deletePrompt.informativeText = "This removes the selected page(s) from the PDF."
        deletePrompt.alertStyle = .warning
        deletePrompt.addButton(withTitle: "Delete Pages")
        deletePrompt.addButton(withTitle: "Cancel")
        guard deletePrompt.runModal() == .alertFirstButtonReturn else { return }

        let removedPageSet = Set(pageIndexes)
        let matchingBookmarkCount = countBookmarksDirectlyTargetingPages(removedPageSet, in: document)
        var removeAssociatedBookmarks = false
        if matchingBookmarkCount > 0 {
            let bookmarkPrompt = NSAlert()
            let bookmarkCountText = matchingBookmarkCount == 1 ? "bookmark" : "bookmarks"
            bookmarkPrompt.messageText = "Remove associated \(bookmarkCountText)?"
            bookmarkPrompt.informativeText = "Found \(matchingBookmarkCount) bookmark(s) pointing to the page(s) being deleted."
            bookmarkPrompt.alertStyle = .informational
            bookmarkPrompt.addButton(withTitle: "Remove Bookmarks")
            bookmarkPrompt.addButton(withTitle: "Keep Bookmarks")
            bookmarkPrompt.addButton(withTitle: "Cancel")
            let response = bookmarkPrompt.runModal()
            if response == .alertThirdButtonReturn {
                return
            }
            removeAssociatedBookmarks = (response == .alertFirstButtonReturn)
        }

        if removeAssociatedBookmarks {
            _ = removeBookmarksTargetingPages(removedPageSet, in: document)
            // Bookmark path keys can shift after structural edits.
            bookmarkLabelOverrides.removeAll()
        }

        let sortedDescending = pageIndexes.sorted(by: >)
        for pageIndex in sortedDescending where pageIndex >= 0 && pageIndex < document.pageCount {
            document.removePage(at: pageIndex)
        }
        remapPageIndexedStateAfterDeletingPages(pageIndexes)

        if document.pageCount > 0 {
            let targetIndex = min(pageIndexes.min() ?? 0, document.pageCount - 1)
            if let targetPage = document.page(at: max(0, targetIndex)) {
                pdfView.navigateToPageWithHistory(targetPage)
            }
        } else {
            clearMarkupSelection()
        }

        clearMarkupCache()
        markMarkupChangedAndScheduleAutosave()
        performRefreshMarkups(selecting: nil, forceImmediate: true)
        reloadBookmarks()
        requestChromeRefresh(immediate: true)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard outlineView == bookmarksOutlineView else { return 0 }
        let node = (item as? PDFOutline) ?? pdfView.document?.outlineRoot
        return node?.numberOfChildren ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard outlineView == bookmarksOutlineView, let node = item as? PDFOutline else { return false }
        return node.numberOfChildren > 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = (item as? PDFOutline) ?? pdfView.document?.outlineRoot
        return node?.child(at: index) as Any
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard outlineView == bookmarksOutlineView, let node = item as? PDFOutline else { return nil }
        let title = displayBookmarkTitle(for: node)
        let indicator = bookmarkContainsCurrentPage(node) ? "● " : "  "
        let text = "\(indicator)\(title)"
        let cell = NSTextField(labelWithString: text)
        cell.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        cell.textColor = .labelColor
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    private func configureMarkupsSidebar() {
        let pageColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        pageColumn.title = "Page"
        pageColumn.width = 56
        markupsTable.addTableColumn(pageColumn)

        let typeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        typeColumn.title = "Type"
        typeColumn.width = 100
        markupsTable.addTableColumn(typeColumn)

        let authorColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("author"))
        authorColumn.title = "Author"
        authorColumn.width = 130
        markupsTable.addTableColumn(authorColumn)

        let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        textColumn.title = "Text"
        textColumn.width = 240
        markupsTable.addTableColumn(textColumn)

        markupsTable.usesAlternatingRowBackgroundColors = true
        markupsTable.allowsMultipleSelection = true
        markupsTable.delegate = self
        markupsTable.dataSource = self
        markupsTable.headerView = NSTableHeaderView()
        markupsTable.rowHeight = 24
        markupsTable.target = self
        markupsTable.action = #selector(selectMarkupFromTable)

        markupFilterField.placeholderString = "Filter markups"
        markupFilterField.target = self
        markupFilterField.action = #selector(filterMarkups)
        markupsCountLabel.textColor = .secondaryLabelColor

        toolSettingsToolLabel.textColor = .secondaryLabelColor
        toolSettingsLineWidthPopup.removeAllItems()
        toolSettingsLineWidthPopup.addItems(withTitles: lineWeightLevels.map(String.init))
        toolSettingsLineWidthPopup.selectItem(withTitle: "5")
        toolSettingsStrokeColorWell.color = .systemRed
        toolSettingsHatchBackgroundColorWell.color = .white
        toolSettingsFontSizePopup.removeAllItems()
        toolSettingsFontSizePopup.addItems(withTitles: standardFontSizes.map { "\($0) pt" })
        let nearestInitialFontSize = standardFontSizes.min { lhs, rhs in
            abs(CGFloat(lhs) - pdfView.textFontSize) < abs(CGFloat(rhs) - pdfView.textFontSize)
        } ?? 15
        toolSettingsFontSizePopup.selectItem(withTitle: "\(nearestInitialFontSize) pt")
        toolSettingsFontSizePopup.translatesAutoresizingMaskIntoConstraints = false
        toolSettingsFontSizePopup.widthAnchor.constraint(equalToConstant: 68).isActive = true
        toolSettingsOpacityValueLabel.alignment = .right
        toolSettingsOpacityValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        toolSettingsOpacitySlider.target = self
        toolSettingsOpacitySlider.action = #selector(toolSettingsOpacityChanged)
        toolSettingsStrokeColorWell.target = self
        toolSettingsStrokeColorWell.action = #selector(toolSettingsChanged)
        toolSettingsFillColorWell.target = self
        toolSettingsFillColorWell.action = #selector(toolSettingsChanged)
        toolSettingsHatchBackgroundColorWell.target = self
        toolSettingsHatchBackgroundColorWell.action = #selector(toolSettingsChanged)
        toolSettingsOutlineColorWell.target = self
        toolSettingsOutlineColorWell.action = #selector(toolSettingsChanged)
        toolSettingsOutlineWidthPopup.removeAllItems()
        toolSettingsOutlineWidthPopup.addItems(withTitles: ["None", "1 pt", "2 pt", "3 pt", "4 pt", "5 pt", "6 pt", "8 pt", "10 pt"])
        toolSettingsOutlineWidthPopup.selectItem(withTitle: "None")
        toolSettingsOutlineWidthPopup.target = self
        toolSettingsOutlineWidthPopup.action = #selector(toolSettingsChanged)
        toolSettingsFontSizePopup.target = self
        toolSettingsFontSizePopup.action = #selector(toolSettingsChanged)
        toolSettingsArrowPopup.removeAllItems()
        toolSettingsArrowPopup.addItems(withTitles: MarkupPDFView.ArrowEndStyle.allCases.map(\.displayName))
        toolSettingsArrowPopup.selectItem(at: 0)
        toolSettingsArrowPopup.target = self
        toolSettingsArrowPopup.action = #selector(toolSettingsChanged)
        toolSettingsArrowSizePopup.removeAllItems()
        toolSettingsArrowSizePopup.addItems(withTitles: ["2 pt", "3 pt", "4 pt", "5 pt", "6 pt", "8 pt", "10 pt", "12 pt", "16 pt", "20 pt"])
        toolSettingsArrowSizePopup.selectItem(withTitle: "8 pt")
        toolSettingsArrowSizePopup.target = self
        toolSettingsArrowSizePopup.action = #selector(toolSettingsChanged)
        toolSettingsHatchPopup.removeAllItems()
        toolSettingsHatchPopup.addItems(withTitles: MarkupPDFView.RectangleHatchStyle.allCases.map(\.displayName))
        toolSettingsHatchPopup.selectItem(withTitle: MarkupPDFView.RectangleHatchStyle.solid.displayName)
        toolSettingsHatchPopup.target = self
        toolSettingsHatchPopup.action = #selector(toolSettingsChanged)
        toolSettingsLineWidthPopup.target = self
        toolSettingsLineWidthPopup.action = #selector(toolSettingsChanged)
        snapshotColorizeButton.target = self
        snapshotColorizeButton.action = #selector(colorizeSnapshotsBlackToRed)
        snapshotColorizeButton.bezelStyle = .texturedRounded
        snapshotColorizeButton.isHidden = true

        measurementCountLabel.textColor = .secondaryLabelColor
        measurementTotalLabel.textColor = .secondaryLabelColor
        configureSnapSectionUI()
        configureLayersSectionUI()
        configureSectionButtons()
        updateToolSettingsUIForCurrentTool()
        applyToolSettingsToPDFView()
    }

    private func configureActionsPopup(highlightButton: NSButton, exportButton: NSButton, refreshMarkupsButton: NSButton, deleteMarkupButton: NSButton, editMarkupButton: NSButton) {
        actionsPopup.removeAllItems()
        actionsPopup.addItem(withTitle: "")

        let menu = NSMenu(title: "Actions")
        menu.addItem(withTitle: highlightButton.title, action: highlightButton.action, keyEquivalent: "h")
        menu.item(at: menu.numberOfItems - 1)?.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: exportButton.title, action: exportButton.action, keyEquivalent: "S")
        menu.item(at: menu.numberOfItems - 1)?.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: refreshMarkupsButton.title, action: refreshMarkupsButton.action, keyEquivalent: "r")
        menu.item(at: menu.numberOfItems - 1)?.keyEquivalentModifierMask = [.command]
        menu.addItem(withTitle: deleteMarkupButton.title, action: deleteMarkupButton.action, keyEquivalent: "\u{8}")
        menu.item(at: menu.numberOfItems - 1)?.keyEquivalentModifierMask = []
        menu.addItem(withTitle: editMarkupButton.title, action: editMarkupButton.action, keyEquivalent: "e")
        menu.item(at: menu.numberOfItems - 1)?.keyEquivalentModifierMask = [.command]
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Bring to Front", action: #selector(commandBringMarkupToFront(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Send to Back", action: #selector(commandSendMarkupToBack(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Bring Forward", action: #selector(commandBringMarkupForward(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Send Backward", action: #selector(commandSendMarkupBackward(_:)), keyEquivalent: "")

        for item in menu.items {
            item.target = self
        }
        actionsPopup.menu = menu
    }

    private func configureStatusBar() {
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = panelBackgroundColor.cgColor

        let labels = [statusPageSizeLabel, statusPageLabel, statusZoomLabel, statusScaleLabel]
        labels.forEach {
            $0.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            $0.textColor = .secondaryLabelColor
        }

        let stack = NSStackView(views: labels)
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: statusBar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: statusBar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor)
        ])
    }

    private func configureBusyOverlay() {
        busyOverlayView.wantsLayer = true
        busyOverlayView.layer?.cornerRadius = 10
        busyOverlayView.layer?.backgroundColor = panelBackgroundColor.cgColor
        busyOverlayView.translatesAutoresizingMaskIntoConstraints = false
        busyOverlayView.isHidden = true

        busyStatusLabel.alignment = .center
        busyStatusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        busyStatusLabel.textColor = .labelColor

        busyDetailLabel.alignment = .center
        busyDetailLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        busyDetailLabel.textColor = .secondaryLabelColor
        busyDetailLabel.stringValue = ""

        busySubdetailLabel.alignment = .center
        busySubdetailLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        busySubdetailLabel.textColor = .secondaryLabelColor
        busySubdetailLabel.stringValue = ""

        busyProgressIndicator.style = .bar
        busyProgressIndicator.isIndeterminate = true
        busyProgressIndicator.controlSize = .small
        busyProgressIndicator.translatesAutoresizingMaskIntoConstraints = false
        busyProgressIndicator.widthAnchor.constraint(equalToConstant: 340).isActive = true

        busyCancelButton.bezelStyle = .rounded
        busyCancelButton.controlSize = .small
        busyCancelButton.target = self
        busyCancelButton.action = #selector(handleBusyCancel(_:))
        busyCancelButton.isHidden = true

        let stack = NSStackView(views: [busyStatusLabel, busyDetailLabel, busySubdetailLabel, busyProgressIndicator, busyCancelButton])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .centerX
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        busyOverlayView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: busyOverlayView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: busyOverlayView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: busyOverlayView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: busyOverlayView.bottomAnchor)
        ])
    }

    @objc private func handleBusyCancel(_ sender: Any?) {
        busyCancelHandler?()
    }

    private func configureCaptureToast() {
        captureToastView.wantsLayer = true
        captureToastView.layer?.cornerRadius = 8
        captureToastView.layer?.backgroundColor = panelBackgroundColor.cgColor
        captureToastView.translatesAutoresizingMaskIntoConstraints = false
        captureToastView.alphaValue = 0
        captureToastView.isHidden = true

        captureToastLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        captureToastLabel.textColor = .labelColor
        captureToastLabel.alignment = .center
        captureToastLabel.translatesAutoresizingMaskIntoConstraints = false

        captureToastView.addSubview(captureToastLabel)
        NSLayoutConstraint.activate([
            captureToastLabel.topAnchor.constraint(equalTo: captureToastView.topAnchor, constant: 8),
            captureToastLabel.leadingAnchor.constraint(equalTo: captureToastView.leadingAnchor, constant: 12),
            captureToastLabel.trailingAnchor.constraint(equalTo: captureToastView.trailingAnchor, constant: -12),
            captureToastLabel.bottomAnchor.constraint(equalTo: captureToastView.bottomAnchor, constant: -8)
        ])
    }

    private func showCaptureToast(_ message: String) {
        captureToastHideWorkItem?.cancel()
        captureToastLabel.stringValue = message
        captureToastView.isHidden = false
        captureSound?.play()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            captureToastView.animator().alphaValue = 1.0
        }

        let hideWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.captureToastView.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                DispatchQueue.main.async {
                    self?.captureToastView.isHidden = true
                }
            })
        }
        captureToastHideWorkItem = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: hideWork)
    }

    func beginBusyIndicator(_ message: String, detail: String? = nil, lockInteraction: Bool = true) {
        busyOperationDepth += 1
        busyStatusLabel.stringValue = message
        busyDetailLabel.stringValue = detail ?? ""
        busySubdetailLabel.stringValue = ""
        busyProgressIndicator.isIndeterminate = true
        busyProgressIndicator.doubleValue = 0
        setBusyCancelAction(nil)
        if busyOperationDepth == 1 {
            busyInteractionLocked = lockInteraction
            view.window?.ignoresMouseEvents = lockInteraction
        } else if lockInteraction {
            busyInteractionLocked = true
            view.window?.ignoresMouseEvents = true
        }
        guard busyOperationDepth == 1 else { return }
        busyOverlayView.isHidden = false
        busyProgressIndicator.startAnimation(nil)
        view.layoutSubtreeIfNeeded()
        busyOverlayView.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }

    func endBusyIndicator() {
        busyOperationDepth = max(0, busyOperationDepth - 1)
        guard busyOperationDepth == 0 else { return }
        view.window?.ignoresMouseEvents = false
        busyInteractionLocked = false
        busyProgressIndicator.stopAnimation(nil)
        busyProgressIndicator.isIndeterminate = true
        busyProgressIndicator.minValue = 0
        busyProgressIndicator.maxValue = 100
        busyProgressIndicator.doubleValue = 0
        busyOverlayView.isHidden = true
        busyDetailLabel.stringValue = ""
        busySubdetailLabel.stringValue = ""
        setBusyCancelAction(nil)
    }

    func updateBusyIndicatorStatus(_ status: String) {
        busyStatusLabel.stringValue = status
        busyOverlayView.displayIfNeeded()
    }

    func updateBusyIndicatorDetail(_ detail: String) {
        busyDetailLabel.stringValue = detail
        busyOverlayView.displayIfNeeded()
    }

    func updateBusyIndicatorSubdetail(_ detail: String) {
        busySubdetailLabel.stringValue = detail
        busyOverlayView.displayIfNeeded()
    }

    func updateBusyIndicatorProgress(current: Int, total: Int) {
        guard total > 0 else { return }
        busyProgressIndicator.isIndeterminate = false
        busyProgressIndicator.minValue = 0
        busyProgressIndicator.maxValue = Double(total)
        busyProgressIndicator.doubleValue = Double(max(0, min(current, total)))
        busyOverlayView.displayIfNeeded()
    }

    func setBusyCancelAction(_ handler: (() -> Void)?, title: String = "Cancel", enabled: Bool = true) {
        busyCancelHandler = handler
        if handler == nil {
            busyCancelButton.isHidden = true
            busyCancelButton.isEnabled = true
            busyCancelButton.title = "Cancel"
            return
        }
        busyCancelButton.title = title
        busyCancelButton.isEnabled = enabled
        busyCancelButton.isHidden = false
        busyOverlayView.displayIfNeeded()
    }

    func clearMarkupSelection() {
        markupsTable.deselectAll(nil)
        lastDirectlySelectedAnnotation = nil
        clearGroupedPasteDragSelection()
        clearSelectionOverlayLayers()
        updateToolSettingsUIForCurrentTool()
        updateStatusBar()
    }

    private func configureEmptyStateView() {
        emptyStateView.wantsLayer = true
        emptyStateView.layer?.cornerRadius = 12
        emptyStateView.layer?.backgroundColor = panelBackgroundColor.cgColor
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        emptyStateTitle.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        emptyStateOpenButton.bezelStyle = .texturedRounded
        emptyStateRecentButton.bezelStyle = .texturedRounded
        emptyStateSampleButton.bezelStyle = .texturedRounded
        emptyStateBatchMobileButton.bezelStyle = .texturedRounded

        let actions = NSStackView(views: [emptyStateOpenButton, emptyStateRecentButton, emptyStateSampleButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY

        let stack = NSStackView(views: [emptyStateTitle, actions, emptyStateBatchMobileButton])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .centerX
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        pdfCanvasContainer.addSubview(emptyStateView)
        emptyStateView.addSubview(stack)

        NSLayoutConstraint.activate([
            emptyStateView.centerXAnchor.constraint(equalTo: pdfView.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor),
            emptyStateView.widthAnchor.constraint(equalToConstant: 620),

            stack.topAnchor.constraint(equalTo: emptyStateView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: emptyStateView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: emptyStateView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: emptyStateView.bottomAnchor)
        ])
    }

    @objc private func showOpenRecentMenuFromEmptyState(_ sender: NSButton) {
        guard let menu = openRecentMenuFromMainMenu() else {
            runAlert(
                title: "Open Recent Unavailable",
                informativeText: "No recent documents are currently available.",
                style: .warning
            )
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func openRecentMenuFromMainMenu() -> NSMenu? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        for topLevelItem in mainMenu.items where topLevelItem.title == "File" {
            guard let fileMenu = topLevelItem.submenu else { continue }
            guard let openRecentRoot = fileMenu.items.first(where: { $0.title == "Open Recent" }) else { continue }
            guard let recentMenu = openRecentRoot.submenu else { continue }
            return recentMenu.copy() as? NSMenu
        }
        return nil
    }

    private func setupToolbarControlStack() {
        openButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Open PDF")
        openButton.imagePosition = .imageOnly
        openButton.bezelStyle = .texturedRounded
        openButton.toolTip = "Open PDF"

        autoNameSheetsButton.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Auto-Generate Sheet Names and Bookmarks")
            ?? NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Auto-Generate Sheet Names and Bookmarks")
        autoNameSheetsButton.imagePosition = .imageOnly
        autoNameSheetsButton.bezelStyle = .texturedRounded
        autoNameSheetsButton.toolTip = "Auto-Generate Sheet Names/Bookmarks"
        batchLinkSheetsButton.image = NSImage(systemSymbolName: "link.badge.plus", accessibilityDescription: "Batch Link Sheet Numbers")
            ?? NSImage(systemSymbolName: "link", accessibilityDescription: "Batch Link Sheet Numbers")
        batchLinkSheetsButton.imagePosition = .imageOnly
        batchLinkSheetsButton.bezelStyle = .texturedRounded
        batchLinkSheetsButton.toolTip = "Batch Link Sheet Numbers (Cmd+Shift+H)"
        flattenPDFButton.image = NSImage(systemSymbolName: "square.stack.3d.down.forward", accessibilityDescription: "Flatten PDF")
            ?? NSImage(systemSymbolName: "square.stack.3d.forward.dottedline", accessibilityDescription: "Flatten PDF")
        flattenPDFButton.imagePosition = .imageOnly
        flattenPDFButton.bezelStyle = .texturedRounded
        flattenPDFButton.toolTip = "Flatten PDF"
        reduceFileSizeButton.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "Reduce File Size")
            ?? NSImage(systemSymbolName: "doc", accessibilityDescription: "Reduce File Size")
        reduceFileSizeButton.imagePosition = .imageOnly
        reduceFileSizeButton.bezelStyle = .texturedRounded
        reduceFileSizeButton.toolTip = "Reduce File Size"

        actionsPopup.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Actions")
        actionsPopup.imagePosition = .imageOnly
        actionsPopup.bezelStyle = .texturedRounded
        actionsPopup.toolTip = "Actions"

        gridToggleButton.setButtonType(.toggle)
        gridToggleButton.image = NSImage(systemSymbolName: "grid", accessibilityDescription: "Toggle Grid")
        gridToggleButton.imagePosition = .imageLeading
        gridToggleButton.title = "X"
        gridToggleButton.bezelStyle = .texturedRounded
        gridToggleButton.toolTip = "Show/Hide Grid (X)"
        gridToggleButton.target = self
        gridToggleButton.action = #selector(toggleGridOverlay)
        gridToggleButton.state = isGridVisible ? .on : .off
        gridToggleButton.wantsLayer = true

        applyToggleIconAppearance(gridToggleButton, enabled: isGridVisible)

        pageJumpField.isHidden = true
        configureScalePresetPopup()

        configureToolSelectorAppearance()
        configureTakeoffSelectorAppearance()
        toolSelector.segmentStyle = .texturedRounded
        toolSelector.controlSize = .small
        takeoffSelector.segmentStyle = .texturedRounded
        takeoffSelector.controlSize = .small

        if !didInstallToolbarWidthConstraints {
            didInstallToolbarWidthConstraints = true
        }

        toolbarControlsStack.orientation = .horizontal
        toolbarControlsStack.spacing = 8
        toolbarControlsStack.alignment = .centerY
        toolbarControlsStack.setHuggingPriority(.required, for: .horizontal)
        toolbarControlsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        toolbarModeGroupsStack.orientation = .horizontal
        toolbarModeGroupsStack.spacing = 6
        toolbarModeGroupsStack.alignment = .centerY
        if toolbarModeGroupsStack.arrangedSubviews.isEmpty {
            if !ToolMode.navigationToolbarModes.isEmpty {
                toolbarModeGroupsStack.addArrangedSubview(makeToolbarButtonGroup(title: "Navigate", modes: ToolMode.navigationToolbarModes))
            }
            if !ToolMode.drawingToolbarModes.isEmpty {
                toolbarModeGroupsStack.addArrangedSubview(makeToolbarButtonGroup(title: "Markup", modes: ToolMode.drawingToolbarModes))
            }
            if !ToolMode.geometryToolbarModes.isEmpty {
                toolbarModeGroupsStack.addArrangedSubview(makeToolbarButtonGroup(title: "Geometry", modes: ToolMode.geometryToolbarModes))
            }
        }
        if toolbarControlsStack.arrangedSubviews.isEmpty {
            toolbarControlsStack.addArrangedSubview(openButton)
            toolbarControlsStack.addArrangedSubview(autoNameSheetsButton)
            toolbarControlsStack.addArrangedSubview(batchLinkSheetsButton)
            toolbarControlsStack.addArrangedSubview(flattenPDFButton)
            toolbarControlsStack.addArrangedSubview(reduceFileSizeButton)
            toolbarControlsStack.addArrangedSubview(toolbarModeGroupsStack)
        }

        toolbarSearchField.placeholderString = "Search document + markups"
        toolbarSearchField.sendsWholeSearchString = false
        toolbarSearchField.maximumRecents = 0
        toolbarSearchField.recentsAutosaveName = nil
        toolbarSearchField.target = self
        toolbarSearchField.action = #selector(searchFieldChanged)
        toolbarSearchField.translatesAutoresizingMaskIntoConstraints = false
        toolbarSearchField.widthAnchor.constraint(equalToConstant: 330).isActive = true
        toolbarSearchPrevButton.title = ""
        toolbarSearchPrevButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous Result")
            ?? NSImage(systemSymbolName: "arrow.left", accessibilityDescription: "Previous Result")
        toolbarSearchPrevButton.imagePosition = .imageOnly
        toolbarSearchPrevButton.bezelStyle = .texturedRounded
        toolbarSearchPrevButton.target = self
        toolbarSearchPrevButton.action = #selector(selectPreviousSearchHit)
        toolbarSearchPrevButton.toolTip = "Previous Result"
        toolbarSearchPrevButton.setButtonType(.momentaryPushIn)
        toolbarSearchPrevButton.controlSize = .small
        toolbarSearchNextButton.title = ""
        toolbarSearchNextButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next Result")
            ?? NSImage(systemSymbolName: "arrow.right", accessibilityDescription: "Next Result")
        toolbarSearchNextButton.imagePosition = .imageOnly
        toolbarSearchNextButton.bezelStyle = .texturedRounded
        toolbarSearchNextButton.target = self
        toolbarSearchNextButton.action = #selector(selectNextSearchHit)
        toolbarSearchNextButton.toolTip = "Next Result"
        toolbarSearchNextButton.setButtonType(.momentaryPushIn)
        toolbarSearchNextButton.controlSize = .small
        toolbarSearchCountLabel.textColor = .secondaryLabelColor
        toolbarSearchCountLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        toolbarSearchCountLabel.stringValue = "0"
        ensureSearchPanel()
        updateSearchControlsState()

        secondaryToolbarControlsStack.orientation = .horizontal
        secondaryToolbarControlsStack.spacing = 8
        secondaryToolbarControlsStack.alignment = .centerY
        secondaryToolbarControlsStack.setHuggingPriority(.required, for: .horizontal)
        secondaryToolbarControlsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        toolbarQuickStrokeColorWell.target = self
        toolbarQuickStrokeColorWell.action = #selector(toolbarQuickSettingsChanged)
        toolbarQuickFillColorWell.target = self
        toolbarQuickFillColorWell.action = #selector(toolbarQuickSettingsChanged)
        toolbarQuickLineWidthPopup.removeAllItems()
        toolbarQuickLineWidthPopup.addItems(withTitles: lineWeightLevels.map(String.init))
        toolbarQuickLineWidthPopup.target = self
        toolbarQuickLineWidthPopup.action = #selector(toolbarQuickSettingsChanged)
        toolbarQuickFontSizePopup.removeAllItems()
        toolbarQuickFontSizePopup.addItems(withTitles: standardFontSizes.map { "\($0) pt" })
        toolbarQuickFontSizePopup.target = self
        toolbarQuickFontSizePopup.action = #selector(toolbarQuickSettingsChanged)
        toolbarQuickArrowPopup.removeAllItems()
        toolbarQuickArrowPopup.addItems(withTitles: MarkupPDFView.ArrowEndStyle.allCases.map(\.displayName))
        toolbarQuickArrowPopup.target = self
        toolbarQuickArrowPopup.action = #selector(toolbarQuickSettingsChanged)
        toolbarQuickOpacitySlider.target = self
        toolbarQuickOpacitySlider.action = #selector(toolbarQuickSettingsChanged)
        toolbarQuickOpacitySlider.controlSize = .small
        toolbarQuickOpacitySlider.translatesAutoresizingMaskIntoConstraints = false
        toolbarQuickOpacitySlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        toolbarQuickOpacityValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        toolbarQuickOpacityValueLabel.textColor = .secondaryLabelColor

        toolbarQuickControlsStack.orientation = .horizontal
        toolbarQuickControlsStack.spacing = 8
        toolbarQuickControlsStack.alignment = .centerY
        if toolbarQuickControlsStack.arrangedSubviews.isEmpty {
            toolbarQuickControlsStack.addArrangedSubview(makeToolbarQuickControl(key: "stroke", label: toolbarQuickStrokeLabel, control: toolbarQuickStrokeColorWell))
            toolbarQuickControlsStack.addArrangedSubview(makeToolbarQuickControl(key: "fill", label: toolbarQuickFillLabel, control: toolbarQuickFillColorWell))
            toolbarQuickControlsStack.addArrangedSubview(makeToolbarQuickControl(key: "width", label: toolbarQuickWidthLabel, control: toolbarQuickLineWidthPopup))
            toolbarQuickControlsStack.addArrangedSubview(makeToolbarQuickControl(key: "font", label: toolbarQuickFontSizeLabel, control: toolbarQuickFontSizePopup))
            toolbarQuickControlsStack.addArrangedSubview(makeToolbarQuickControl(key: "arrow", label: toolbarQuickArrowLabel, control: toolbarQuickArrowPopup))
            let opacityContent = NSStackView(views: [toolbarQuickOpacitySlider, toolbarQuickOpacityValueLabel])
            opacityContent.orientation = .horizontal
            opacityContent.spacing = 4
            opacityContent.alignment = .centerY
            let opacityControl = NSStackView(views: [toolbarQuickOpacityLabel, opacityContent])
            opacityControl.orientation = .horizontal
            opacityControl.spacing = 4
            opacityControl.alignment = .centerY
            toolbarQuickControlContainers["opacity"] = opacityControl
            toolbarQuickControlsStack.addArrangedSubview(opacityControl)
        }

        if secondaryToolbarControlsStack.arrangedSubviews.isEmpty {
            if !ToolMode.takeoffToolbarModes.isEmpty {
                let takeoffToolbarGroup = makeToolbarButtonGroup(title: "Takeoff", modes: ToolMode.takeoffToolbarModes)
                secondaryToolbarControlsStack.addArrangedSubview(takeoffToolbarGroup)
            }
            secondaryToolbarControlsStack.addArrangedSubview(scalePresetPopup)
            secondaryToolbarControlsStack.addArrangedSubview(gridToggleButton)
            secondaryToolbarControlsStack.addArrangedSubview(actionsPopup)
        }
        refreshToolbarShortcutTooltips()
        refreshToolbarToolButtons()
        syncToolbarQuickControlsFromToolSettings()
    }

    private func setGridVisibleState(_ visible: Bool) {
        isGridVisible = visible
        gridToggleButton.state = visible ? .on : .off
        pdfView.setGridVisible(visible)
        applyToggleIconAppearance(gridToggleButton, enabled: visible)
    }

    func setHyperlinkHighlightsVisible(_ visible: Bool) {
        isHyperlinkHighlightsVisible = visible
        UserDefaults.standard.set(visible, forKey: Self.defaultsHyperlinkHighlightsVisibleKey)
        pdfView.setHyperlinkHighlightsVisible(visible)
        if let item = NSApp.mainMenu?.item(withTitle: "View")?.submenu?.items.first(where: { $0.action == #selector(commandToggleHyperlinkHighlights(_:)) }) {
            item.state = visible ? .on : .off
        }
    }

    func toggleGridVisibilityShortcut() {
        setGridVisibleState(!isGridVisible)
    }

    @objc private func toggleGridOverlay() {
        setGridVisibleState(gridToggleButton.state == .on)
    }

    private func setEndpointSnapEnabled(_ enabled: Bool) {
        isEndpointSnapEnabled = enabled
        pdfView.setEndpointSnapEnabled(enabled)
        configureSnapSectionUI()
    }

    func setOrthoSnapEnabled(_ enabled: Bool) {
        isOrthoSnapEnabled = enabled
        pdfView.setOrthoSnapEnabled(enabled)
        if let item = NSApp.mainMenu?.item(withTitle: "View")?.submenu?.items.first(where: { $0.action == #selector(commandToggleOrthoSnap(_:)) }) {
            item.state = enabled ? .on : .off
        }
        configureSnapSectionUI()
    }

    private func setMidpointSnapEnabled(_ enabled: Bool) {
        isMidpointSnapEnabled = enabled
        pdfView.setMidpointSnapEnabled(enabled)
        configureSnapSectionUI()
    }

    private func setIntersectionSnapEnabled(_ enabled: Bool) {
        isIntersectionSnapEnabled = enabled
        pdfView.setIntersectionSnapEnabled(enabled)
        configureSnapSectionUI()
    }

    private func makeSnapRow(title: String, isOn: Bool, action: Selector) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail

        let toggle = NSSwitch(frame: .zero)
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = action

        let row = NSStackView(views: [label, NSView(), toggle])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    private func configureSnapSectionUI() {
        snapSectionContent.orientation = .vertical
        snapSectionContent.spacing = 6
        snapRowsStack.orientation = .vertical
        snapRowsStack.spacing = 4

        for view in snapRowsStack.arrangedSubviews {
            snapRowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        snapRowsStack.addArrangedSubview(makeSnapRow(title: "Snap to Ortho - Tap OPTION", isOn: isOrthoSnapEnabled, action: #selector(snapOrthoSwitchChanged(_:))))
        snapRowsStack.addArrangedSubview(makeSnapRow(title: "Snap to Endpoint", isOn: isEndpointSnapEnabled, action: #selector(snapEndpointSwitchChanged(_:))))
        snapRowsStack.addArrangedSubview(makeSnapRow(title: "Snap to Midpoint", isOn: isMidpointSnapEnabled, action: #selector(snapMidpointSwitchChanged(_:))))
        snapRowsStack.addArrangedSubview(makeSnapRow(title: "Snap to Intersection", isOn: isIntersectionSnapEnabled, action: #selector(snapIntersectionSwitchChanged(_:))))

        for view in snapSectionContent.arrangedSubviews {
            snapSectionContent.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        snapSectionContent.addArrangedSubview(snapRowsStack)
    }

    @objc private func snapOrthoSwitchChanged(_ sender: NSSwitch) {
        setOrthoSnapEnabled(sender.state == .on)
    }

    @objc private func snapEndpointSwitchChanged(_ sender: NSSwitch) {
        setEndpointSnapEnabled(sender.state == .on)
    }

    @objc private func snapMidpointSwitchChanged(_ sender: NSSwitch) {
        setMidpointSnapEnabled(sender.state == .on)
    }

    @objc private func snapIntersectionSwitchChanged(_ sender: NSSwitch) {
        setIntersectionSnapEnabled(sender.state == .on)
    }

    @objc private func toggleSnapSection() {
        snapSectionContent.isHidden.toggle()
        updateSectionHeaders()
    }

    private func updateSectionHeaders() {
        toolSettingsSectionButton.title = "Tool Settings"
        markupsSectionButton.title = "\(markupsSectionContent.isHidden ? "▸" : "▾") Markups"
        summarySectionButton.title = "\(summarySectionContent.isHidden ? "▸" : "▾") Takeoff Summary"
        snapSectionButton.title = "\(snapSectionContent.isHidden ? "▸" : "▾") Snap"
        layersSectionButton.title = "\(layersSectionContent.isHidden ? "▸" : "▾") Layers"
    }

    private func configureSectionButtons() {
        markupsSectionButton.target = self
        markupsSectionButton.action = #selector(toggleMarkupsSection)
        summarySectionButton.target = self
        summarySectionButton.action = #selector(toggleSummarySection)
        snapSectionButton.target = self
        snapSectionButton.action = #selector(toggleSnapSection)
        layersSectionButton.target = self
        layersSectionButton.action = #selector(toggleLayersSection)

        toolSettingsSectionButton.isBordered = false
        toolSettingsSectionButton.isEnabled = false
        toolSettingsSectionButton.alignment = .left
        toolSettingsSectionButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        toolSettingsSectionButton.contentTintColor = .secondaryLabelColor

        [markupsSectionButton, summarySectionButton, snapSectionButton, layersSectionButton].forEach {
            $0.setButtonType(.momentaryPushIn)
            $0.bezelStyle = .recessed
            $0.alignment = .left
            $0.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        }
        updateSectionHeaders()
    }

    @objc private func toggleMarkupsSection() {
        markupsSectionContent.isHidden.toggle()
        updateSectionHeaders()
    }

    @objc private func toggleSummarySection() {
        summarySectionContent.isHidden.toggle()
        updateSectionHeaders()
    }

    @objc private func toggleLayersSection() {
        layersSectionContent.isHidden.toggle()
        updateSectionHeaders()
    }

    @objc private func toggleToolSettingsSection() {
        toolSettingsSectionContent.isHidden.toggle()
        updateSectionHeaders()
    }

    private func applyToggleIconAppearance(_ button: NSButton, enabled: Bool) {
        let active = NSColor.systemBlue
        let inactive = NSColor.tertiaryLabelColor
        button.contentTintColor = enabled ? active : inactive
        button.bezelColor = enabled ? active.withAlphaComponent(0.30) : NSColor.clear
        button.layer?.cornerRadius = 6
        button.layer?.borderWidth = enabled ? 1.0 : 0.0
        button.layer?.borderColor = enabled ? active.withAlphaComponent(0.85).cgColor : NSColor.clear.cgColor
        button.layer?.backgroundColor = enabled ? active.withAlphaComponent(0.20).cgColor : NSColor.clear.cgColor
        button.layer?.shadowColor = active.cgColor
        button.layer?.shadowOpacity = enabled ? 0.95 : 0.0
        button.layer?.shadowRadius = enabled ? 10.0 : 0.0
        button.layer?.shadowOffset = .zero
    }

    private func configureCollapsedSidebarRevealButton() {
        if let image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Show Tool Settings Sidebar")
            ?? NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Show Tool Settings Sidebar")
            ?? NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: "Show Tool Settings Sidebar")
            ?? NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Show Tool Settings Sidebar") {
            collapsedSidebarRevealButton.image = image
            collapsedSidebarRevealButton.title = ""
        } else {
            collapsedSidebarRevealButton.image = nil
            collapsedSidebarRevealButton.title = ">"
        }
        collapsedSidebarRevealButton.imagePosition = .imageOnly
        collapsedSidebarRevealButton.bezelStyle = .regularSquare
        collapsedSidebarRevealButton.controlSize = .small
        collapsedSidebarRevealButton.target = self
        collapsedSidebarRevealButton.action = #selector(toggleSidebar)
        collapsedSidebarRevealButton.toolTip = "Show Tool Settings Sidebar"
        collapsedSidebarRevealButton.translatesAutoresizingMaskIntoConstraints = false
        collapsedSidebarRevealButton.isBordered = true
        collapsedSidebarRevealButton.wantsLayer = true
        collapsedSidebarRevealButton.layer?.cornerRadius = 6
        collapsedSidebarRevealButton.layer?.backgroundColor = panelBackgroundColor.cgColor
        collapsedSidebarRevealButton.setContentHuggingPriority(.required, for: .horizontal)
        collapsedSidebarRevealButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        collapsedSidebarRevealButton.isHidden = !isSidebarCollapsed
    }

    private func configureDocumentTabsBar() {
        documentTabsBar.wantsLayer = true
        documentTabsBar.layer?.borderWidth = 1
        documentTabsBar.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        documentTabsBar.layer?.backgroundColor = panelBackgroundColor.cgColor
        documentTabsBar.translatesAutoresizingMaskIntoConstraints = false

        documentTabsScrollView.drawsBackground = false
        documentTabsScrollView.borderType = .noBorder
        documentTabsScrollView.hasHorizontalScroller = true
        documentTabsScrollView.hasVerticalScroller = false
        documentTabsScrollView.autohidesScrollers = true
        documentTabsScrollView.horizontalScrollElasticity = .automatic
        documentTabsScrollView.verticalScrollElasticity = .none
        documentTabsScrollView.translatesAutoresizingMaskIntoConstraints = false

        documentTabsStack.orientation = .horizontal
        documentTabsStack.alignment = .centerY
        documentTabsStack.spacing = 6
        documentTabsStack.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)
        documentTabsStack.translatesAutoresizingMaskIntoConstraints = false
        documentTabsScrollView.documentView = documentTabsStack
        documentTabsBar.addSubview(documentTabsScrollView)

        NSLayoutConstraint.activate([
            documentTabsScrollView.topAnchor.constraint(equalTo: documentTabsBar.topAnchor),
            documentTabsScrollView.leadingAnchor.constraint(equalTo: documentTabsBar.leadingAnchor),
            documentTabsScrollView.trailingAnchor.constraint(equalTo: documentTabsBar.trailingAnchor),
            documentTabsScrollView.bottomAnchor.constraint(equalTo: documentTabsBar.bottomAnchor),

            documentTabsStack.topAnchor.constraint(equalTo: documentTabsScrollView.contentView.topAnchor),
            documentTabsStack.leadingAnchor.constraint(equalTo: documentTabsScrollView.contentView.leadingAnchor),
            documentTabsStack.trailingAnchor.constraint(equalTo: documentTabsScrollView.contentView.trailingAnchor),
            documentTabsStack.bottomAnchor.constraint(equalTo: documentTabsScrollView.contentView.bottomAnchor),
            documentTabsStack.heightAnchor.constraint(equalTo: documentTabsScrollView.contentView.heightAnchor)
        ])
    }

    private func refreshDocumentTabs() {
        for view in documentTabsStack.arrangedSubviews {
            documentTabsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let current = openDocumentURL.map { canonicalDocumentURL($0) }
        var ordered = sessionDocumentURLs.map { canonicalDocumentURL($0) }
        if let current, !ordered.contains(current) {
            ordered.append(current)
        }

        if ordered.isEmpty {
            if pdfView.document != nil {
                let untitledTab = NSButton(title: "Untitled", target: nil, action: nil)
                untitledTab.setButtonType(.toggle)
                untitledTab.state = .on
                untitledTab.bezelStyle = .texturedRounded
                untitledTab.isEnabled = false
                documentTabsStack.addArrangedSubview(untitledTab)
            } else {
                let emptyLabel = NSTextField(labelWithString: "No PDF Open")
                emptyLabel.textColor = .secondaryLabelColor
                emptyLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                documentTabsStack.addArrangedSubview(emptyLabel)
            }
            return
        }

        for url in ordered {
            let tab = NSButton(title: url.lastPathComponent, target: self, action: #selector(selectDocumentTab(_:)))
            tab.setButtonType(.toggle)
            tab.state = (url == current) ? .on : .off
            tab.bezelStyle = .texturedRounded
            tab.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            tab.toolTip = url.path
            tab.identifier = NSUserInterfaceItemIdentifier(url.path)
            documentTabsStack.addArrangedSubview(tab)
        }
    }

    @objc private func selectDocumentTab(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        let targetURL = URL(fileURLWithPath: path)
        let normalizedTarget = canonicalDocumentURL(targetURL)
        if openDocumentURL.map({ canonicalDocumentURL($0) }) == normalizedTarget {
            return
        }
        guard confirmDiscardUnsavedChangesIfNeeded() else {
            refreshDocumentTabs()
            return
        }
        openDocument(at: normalizedTarget)
    }

    private func configureScalePresetPopup() {
        scalePresetPopup.removeAllItems()
        scalePresetPopup.addItems(withTitles: drawingScalePresets.map(\.label))
        scalePresetPopup.selectItem(at: 0)
        scalePresetPopup.controlSize = .small
        scalePresetPopup.bezelStyle = .texturedRounded
        scalePresetPopup.target = self
        scalePresetPopup.action = #selector(changeScalePreset)
        scalePresetPopup.translatesAutoresizingMaskIntoConstraints = false
        scalePresetPopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        scalePresetPopup.toolTip = "Drawing Scale"
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "DrawbridgeToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    private func configureToolSelectorAppearance() {
        toolSelector.trackingMode = .selectOne
        toolSelector.setLabel("V", forSegment: 0)
        toolSelector.setWidth(42, forSegment: 0)
        toolSelector.selectedSegmentBezelColor = NSColor.systemBlue.withAlphaComponent(0.9)
        toolSelector.wantsLayer = true
        toolSelector.isHidden = true
        refreshToolbarShortcutTooltips()
        refreshToolSegmentIcons()
    }

    private func configureTakeoffSelectorAppearance() {
        takeoffSelector.segmentCount = 0
        takeoffSelector.isHidden = true
        refreshToolbarShortcutTooltips()
        refreshTakeoffSegmentIcons()
    }

    func refreshToolbarShortcutTooltips() {
        let primaryTooltips: [(Int, String, ShortcutAction)] = [
            (0, "Select", .selectTool)
        ]
        for (segment, title, action) in primaryTooltips where segment < toolSelector.segmentCount {
            toolSelector.setToolTip("\(title) (\(shortcutDisplayString(for: action)))", forSegment: segment)
        }
        let primaryButtonActions: [(ToolMode, String, ShortcutAction)] = [
            (.select, "Select", .selectTool)
        ]
        for (mode, title, action) in primaryButtonActions {
            toolbarToolButtons[mode]?.toolTip = "\(title) (\(shortcutDisplayString(for: action)))"
        }

        gridToggleButton.toolTip = "Show/Hide Grid (\(shortcutDisplayString(for: .toggleGrid)))"
    }

    private func symbolImage(
        candidates: [String],
        description: String,
        color: NSColor
    ) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        for name in candidates {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: description) {
                return image.withSymbolConfiguration(config)
            }
        }
        return nil
    }

    private func refreshToolSegmentIcons() {
        let activeColor = NSColor.systemBlue
        let inactiveColor = NSColor.secondaryLabelColor
        for idx in 0..<min(toolSelector.segmentCount, ToolMode.primaryToolbarModes.count) {
            let mode = ToolMode.primaryToolbarModes[idx]
            let color = (toolSelector.selectedSegment == idx) ? activeColor : inactiveColor
            if let icon = symbolImage(candidates: mode.symbolCandidates, description: mode.symbolDescription, color: color) {
                toolSelector.setImage(icon, forSegment: idx)
            }
        }
        refreshToolbarToolButtons()
    }

    private func refreshTakeoffSegmentIcons() {
        let activeColor = NSColor.systemBlue
        let inactiveColor = NSColor.secondaryLabelColor
        for idx in 0..<min(takeoffSelector.segmentCount, ToolMode.takeoffToolbarModes.count) {
            let mode = ToolMode.takeoffToolbarModes[idx]
            let color = (takeoffSelector.selectedSegment == idx) ? activeColor : inactiveColor
            if let icon = symbolImage(candidates: mode.symbolCandidates, description: mode.symbolDescription, color: color) {
                takeoffSelector.setImage(icon, forSegment: idx)
            }
        }
        refreshToolbarToolButtons()
    }

    private func makeToolbarGroupLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = NSFont.systemFont(ofSize: 8, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeToolbarToolButton(mode: ToolMode) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(toolbarToolButtonPressed(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("toolbar.\(mode.toolbarIdentifier)")
        button.setButtonType(.toggle)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.imagePosition = .imageOnly
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    private func makeToolbarButtonGroup(title: String, modes: [ToolMode]) -> NSView {
        let label = makeToolbarGroupLabel(title)
        let buttonsRow = NSStackView()
        buttonsRow.orientation = .horizontal
        buttonsRow.spacing = 4
        buttonsRow.alignment = .centerY
        for mode in modes {
            let button = makeToolbarToolButton(mode: mode)
            toolbarToolButtons[mode] = button
            buttonsRow.addArrangedSubview(button)
        }

        let content = NSStackView(views: [label, buttonsRow])
        content.orientation = .vertical
        content.spacing = 2
        content.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = NSVisualEffectView(frame: .zero)
        container.material = .headerView
        container.blendingMode = .withinWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
        container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.02).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func makeToolbarQuickControl(key: String, label: NSTextField, control: NSView) -> NSView {
        label.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        toolbarQuickControlContainers[key] = stack
        return stack
    }

    private func refreshToolbarToolButtons() {
        let activeMode = pdfView.toolMode
        let activeColor = NSColor.white
        let inactiveColor = NSColor.secondaryLabelColor
        for (mode, button) in toolbarToolButtons {
            let isActive = mode == activeMode
            button.state = isActive ? .on : .off
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            button.layer?.backgroundColor = isActive
                ? NSColor.systemBlue.withAlphaComponent(0.88).cgColor
                : NSColor.clear.cgColor
            let iconColor = isActive ? activeColor : inactiveColor
            button.contentTintColor = iconColor
            if let icon = symbolImage(candidates: mode.symbolCandidates, description: mode.symbolDescription, color: iconColor) {
                button.image = icon
            }
        }
    }

    @objc private func toolbarToolButtonPressed(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        let targetMode = (ToolMode.primaryToolbarModes + ToolMode.takeoffToolbarModes)
            .first(where: { "toolbar.\($0.toolbarIdentifier)" == raw })
        guard let targetMode else { return }
        setTool(targetMode)
    }

    @objc private func toolbarQuickSettingsChanged() {
        guard !isSyncingToolbarQuickControls else { return }
        toolSettingsStrokeColorWell.color = toolbarQuickStrokeColorWell.color
        toolSettingsFillColorWell.color = toolbarQuickFillColorWell.color
        if let widthTitle = toolbarQuickLineWidthPopup.titleOfSelectedItem {
            toolSettingsLineWidthPopup.selectItem(withTitle: widthTitle)
        }
        if let fontSizeTitle = toolbarQuickFontSizePopup.titleOfSelectedItem {
            toolSettingsFontSizePopup.selectItem(withTitle: fontSizeTitle)
        }
        if let arrowTitle = toolbarQuickArrowPopup.titleOfSelectedItem {
            toolSettingsArrowPopup.selectItem(withTitle: arrowTitle)
        }
        toolSettingsOpacitySlider.doubleValue = toolbarQuickOpacitySlider.doubleValue
        toolSettingsOpacityValueLabel.stringValue = "\(Int(round(toolSettingsOpacitySlider.doubleValue * 100)))%"
        applyToolSettingsToPDFView()
        syncToolbarQuickControlsFromToolSettings()
    }

    func syncToolbarQuickControlsFromToolSettings() {
        isSyncingToolbarQuickControls = true
        toolbarQuickStrokeLabel.stringValue = toolSettingsStrokeTitleLabel.stringValue.replacingOccurrences(of: ":", with: "")
        toolbarQuickStrokeColorWell.color = toolSettingsStrokeColorWell.color
        toolbarQuickStrokeColorWell.isEnabled = toolSettingsStrokeColorWell.isEnabled

        toolbarQuickFillLabel.stringValue = toolSettingsFillTitleLabel.stringValue.replacingOccurrences(of: ":", with: "")
        toolbarQuickFillColorWell.color = toolSettingsFillColorWell.color
        toolbarQuickFillColorWell.isEnabled = toolSettingsFillColorWell.isEnabled

        toolbarQuickLineWidthPopup.selectItem(withTitle: toolSettingsLineWidthPopup.titleOfSelectedItem ?? "5")
        toolbarQuickLineWidthPopup.isEnabled = toolSettingsLineWidthPopup.isEnabled

        toolbarQuickFontSizeLabel.stringValue = toolSettingsFontTitleLabel.stringValue.replacingOccurrences(of: ":", with: "")
        toolbarQuickFontSizePopup.selectItem(withTitle: toolSettingsFontSizePopup.titleOfSelectedItem ?? "15 pt")
        toolbarQuickFontSizePopup.isEnabled = toolSettingsFontSizePopup.isEnabled

        toolbarQuickArrowLabel.stringValue = toolSettingsArrowTitleLabel.stringValue.replacingOccurrences(of: ":", with: "")
        toolbarQuickArrowPopup.selectItem(withTitle: toolSettingsArrowPopup.titleOfSelectedItem ?? MarkupPDFView.ArrowEndStyle.solidArrow.displayName)
        toolbarQuickArrowPopup.isEnabled = toolSettingsArrowPopup.isEnabled

        toolbarQuickOpacitySlider.doubleValue = toolSettingsOpacitySlider.doubleValue
        toolbarQuickOpacitySlider.isEnabled = toolSettingsOpacitySlider.isEnabled
        toolbarQuickOpacityValueLabel.stringValue = toolSettingsOpacityValueLabel.stringValue

        toolbarQuickControlContainers["fill"]?.isHidden = toolSettingsFillRow.isHidden
        toolbarQuickControlContainers["width"]?.isHidden = toolSettingsWidthRow.isHidden
        toolbarQuickControlContainers["font"]?.isHidden = toolSettingsFontRow.isHidden
        toolbarQuickControlContainers["arrow"]?.isHidden = toolSettingsArrowRow.isHidden
        toolbarQuickControlContainers["opacity"]?.isHidden = false

        // Tool settings should live in the right sidebar only.
        toolbarQuickControlsStack.isHidden = true
        isSyncingToolbarQuickControls = false
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.drawbridgePrimaryControls, .drawbridgeSecondaryControls, .flexibleSpace, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.drawbridgePrimaryControls, .flexibleSpace, .drawbridgeSecondaryControls]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        if itemIdentifier == .drawbridgePrimaryControls {
            item.label = "Tools"
            item.view = toolbarControlsStack
            return item
        }
        if itemIdentifier == .drawbridgeSecondaryControls {
            item.label = "Takeoff"
            item.view = secondaryToolbarControlsStack
            return item
        }
        return nil
    }


    private func buildMarkupsSidebar() -> NSView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = markupsTable
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        markupsTable.translatesAutoresizingMaskIntoConstraints = false
        markupsTable.widthAnchor.constraint(equalTo: scrollView.widthAnchor).isActive = true

        let toolStrokeRow = NSStackView(views: [toolSettingsStrokeTitleLabel, toolSettingsStrokeColorWell])
        toolStrokeRow.orientation = .horizontal
        toolStrokeRow.spacing = 8
        toolStrokeRow.alignment = .centerY

        toolSettingsFillRow.orientation = .horizontal
        toolSettingsFillRow.spacing = 8
        toolSettingsFillRow.alignment = .centerY
        toolSettingsFillRow.addArrangedSubview(toolSettingsFillTitleLabel)
        toolSettingsFillRow.addArrangedSubview(toolSettingsFillColorWell)

        toolSettingsOutlineRow.orientation = .horizontal
        toolSettingsOutlineRow.spacing = 8
        toolSettingsOutlineRow.alignment = .centerY
        toolSettingsOutlineRow.addArrangedSubview(toolSettingsOutlineTitleLabel)
        toolSettingsOutlineRow.addArrangedSubview(toolSettingsOutlineColorWell)
        toolSettingsOutlineRow.addArrangedSubview(toolSettingsOutlineWidthPopup)

        toolSettingsFontRow.orientation = .horizontal
        toolSettingsFontRow.spacing = 8
        toolSettingsFontRow.alignment = .centerY
        toolSettingsFontRow.addArrangedSubview(toolSettingsFontTitleLabel)
        toolSettingsFontRow.addArrangedSubview(toolSettingsFontSizePopup)

        toolSettingsArrowRow.orientation = .horizontal
        toolSettingsArrowRow.spacing = 8
        toolSettingsArrowRow.alignment = .centerY
        toolSettingsArrowRow.addArrangedSubview(toolSettingsArrowTitleLabel)
        toolSettingsArrowRow.addArrangedSubview(toolSettingsArrowPopup)

        toolSettingsArrowSizeRow.orientation = .horizontal
        toolSettingsArrowSizeRow.spacing = 8
        toolSettingsArrowSizeRow.alignment = .centerY
        toolSettingsArrowSizeRow.addArrangedSubview(toolSettingsArrowSizeTitleLabel)
        toolSettingsArrowSizeRow.addArrangedSubview(toolSettingsArrowSizePopup)

        toolSettingsHatchRow.orientation = .horizontal
        toolSettingsHatchRow.spacing = 8
        toolSettingsHatchRow.alignment = .centerY
        toolSettingsHatchRow.addArrangedSubview(toolSettingsHatchTitleLabel)
        toolSettingsHatchRow.addArrangedSubview(toolSettingsHatchPopup)

        toolSettingsHatchBackgroundRow.orientation = .horizontal
        toolSettingsHatchBackgroundRow.spacing = 8
        toolSettingsHatchBackgroundRow.alignment = .centerY
        toolSettingsHatchBackgroundRow.addArrangedSubview(toolSettingsHatchBackgroundTitleLabel)
        toolSettingsHatchBackgroundRow.addArrangedSubview(toolSettingsHatchBackgroundColorWell)

        toolSettingsWidthRow.orientation = .horizontal
        toolSettingsWidthRow.spacing = 8
        toolSettingsWidthRow.alignment = .centerY
        toolSettingsWidthRow.addArrangedSubview(NSTextField(labelWithString: "Line Weight:"))
        toolSettingsWidthRow.addArrangedSubview(toolSettingsLineWidthPopup)

        let toolOpacityRow = NSStackView(views: [NSTextField(labelWithString: "Opacity:"), toolSettingsOpacitySlider, toolSettingsOpacityValueLabel])
        toolOpacityRow.orientation = .horizontal
        toolOpacityRow.spacing = 12
        toolOpacityRow.alignment = .centerY
        toolSettingsOpacitySlider.translatesAutoresizingMaskIntoConstraints = false
        toolSettingsOpacityValueLabel.translatesAutoresizingMaskIntoConstraints = false
        toolSettingsOpacitySlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        toolSettingsOpacityValueLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true

        toolSettingsSectionContent.orientation = .vertical
        toolSettingsSectionContent.spacing = 8
        toolSettingsSectionContent.addArrangedSubview(toolSettingsToolLabel)
        toolSettingsSectionContent.addArrangedSubview(toolStrokeRow)
        toolSettingsSectionContent.addArrangedSubview(toolSettingsFillRow)
        toolSettingsSectionContent.addArrangedSubview(toolSettingsOutlineRow)
        toolSettingsSectionContent.addArrangedSubview(toolSettingsFontRow)
        toolSettingsSectionContent.addArrangedSubview(toolSettingsArrowRow)
        toolSettingsSectionContent.addArrangedSubview(toolSettingsArrowSizeRow)
        toolSettingsSectionContent.addArrangedSubview(toolSettingsHatchRow)
        toolSettingsSectionContent.addArrangedSubview(toolSettingsHatchBackgroundRow)
        toolSettingsSectionContent.addArrangedSubview(toolSettingsWidthRow)
        toolSettingsSectionContent.addArrangedSubview(toolOpacityRow)
        toolSettingsSectionContent.addArrangedSubview(snapshotColorizeButton)

        markupsSectionContent.orientation = .vertical
        markupsSectionContent.spacing = 6
        markupsSectionContent.addArrangedSubview(markupFilterField)
        markupsSectionContent.addArrangedSubview(markupsCountLabel)
        markupsSectionContent.addArrangedSubview(scrollView)

        summarySectionContent.orientation = .vertical
        summarySectionContent.spacing = 4
        summarySectionContent.addArrangedSubview(measurementCountLabel)
        summarySectionContent.addArrangedSubview(measurementTotalLabel)

        toolSettingsSidebarToggleButton.image = NSImage(systemSymbolName: isSidebarCollapsed ? "sidebar.left" : "sidebar.right", accessibilityDescription: "Hide Tool Settings")
        toolSettingsSidebarToggleButton.imagePosition = .imageOnly
        toolSettingsSidebarToggleButton.bezelStyle = .texturedRounded
        toolSettingsSidebarToggleButton.controlSize = .small
        toolSettingsSidebarToggleButton.target = self
        toolSettingsSidebarToggleButton.action = #selector(toggleSidebar)
        toolSettingsSidebarToggleButton.toolTip = isSidebarCollapsed ? "Show Tool Settings Sidebar" : "Hide Tool Settings Sidebar"

        let toolSettingsHeaderRow = NSStackView(views: [toolSettingsSectionButton, NSView(), toolSettingsSidebarToggleButton])
        toolSettingsHeaderRow.orientation = .horizontal
        toolSettingsHeaderRow.spacing = 6
        toolSettingsHeaderRow.alignment = .centerY

        let sidebarSpacer = NSView(frame: .zero)
        sidebarSpacer.translatesAutoresizingMaskIntoConstraints = false
        sidebarSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        sidebarSpacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let sidebar = NSStackView(views: [
            toolSettingsHeaderRow,
            toolSettingsSectionContent,
            markupsSectionButton,
            markupsSectionContent,
            summarySectionButton,
            summarySectionContent,
            sidebarSpacer,
            snapSectionButton,
            snapSectionContent,
            layersSectionButton,
            layersSectionContent
        ])
        sidebar.orientation = .vertical
        sidebar.spacing = 8
        sidebar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: .zero)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sidebar)

        let preferredWidth = container.widthAnchor.constraint(equalToConstant: 240)
        sidebarPreferredWidthConstraint = preferredWidth
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: container.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            preferredWidth
        ])
        updateSectionHeaders()
        return container
    }

    @objc private func changeTool() {
        let requestedMode = ToolMode.fromPrimaryToolbarSegment(toolSelector.selectedSegment) ?? .select
        activateTool(requestedMode)
    }

    @objc private func changeTakeoffTool() {
        return
    }

    private func activateTool(_ requestedMode: ToolMode) {
        let requestedMode = requestedMode.isEnabledInScratchReset ? requestedMode : .select
        persistToolSettingsFromControls(for: pdfView.toolMode)

        cancelPendingMarkupInteractions(except: requestedMode)

        pdfView.toolMode = requestedMode
        if requestedMode != .select {
            setPolygonVertexEditMode(false)
        }
        applyStoredToolSettings(to: requestedMode)
        refreshToolSegmentIcons()
        refreshTakeoffSegmentIcons()
        if toolSelector.selectedSegment >= 0 || takeoffSelector.selectedSegment >= 0 {
            animateToolSelectionFeedback()
        }
        updateToolSettingsUIForCurrentTool()
        applyToolSettingsToPDFView()
        updateStatusBar()
    }

    @objc func selectSelectionTool(_ sender: Any?) {
        setTool(.select)
    }

    @objc func selectPenTool(_ sender: Any?) { setTool(.pen) }
    @objc func selectHighlighterTool(_ sender: Any?) { setTool(.highlighter) }
    @objc func selectTextTool(_ sender: Any?) { setTool(.text) }
    @objc func selectNoteTool(_ sender: Any?) { setTool(.note) }
    @objc func selectLineTool(_ sender: Any?) { setTool(.line) }
    @objc func selectArrowTool(_ sender: Any?) { setTool(.arrow) }
    @objc func selectRectangleTool(_ sender: Any?) { setTool(.rectangle) }
    @objc func selectEllipseTool(_ sender: Any?) { setTool(.circle) }

    func setTool(_ mode: ToolMode) {
        let mode = mode.isEnabledInScratchReset ? mode : .select
        if let primary = mode.primaryToolbarSegmentIndex {
            toolSelector.selectedSegment = primary
            takeoffSelector.selectedSegment = -1
        } else if let takeoff = mode.takeoffToolbarSegmentIndex {
            toolSelector.selectedSegment = -1
            takeoffSelector.selectedSegment = takeoff
        } else {
            toolSelector.selectedSegment = -1
            takeoffSelector.selectedSegment = -1
        }
        activateTool(mode)
    }

    private func animateToolSelectionFeedback() {
        guard let layer = toolSelector.layer else { return }
        let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
        bounce.values = [1.0, 1.05, 0.98, 1.0]
        bounce.keyTimes = [0.0, 0.35, 0.7, 1.0]
        bounce.duration = 0.18
        bounce.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(bounce, forKey: "drawbridge.tool.bounce")
    }

    private func focusAndHighlightScalePresetControl() {
        guard let window = view.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(scalePresetPopup)
        scalePresetPopup.wantsLayer = true
        guard let layer = scalePresetPopup.layer else { return }
        let accent = NSColor.systemBlue
        layer.cornerRadius = 6
        layer.borderColor = accent.cgColor
        layer.borderWidth = 2
        layer.shadowColor = accent.cgColor
        layer.shadowOpacity = 0.9
        layer.shadowRadius = 10
        layer.shadowOffset = .zero

        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [1.0, 1.08, 1.0, 1.08, 1.0]
        pulse.keyTimes = [0.0, 0.2, 0.45, 0.7, 1.0]
        pulse.duration = 1.0
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "drawbridge.scalePreset.spotlight")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.scalePresetPopup.layer?.borderWidth = 0
            self.scalePresetPopup.layer?.shadowOpacity = 0
            self.scalePresetPopup.layer?.shadowRadius = 0
        }
    }

    @objc func toggleSidebar() {
        guard let sidebar = sidebarContainerView else { return }
        if isSidebarCollapsed {
            sidebar.isHidden = false
            sidebarPreferredWidthConstraint?.constant = min(max(lastSidebarExpandedWidth, 220), 280)
            splitView.setPosition(max(900, view.bounds.width - lastSidebarExpandedWidth), ofDividerAt: 0)
            isSidebarCollapsed = false
            UserDefaults.standard.set(false, forKey: "DrawbridgeSidebarCollapsed")
        } else {
            let width = max(220, sidebar.frame.width)
            lastSidebarExpandedWidth = min(width, 280)
            sidebarPreferredWidthConstraint?.constant = min(max(lastSidebarExpandedWidth, 220), 280)
            UserDefaults.standard.set(Double(lastSidebarExpandedWidth), forKey: "DrawbridgeSidebarWidth")
            splitView.setPosition(view.bounds.width - 1, ofDividerAt: 0)
            sidebar.isHidden = true
            isSidebarCollapsed = true
            UserDefaults.standard.set(true, forKey: "DrawbridgeSidebarCollapsed")
        }
        toolSettingsSidebarToggleButton.image = NSImage(systemSymbolName: isSidebarCollapsed ? "sidebar.left" : "sidebar.right", accessibilityDescription: "Toggle Sidebar")
        toolSettingsSidebarToggleButton.toolTip = isSidebarCollapsed ? "Show Tool Settings Sidebar" : "Hide Tool Settings Sidebar"
        if let image = NSImage(systemSymbolName: isSidebarCollapsed ? "sidebar.left" : "sidebar.right", accessibilityDescription: "Toggle Sidebar")
            ?? NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: "Toggle Sidebar")
            ?? NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Toggle Sidebar") {
            collapsedSidebarRevealButton.image = image
            collapsedSidebarRevealButton.title = ""
            collapsedSidebarRevealButton.imagePosition = .imageOnly
        } else {
            collapsedSidebarRevealButton.image = nil
            collapsedSidebarRevealButton.title = isSidebarCollapsed ? ">" : "<"
            collapsedSidebarRevealButton.imagePosition = .noImage
        }
        collapsedSidebarRevealButton.isHidden = !isSidebarCollapsed
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let sidebar = sidebarContainerView, !isSidebarCollapsed, sidebar.frame.width > 120 else { return }
        lastSidebarExpandedWidth = min(max(sidebar.frame.width, 220), 280)
        UserDefaults.standard.set(Double(lastSidebarExpandedWidth), forKey: "DrawbridgeSidebarWidth")
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard splitView === self.splitView, dividerIndex == 0 else {
            return proposedPosition
        }
        let minCanvasWidth: CGFloat = 900
        let minSidebarWidth: CGFloat = isSidebarCollapsed ? 0 : 220
        let dividerThickness = splitView.dividerThickness
        let maxCanvasWidth = splitView.bounds.width - dividerThickness - minSidebarWidth
        if maxCanvasWidth <= minCanvasWidth {
            return max(0, maxCanvasWidth)
        }
        return min(max(proposedPosition, minCanvasWidth), maxCanvasWidth)
    }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        guard splitView === self.splitView, dividerIndex == 0 else {
            return proposedEffectiveRect
        }
        // Disable mouse hit-testing on the right Tool Settings divider.
        // We only allow resizing via the left Navigation grabber.
        return .zero
    }

    @objc func openPDF() {
        guard confirmDiscardUnsavedChangesIfNeeded() else {
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        openDocument(at: url)
    }

    @objc func createNewPDFAction() {
        guard confirmDiscardUnsavedChangesIfNeeded() else {
            return
        }
        presentCreateNewDocumentSheet()
    }

    private func presentCreateNewDocumentSheet() {
        if let panel = newDocumentPanel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Create New PDF"
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: panel.contentView?.bounds ?? .zero)
        container.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = container

        let titleLabel = NSTextField(labelWithString: "Choose a paper size and orientation.")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor

        let sizeLabel = NSTextField(labelWithString: "Paper Size")
        let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sizePopup.addItems(withTitles: newDocumentSizes.map(\.name))
        sizePopup.selectItem(at: 0)
        sizePopup.translatesAutoresizingMaskIntoConstraints = false
        sizePopup.widthAnchor.constraint(equalToConstant: 360).isActive = true

        let orientationLabel = NSTextField(labelWithString: "Orientation")
        let orientationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        orientationPopup.addItems(withTitles: ["Landscape", "Portrait"])
        orientationPopup.selectItem(withTitle: "Landscape")
        orientationPopup.translatesAutoresizingMaskIntoConstraints = false
        orientationPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let createButton = NSButton(title: "Create", target: self, action: #selector(confirmCreateNewDocument))
        createButton.keyEquivalent = "\r"
        createButton.bezelStyle = .rounded
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelCreateNewDocument))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded

        let sizeRow = NSStackView(views: [sizeLabel, sizePopup])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 12
        sizeRow.alignment = .centerY

        let orientationRow = NSStackView(views: [orientationLabel, orientationPopup])
        orientationRow.orientation = .horizontal
        orientationRow.spacing = 12
        orientationRow.alignment = .centerY

        let buttonsRow = NSStackView(views: [cancelButton, createButton])
        buttonsRow.orientation = .horizontal
        buttonsRow.spacing = 8
        buttonsRow.alignment = .centerY
        buttonsRow.distribution = .gravityAreas

        let stack = NSStackView(views: [titleLabel, sizeRow, orientationRow, buttonsRow])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        newDocumentPanel = panel
        newDocumentSizePopup = sizePopup
        newDocumentOrientationPopup = orientationPopup
        newDocumentPanelCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closeCreateNewDocumentPanel()
            }
        }
        if let closeButton = panel.standardWindowButton(.closeButton) {
            closeButton.target = self
            closeButton.action = #selector(cancelCreateNewDocument)
        }
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: panel)
    }

    @objc private func confirmCreateNewDocument() {
        let selectedIndex = max(0, newDocumentSizePopup?.indexOfSelectedItem ?? 0)
        let selected = newDocumentSizes[min(selectedIndex, newDocumentSizes.count - 1)]
        let isLandscape = (newDocumentOrientationPopup?.titleOfSelectedItem == "Landscape")
        createBlankDocument(sizeInches: selected, landscape: isLandscape)
        closeCreateNewDocumentPanel()
    }

    @objc private func cancelCreateNewDocument() {
        closeCreateNewDocumentPanel()
    }

    private func closeCreateNewDocumentPanel() {
        guard let panel = newDocumentPanel else { return }
        if NSApp.modalWindow === panel {
            NSApp.stopModal()
        }
        if panel.isVisible {
            panel.orderOut(nil)
        }
        if let observer = newDocumentPanelCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            newDocumentPanelCloseObserver = nil
        }
        newDocumentPanel = nil
        newDocumentSizePopup = nil
        newDocumentOrientationPopup = nil
    }

    func pasteGrabSnapshotInPlace() {
        guard ensureWorkingCopyBeforeFirstMarkup() else { return }
        guard let pdfData = grabClipboardPDFData,
              let sourceRect = grabClipboardPageRect,
              let page = pdfView.currentPage else {
            beep()
            return
        }
        let selectedLayer = resolvedGrabSnapshotLayer()
        guard let snapshotURL = resolvedGrabSnapshotURL(for: pdfData) else { beep(); return }

        let destinationRect = adjustedGrabPasteRect(sourceRect, on: page)
        let annotation = PDFSnapshotAnnotation(bounds: destinationRect, snapshotURL: snapshotURL)
        annotation.renderOpacity = 1.0
        annotation.tintBlendStyle = grabClipboardTintBlendStyle
        annotation.snapshotLayerName = selectedLayer
        grabSnapshotPreferredLayer = selectedLayer
        applyLayerRenderingStyle(to: annotation, layer: selectedLayer)
        page.addAnnotation(annotation)
        registerAnnotationPresenceUndo(page: page, annotation: annotation, shouldExist: false, actionName: "Paste Grab Snapshot")
        markPageMarkupCacheDirty(page)
        markMarkupChanged()
        applySnapshotLayerVisibility()
        setTool(.select)
        lastDirectlySelectedAnnotation = annotation
        markupsTable.deselectAll(nil)
        performRefreshMarkups(selecting: annotation)
        updateSelectionOverlay()
        updateToolSettingsUIForCurrentTool()
        updateStatusBar()
        scheduleAutosave()
    }

    private func adjustedGrabPasteRect(_ sourceRect: NSRect, on page: PDFPage) -> NSRect {
        let pageBounds = page.bounds(for: .mediaBox).insetBy(dx: 2, dy: 2)
        guard pageBounds.width > 4, pageBounds.height > 4 else { return sourceRect }

        var rect = sourceRect.standardized
        rect.size.width = max(1, rect.width)
        rect.size.height = max(1, rect.height)

        if rect.width > pageBounds.width || rect.height > pageBounds.height {
            let scale = min(pageBounds.width / rect.width, pageBounds.height / rect.height)
            rect.size.width *= scale
            rect.size.height *= scale
        }

        let maxX = pageBounds.maxX - rect.width
        let maxY = pageBounds.maxY - rect.height
        rect.origin.x = min(max(rect.origin.x, pageBounds.minX), maxX)
        rect.origin.y = min(max(rect.origin.y, pageBounds.minY), maxY)
        return rect
    }

    private func resolvedGrabSnapshotLayer() -> String {
        let selectedSnapshots = currentSelectedMarkupItems().compactMap { $0.annotation as? PDFSnapshotAnnotation }
        if let firstLayer = selectedSnapshots
            .lazy
            .compactMap({ $0.snapshotLayerName?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return firstLayer
        }
        return grabSnapshotPreferredLayer
    }

    private func resolvedGrabSnapshotURL(for data: Data) -> URL? {
        if let cached = grabClipboardSnapshotURL,
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        guard let persisted = persistGrabSnapshotPDFData(data, captureID: grabClipboardCaptureID) else {
            return nil
        }
        grabClipboardSnapshotURL = persisted
        return persisted
    }

    private func warmGrabSnapshotPersistence(_ data: Data, captureID: UUID) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let url = MainViewController.persistGrabSnapshotPDFDataToDisk(data, captureID: captureID) else {
                return
            }
            DispatchQueue.main.async {
                guard let self, self.grabClipboardCaptureID == captureID else { return }
                self.grabClipboardSnapshotURL = url
            }
        }
    }

    private func persistGrabSnapshotPDFData(_ data: Data, captureID: UUID) -> URL? {
        MainViewController.persistGrabSnapshotPDFDataToDisk(data, captureID: captureID)
    }

    nonisolated private static func persistGrabSnapshotPDFDataToDisk(_ data: Data, captureID: UUID) -> URL? {
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let directory = root?
                .appendingPathComponent("Drawbridge", isDirectory: true)
                .appendingPathComponent("GrabSnapshots", isDirectory: true)
            guard let directory else { return nil }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("grab-\(captureID.uuidString).pdf")
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            }
            return url
        } catch {
            return nil
        }
    }

    func preferredSnapshotTintBlendStyle(for pdfData: Data) -> PDFSnapshotAnnotation.TintBlendStyle {
        guard let provider = CGDataProvider(data: pdfData as CFData),
              let doc = CGPDFDocument(provider),
              let page = doc.page(at: 1) else {
            return .screen
        }
        let sample = 48
        guard let ctx = CGContext(
            data: nil,
            width: sample,
            height: sample,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return .screen
        }
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: sample, height: sample))
        let mediaBox = page.getBoxRect(.mediaBox)
        guard mediaBox.width > 0.1, mediaBox.height > 0.1 else {
            return .screen
        }
        ctx.saveGState()
        ctx.scaleBy(x: CGFloat(sample) / mediaBox.width, y: CGFloat(sample) / mediaBox.height)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
        guard let image = ctx.makeImage(),
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return .screen
        }
        let bytesPerRow = max(1, image.bytesPerRow)
        func intensity(x: Int, y: Int) -> Double {
            let clampedX = min(max(x, 0), sample - 1)
            let clampedY = min(max(y, 0), sample - 1)
            let idx = clampedY * bytesPerRow + clampedX
            return Double(bytes[idx]) / 255.0
        }

        let margin = max(2, sample / 8)
        let cornerValues: [Double] = [
            intensity(x: margin, y: margin),
            intensity(x: sample - 1 - margin, y: margin),
            intensity(x: margin, y: sample - 1 - margin),
            intensity(x: sample - 1 - margin, y: sample - 1 - margin)
        ]
        let cornerAverage = cornerValues.reduce(0, +) / Double(cornerValues.count)
        return cornerAverage < 0.45 ? .multiply : .screen
    }

    private func createBlankDocument(sizeInches: (name: String, widthInches: CGFloat, heightInches: CGFloat), landscape: Bool) {
        let width = landscape ? sizeInches.heightInches : sizeInches.widthInches
        let height = landscape ? sizeInches.widthInches : sizeInches.heightInches
        let pageSize = NSSize(width: width * 72.0, height: height * 72.0)

        let image = NSImage(size: pageSize)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: pageSize)).fill()
        image.unlockFocus()

        guard let page = PDFPage(image: image) else {
            beep()
            return
        }

        let document = PDFDocument()
        document.insert(page, at: 0)
        pdfView.document = document
        clearMarkupCache()
        pageScaleLocks.removeAll(keepingCapacity: false)
        lastScaleLockAppliedPageIndex = -1
        lastExplicitScaleSetDocumentID = nil
        lastExplicitScaleSetPageIndex = -1
        explicitScaleSetDocumentID = nil
        explicitScaleSetPageIndexes.removeAll(keepingCapacity: false)
        pendingScaleReminderSuppressionDocumentID = nil
        pendingScaleReminderSuppressionPageIndex = -1
        pendingScaleReminderSuppressionOneShot = false
        openDocumentURL = nil
        hasPromptedForInitialMarkupSaveCopy = true
        isPresentingInitialMarkupSaveCopyPrompt = false
        configureAutosaveURL(for: nil)
        view.window?.title = "Drawbridge - Untitled"
        view.window?.makeFirstResponder(pdfView)
        markDocumentClean(updateStatusBarValue: false)
        refreshMarkups()
        updateEmptyStateVisibility()
        refreshRulers()
        refreshDocumentTabs()
    }

    @objc func highlightSelection() {
        guard ensureWorkingCopyBeforeFirstMarkup() else { return }
        pdfView.addHighlightForCurrentSelection()
        refreshMarkups()
        scheduleAutosave()
    }

    @objc func underlineSelection() {
        guard ensureWorkingCopyBeforeFirstMarkup() else { return }
        pdfView.addUnderlineForCurrentSelection()
        refreshMarkups()
        scheduleAutosave()
    }

    @objc func strikethroughSelection() {
        guard ensureWorkingCopyBeforeFirstMarkup() else { return }
        pdfView.addStrikethroughForCurrentSelection()
        refreshMarkups()
        scheduleAutosave()
    }

    @objc func saveCopy() {
        saveDocumentAsCopy()
    }

    @objc func saveDocument() {
        guard let document = pdfView.document else { beep(); return }
        if let url = openDocumentURL {
            // Bluebeam-style Save: persist changes into the PDF itself.
            persistDocument(
                to: url,
                adoptAsPrimaryDocument: false,
                busyMessage: "Saving PDF…",
                document: document,
                showBusyOverlay: false,
                deferEmbeddedWrite: false
            )
        } else {
            saveDocumentAsProject(document: document)
        }
    }

    private func saveDocumentAsCopy() {
        saveDocumentAs(adoptAsPrimaryDocument: true)
    }

    func saveDocumentAsProject(document: PDFDocument) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Drawbridge Project.pdf"
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        // Save As must always produce a real PDF at the selected destination.
        persistDocument(to: selectedURL, adoptAsPrimaryDocument: true, busyMessage: "Saving PDF…", document: document)
    }

    private func saveDocumentAs(adoptAsPrimaryDocument: Bool, suggestedFilename: String? = nil) {
        guard let document = pdfView.document else { beep(); return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedFilename ?? openDocumentURL?.lastPathComponent ?? "Marked-Up.pdf"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        persistDocument(to: url, adoptAsPrimaryDocument: adoptAsPrimaryDocument, busyMessage: "Saving PDF…", document: document)
    }

    func saveStagingFileURL(for destinationURL: URL) -> URL {
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        let destinationFilename = destinationURL.deletingPathExtension().lastPathComponent
        let stagingFilename = ".\(destinationFilename)-drawbridge-staging-\(UUID().uuidString).pdf"
        let preferredURL = destinationDirectory.appendingPathComponent(stagingFilename)

        // Prefer staging in the destination directory to keep commit on the same volume.
        if FileManager.default.isWritableFile(atPath: destinationDirectory.path) {
            return preferredURL
        }

        let fallbackDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgeSaveStaging", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
        return fallbackDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
    }

    private func decodeAnnotation(from data: Data) -> PDFAnnotation? {
        if let secure = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PDFAnnotation.self, from: data) {
            return secure
        }
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return nil
        }
        unarchiver.requiresSecureCoding = false
        let insecure = unarchiver.decodeObject(of: PDFAnnotation.self, forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()
        return insecure
    }

    private func decodeMarkupClipboardPayloadFromPasteboard() -> MarkupClipboardPayload? {
        let board = NSPasteboard.general
        let changeCount = board.changeCount
        if changeCount == cachedMarkupPasteboardChangeCount {
            return cachedMarkupPasteboardPayload
        }
        cachedMarkupPasteboardChangeCount = changeCount
        guard let raw = board.data(forType: markupClipboardPasteboardType),
              let payload = try? PropertyListDecoder().decode(MarkupClipboardPayload.self, from: raw),
              !payload.records.isEmpty else {
            cachedMarkupPasteboardPayload = nil
            return nil
        }
        cachedMarkupPasteboardPayload = payload
        return payload
    }

    func pasteCopiedMarkupsFromPasteboard() {
        guard let document = pdfView.document else { beep(); return }
        guard ensureWorkingCopyBeforeFirstMarkup() else { return }
        guard let payload = decodeMarkupClipboardPayloadFromPasteboard() else {
            beep()
            return
        }

        let destinationPageIndex: Int
        if let currentPage = pdfView.currentPage {
            destinationPageIndex = max(0, document.index(for: currentPage))
        } else {
            destinationPageIndex = min(max(0, payload.records.first?.pageIndex ?? 0), max(0, document.pageCount - 1))
        }
        guard destinationPageIndex >= 0,
              destinationPageIndex < document.pageCount,
              let destinationPage = document.page(at: destinationPageIndex) else {
            beep()
            return
        }

        let sourcePageIndex = payload.records.first?.pageIndex ?? destinationPageIndex
        let shouldOffset = (sourcePageIndex == destinationPageIndex)
        let deltaX: CGFloat = shouldOffset ? 12 : 0
        let deltaY: CGFloat = shouldOffset ? -12 : 0

        var pasted: [PDFAnnotation] = []
        pasted.reserveCapacity(payload.records.count)
        for record in payload.records {
            guard let annotation = decodeAnnotation(from: record.archivedAnnotation) else { continue }
            var bounds = annotation.bounds
            bounds.origin.x += deltaX
            bounds.origin.y += deltaY
            annotation.bounds = bounds
            if let lineWidth = record.lineWidth, lineWidth > 0 {
                assignLineWidth(lineWidth, to: annotation)
            }
            destinationPage.addAnnotation(annotation)
            pdfView.rebindRectangleHatchIdentityAndSync(for: annotation, preferredLineWidth: record.lineWidth)
            registerAnnotationPresenceUndo(page: destinationPage, annotation: annotation, shouldExist: false, actionName: "Paste Markup")
            pasted.append(annotation)
        }

        guard guardOrBeep(!pasted.isEmpty) else { return }
        markPageMarkupCacheDirty(destinationPage)
        pdfView.restorePolygonHatchOverlays(on: destinationPage, for: pasted)
        commitMarkupMutation(selecting: pasted.first, forceImmediateRefresh: true)
        selectMarkupsFromFence(page: destinationPage, annotations: pasted, enablesGroupedDrag: true, refreshBeforeSelecting: false)
    }

    func startSaveProgressTracking(phase: String) {
        saveOperationStartedAt = CFAbsoluteTimeGetCurrent()
        savePhase = phase
        saveGenerateElapsed = 0
        saveProgressTimer?.invalidate()
        saveProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let started = self.saveOperationStartedAt,
                      let phase = self.savePhase else { return }
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                if phase == "Committing" {
                    self.updateBusyIndicatorDetail(
                        String(format: "Generated %.2fs • Committing… %.1fs elapsed", self.saveGenerateElapsed, elapsed)
                    )
                } else {
                    self.updateBusyIndicatorDetail(String(format: "%@… %.1fs elapsed", phase, elapsed))
                }
            }
        }
    }

    func updateSaveProgressPhase(_ phase: String) {
        savePhase = phase
    }

    func stopSaveProgressTracking() {
        saveProgressTimer?.invalidate()
        saveProgressTimer = nil
        saveOperationStartedAt = nil
        savePhase = nil
        saveGenerateElapsed = 0
    }

    @objc func refreshMarkups() {
        pendingMarkupsRefreshWorkItem?.cancel()
        performRefreshMarkups(selecting: currentSelectedAnnotation(), forceImmediate: true)
    }

    func performRefreshMarkups(selecting selectedAnnotation: PDFAnnotation?, forceImmediate: Bool = false) {
        let refreshSpan = PerformanceMetrics.begin(
            "refresh_markups",
            thresholdMs: 120,
            fields: [
                "force_immediate": forceImmediate ? "1" : "0",
                "filter_len": "\(markupFilterText.count)"
            ]
        )
        if isSavingDocumentOperation && !forceImmediate {
            return
        }
        guard let document = pdfView.document else {
            clearMarkupCache()
            lastKnownTotalMatchingMarkups = 0
            isMarkupListTruncated = false
            markupItems = []
            markupsTable.reloadData()
            markupsCountLabel.stringValue = "0 items"
            updateMeasurementSummary()
            restoreSelection(for: nil)
            updateSelectionOverlay()
            requestChromeRefresh()
            PerformanceMetrics.end(refreshSpan, extra: ["result": "no_document", "items": "0"])
            return
        }

        ensureMarkupCacheDocumentIdentity(for: document)
        if pageMarkupCache.isEmpty {
            dirtyMarkupPageIndexes = Set(0..<document.pageCount)
        } else {
            for pageIndex in 0..<document.pageCount where pageMarkupCache[pageIndex] == nil {
                dirtyMarkupPageIndexes.insert(pageIndex)
            }
        }

        let generation = markupsScanGeneration + 1
        markupsScanGeneration = generation
        let filter = markupFilterText
        let pagesToRebuild = dirtyMarkupPageIndexes.sorted()
        if !pagesToRebuild.isEmpty {
            cancelSearchIndexWarmup()
        }
        let chunkSize = forceImmediate ? max(32, pagesToRebuild.count) : (pagesToRebuild.count >= 120 ? 8 : 16)
        let rebuildPageCount = pagesToRebuild.count
        let isColdStartIndexBuild = totalCachedAnnotationCount() == 0
        let shouldPublishProvisional = !forceImmediate && isColdStartIndexBuild && filter.isEmpty && rebuildPageCount >= 40
        let provisionalPageTarget = shouldPublishProvisional ? min(rebuildPageCount, max(chunkSize, 12)) : 0
        var didPublishProvisional = false

        if !forceImmediate && !pagesToRebuild.isEmpty {
            markupsCountLabel.stringValue = "Updating…"
        }

        func publishResults(final: Bool, rebuiltChunkCount: Int = 0) {
            guard generation == self.markupsScanGeneration else { return }
            let indexCap = self.effectiveIndexCap(for: document)
            let collectionCap = final ? indexCap : min(indexCap, 1_500)
            var collected: [MarkupItem] = []
            let totalCached = self.totalCachedAnnotationCount()
            collected.reserveCapacity(min(totalCached, collectionCap))
            var totalMatching = 0
            let allowEarlyBreak = !final && filter.isEmpty
            @inline(__always)
            func forEachTargetPage(_ body: (Int) -> Bool) {
                if final {
                    for pageIndex in 0..<document.pageCount {
                        if !body(pageIndex) {
                            break
                        }
                    }
                    return
                }
                let limit = min(rebuiltChunkCount, pagesToRebuild.count)
                for idx in 0..<limit {
                    if !body(pagesToRebuild[idx]) {
                        break
                    }
                }
            }
            func finalizePublish(totalMatching: Int, collected: [MarkupItem]) {
                self.markupItems = collected
                self.markupsTable.reloadData()
                self.lastKnownTotalMatchingMarkups = totalMatching
                self.isMarkupListTruncated = (totalMatching > indexCap)
                if self.isMarkupListTruncated {
                    self.markupsCountLabel.stringValue = "\(collected.count) of \(totalMatching) items (refine filter)"
                } else {
                    self.markupsCountLabel.stringValue = "\(collected.count) items"
                }
                self.updateMeasurementSummary()
                self.restoreSelection(for: selectedAnnotation)
                self.updateSelectionOverlay()
                self.requestChromeRefresh()
                self.persistMarkupIndexSnapshot(document: document)
                self.scheduleSearchIndexWarmupIfNeeded(document: document, generation: generation)
                PerformanceMetrics.end(
                    refreshSpan,
                    extra: [
                        "result": "ok",
                        "pages_rebuilt": "\(rebuildPageCount)",
                        "total_matching": "\(totalMatching)",
                        "listed_items": "\(collected.count)",
                        "page_count": "\(document.pageCount)"
                    ]
                )
            }
            if final && filter.isEmpty {
                totalMatching = totalCached
                forEachTargetPage { pageIndex in
                    guard let annotations = self.pageMarkupCache[pageIndex], collected.count < collectionCap else { return true }
                    let room = collectionCap - collected.count
                    for annotation in annotations.prefix(room) {
                        collected.append(MarkupItem(pageIndex: pageIndex, annotation: annotation))
                    }
                    if collected.count >= collectionCap {
                        return false
                    }
                    return true
                }
                finalizePublish(totalMatching: totalMatching, collected: collected)
                return
            }
            forEachTargetPage { pageIndex in
                guard let annotations = self.pageMarkupCache[pageIndex] else { return true }
                if filter.isEmpty {
                    totalMatching += annotations.count
                    guard collected.count < collectionCap else { return true }
                    let room = collectionCap - collected.count
                    let prefixCount = min(room, annotations.count)
                    if prefixCount > 0 {
                        for annotation in annotations.prefix(prefixCount) {
                            collected.append(MarkupItem(pageIndex: pageIndex, annotation: annotation))
                        }
                    }
                    if allowEarlyBreak && collected.count >= collectionCap {
                        return false
                    }
                } else {
                    var searchIndex = self.pageMarkupSearchIndex[pageIndex] ?? [:]
                    var didMutateSearchIndex = false
                    for annotation in annotations {
                        let key = ObjectIdentifier(annotation)
                        let searchText: String
                        if let cached = searchIndex[key] {
                            searchText = cached
                        } else {
                            searchText = annotationSearchText(for: annotation)
                            searchIndex[key] = searchText
                            didMutateSearchIndex = true
                        }
                        if searchText.contains(filter) {
                            totalMatching += 1
                            if collected.count < collectionCap {
                                collected.append(MarkupItem(pageIndex: pageIndex, annotation: annotation))
                            }
                        }
                    }
                    if didMutateSearchIndex {
                        self.pageMarkupSearchIndex[pageIndex] = searchIndex
                    }
                }
                return true
            }
            self.markupItems = collected
            self.markupsTable.reloadData()

            if !final {
                if filter.isEmpty {
                    self.markupsCountLabel.stringValue = "Loading… \(collected.count) shown"
                } else {
                    self.markupsCountLabel.stringValue = "Updating… \(collected.count) matches so far"
                }
                return
            }
            finalizePublish(totalMatching: totalMatching, collected: collected)
        }

        guard !pagesToRebuild.isEmpty else {
            publishResults(final: true, rebuiltChunkCount: pagesToRebuild.count)
            return
        }

        func rebuildChunk(from startIndex: Int) {
            guard generation == self.markupsScanGeneration else { return }
            let endIndex = min(startIndex + chunkSize, pagesToRebuild.count)
            if startIndex < endIndex {
                for idx in startIndex..<endIndex {
                    let pageIndex = pagesToRebuild[idx]
                    guard let page = document.page(at: pageIndex) else {
                        let previousCount = self.pageMarkupCache[pageIndex]?.count ?? 0
                        if let previousSummary = self.measurementSummaryByPage.removeValue(forKey: pageIndex) {
                            self.cachedMeasurementCount -= previousSummary.count
                            self.cachedMeasurementTotalPoints -= previousSummary.totalPoints
                        }
                        self.pageMarkupCache.removeValue(forKey: pageIndex)
                        self.pageMarkupSearchIndex.removeValue(forKey: pageIndex)
                        self.cachedMarkupAnnotationCount = max(0, self.cachedMarkupAnnotationCount - previousCount)
                        self.dirtyMarkupPageIndexes.remove(pageIndex)
                        continue
                    }
                    let annotations = page.annotations.filter(self.isUserEditableMarkup)
                    let previousCount = self.pageMarkupCache[pageIndex]?.count ?? 0
                    self.pageMarkupCache[pageIndex] = annotations
                    self.pageMarkupSearchIndex.removeValue(forKey: pageIndex)
                    self.cachedMarkupAnnotationCount += annotations.count - previousCount
                    let pageSummary = self.measurementSummary(for: annotations)
                    self.updateMeasurementSummaryCache(pageSummary, for: pageIndex)
                    self.dirtyMarkupPageIndexes.remove(pageIndex)
                }
            }
            if !didPublishProvisional,
               shouldPublishProvisional,
               endIndex >= provisionalPageTarget,
               endIndex < pagesToRebuild.count {
                didPublishProvisional = true
                publishResults(final: false, rebuiltChunkCount: endIndex)
            }
            if endIndex < pagesToRebuild.count {
                DispatchQueue.main.async {
                    rebuildChunk(from: endIndex)
                }
                return
            }
            publishResults(final: true, rebuiltChunkCount: pagesToRebuild.count)
        }

        rebuildChunk(from: 0)
    }

    private func ensureMarkupCacheDocumentIdentity(for document: PDFDocument) {
        let id = ObjectIdentifier(document)
        guard cachedMarkupDocumentID != id else { return }
        cancelSearchIndexWarmup()
        cachedMarkupDocumentID = id
        pageMarkupCache.removeAll(keepingCapacity: false)
        pageMarkupSearchIndex.removeAll(keepingCapacity: false)
        cachedMarkupAnnotationCount = 0
        measurementSummaryByPage.removeAll(keepingCapacity: false)
        cachedMeasurementCount = 0
        cachedMeasurementTotalPoints = 0
        dirtyMarkupPageIndexes = Set(0..<document.pageCount)
    }

    private func clearMarkupCache() {
        cancelSearchIndexWarmup()
        cachedMarkupDocumentID = nil
        pageMarkupCache.removeAll(keepingCapacity: false)
        pageMarkupSearchIndex.removeAll(keepingCapacity: false)
        cachedMarkupAnnotationCount = 0
        measurementSummaryByPage.removeAll(keepingCapacity: false)
        cachedMeasurementCount = 0
        cachedMeasurementTotalPoints = 0
        dirtyMarkupPageIndexes.removeAll(keepingCapacity: false)
        lastKnownTotalMatchingMarkups = 0
        isMarkupListTruncated = false
        markupsScanGeneration += 1
    }

    func markPageMarkupCacheDirty(_ page: PDFPage?) {
        guard let page, let document = pdfView.document else { return }
        ensureMarkupCacheDocumentIdentity(for: document)
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return }
        dirtyMarkupPageIndexes.insert(pageIndex)
        invalidateVisibleMarkupRendering(on: page)
    }

    private func invalidateVisibleMarkupRendering(on page: PDFPage) {
        guard pdfView.currentPage === page else { return }
        let pageBounds = page.bounds(for: pdfView.displayBox)
        let rectInView = pdfView.convert(pageBounds, from: page)
        let hasFiniteComponents =
            rectInView.origin.x.isFinite &&
            rectInView.origin.y.isFinite &&
            rectInView.size.width.isFinite &&
            rectInView.size.height.isFinite
        if rectInView.isNull || !hasFiniteComponents || rectInView.isEmpty {
            pdfView.needsDisplay = true
            return
        }
        let expanded = rectInView.insetBy(dx: -4, dy: -4)
        pdfView.setNeedsDisplay(expanded)
    }

    func totalCachedAnnotationCount() -> Int {
        cachedMarkupAnnotationCount
    }

    private func annotationSearchText(for annotation: PDFAnnotation) -> String {
        let type = annotation.type ?? ""
        let contents = annotation.contents ?? ""
        let author = annotation.userName ?? ""
        return "\(type)\n\(author)\n\(contents)".lowercased()
    }

    private func measurementSummary(for annotations: [PDFAnnotation]) -> (count: Int, totalPoints: CGFloat) {
        let prefix = "DrawbridgeMeasure|"
        var count = 0
        var totalPoints: CGFloat = 0
        for annotation in annotations {
            guard let contents = annotation.contents,
                  contents.hasPrefix(prefix),
                  let points = Double(contents.dropFirst(prefix.count)) else {
                continue
            }
            count += 1
            totalPoints += CGFloat(points)
        }
        return (count, totalPoints)
    }

    private func updateMeasurementSummaryCache(_ summary: (count: Int, totalPoints: CGFloat), for pageIndex: Int) {
        if let previous = measurementSummaryByPage[pageIndex] {
            cachedMeasurementCount -= previous.count
            cachedMeasurementTotalPoints -= previous.totalPoints
        }
        measurementSummaryByPage[pageIndex] = summary
        cachedMeasurementCount += summary.count
        cachedMeasurementTotalPoints += summary.totalPoints
    }

    func annotationsForPageIndex(_ pageIndex: Int, in document: PDFDocument) -> [PDFAnnotation] {
        if let cached = pageMarkupCache[pageIndex] {
            return cached
        }
        return document.page(at: pageIndex)?.annotations.filter(isUserEditableMarkup) ?? []
    }

    func searchableAnnotationText(for annotation: PDFAnnotation, pageIndex: Int) -> String {
        let key = ObjectIdentifier(annotation)
        if let cached = pageMarkupSearchIndex[pageIndex]?[key] {
            return cached
        }
        let text = annotationSearchText(for: annotation)
        var pageIndexCache = pageMarkupSearchIndex[pageIndex] ?? [:]
        pageIndexCache[key] = text
        pageMarkupSearchIndex[pageIndex] = pageIndexCache
        return text
    }

    private func cancelSearchIndexWarmup() {
        pendingSearchIndexWarmupWorkItem?.cancel()
        pendingSearchIndexWarmupWorkItem = nil
        searchIndexWarmupGeneration += 1
    }

    private func scheduleSearchIndexWarmupIfNeeded(document: PDFDocument, generation: Int) {
        guard cachedMarkupDocumentID == ObjectIdentifier(document),
              dirtyMarkupPageIndexes.isEmpty,
              totalCachedAnnotationCount() > 0 else {
            cancelSearchIndexWarmup()
            return
        }
        cancelSearchIndexWarmup()
        let warmupGeneration = searchIndexWarmupGeneration
        let workItem = DispatchWorkItem { [weak self] in
            self?.continueSearchIndexWarmup(
                document: document,
                refreshGeneration: generation,
                warmupGeneration: warmupGeneration,
                startPageIndex: 0,
                startAnnotationIndex: 0
            )
        }
        pendingSearchIndexWarmupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func continueSearchIndexWarmup(
        document: PDFDocument,
        refreshGeneration: Int,
        warmupGeneration: Int,
        startPageIndex: Int,
        startAnnotationIndex: Int
    ) {
        guard refreshGeneration == markupsScanGeneration,
              warmupGeneration == searchIndexWarmupGeneration,
              cachedMarkupDocumentID == ObjectIdentifier(document),
              let activeDocument = pdfView.document,
              ObjectIdentifier(activeDocument) == ObjectIdentifier(document) else {
            pendingSearchIndexWarmupWorkItem = nil
            return
        }

        let maxNewEntriesPerSlice = 500
        var remaining = maxNewEntriesPerSlice
        var pageIndex = startPageIndex
        var annotationIndex = startAnnotationIndex

        while pageIndex < document.pageCount, remaining > 0 {
            guard let annotations = pageMarkupCache[pageIndex], !annotations.isEmpty else {
                pageMarkupSearchIndex.removeValue(forKey: pageIndex)
                pageIndex += 1
                annotationIndex = 0
                continue
            }
            var pageIndexCache = pageMarkupSearchIndex[pageIndex] ?? [:]
            if pageIndexCache.isEmpty {
                pageIndexCache.reserveCapacity(annotations.count)
            }
            if annotationIndex == 0, pageIndexCache.count >= annotations.count {
                pageIndex += 1
                continue
            }
            while annotationIndex < annotations.count, remaining > 0 {
                let annotation = annotations[annotationIndex]
                let key = ObjectIdentifier(annotation)
                if pageIndexCache[key] == nil {
                    pageIndexCache[key] = annotationSearchText(for: annotation)
                    remaining -= 1
                }
                annotationIndex += 1
            }
            pageMarkupSearchIndex[pageIndex] = pageIndexCache
            if annotationIndex >= annotations.count {
                pageIndex += 1
                annotationIndex = 0
            }
        }

        if pageIndex >= document.pageCount {
            pendingSearchIndexWarmupWorkItem = nil
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.continueSearchIndexWarmup(
                document: document,
                refreshGeneration: refreshGeneration,
                warmupGeneration: warmupGeneration,
                startPageIndex: pageIndex,
                startAnnotationIndex: annotationIndex
            )
        }
        pendingSearchIndexWarmupWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func registerDefaultPerformanceSettingsIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.defaultsAdaptiveIndexCapEnabledKey) == nil {
            defaults.set(true, forKey: Self.defaultsAdaptiveIndexCapEnabledKey)
        }
        if defaults.object(forKey: Self.defaultsIndexCapKey) == nil {
            defaults.set(25_000, forKey: Self.defaultsIndexCapKey)
        }
        if defaults.object(forKey: Self.defaultsWatchdogEnabledKey) == nil {
            defaults.set(true, forKey: Self.defaultsWatchdogEnabledKey)
        }
        if defaults.object(forKey: Self.defaultsWatchdogThresholdSecondsKey) == nil {
            defaults.set(2.5, forKey: Self.defaultsWatchdogThresholdSecondsKey)
        }
        if defaults.object(forKey: Self.defaultsHyperlinkHighlightsVisibleKey) == nil {
            defaults.set(false, forKey: Self.defaultsHyperlinkHighlightsVisibleKey)
        }
    }

    private func migrateHyperlinkHighlightsDefaultIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.defaultsHyperlinkHighlightsDefaultMigrationKey) {
            return
        }
        defaults.set(true, forKey: Self.defaultsHyperlinkHighlightsVisibleKey)
        defaults.set(true, forKey: Self.defaultsHyperlinkHighlightsDefaultMigrationKey)
    }

    func configuredIndexCap() -> Int {
        let raw = UserDefaults.standard.integer(forKey: Self.defaultsIndexCapKey)
        let normalized = raw > 0 ? raw : 25_000
        return min(max(normalized, minimumIndexedMarkupItems), maximumIndexedMarkupItems)
    }

    private func adaptiveIndexCapEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: Self.defaultsAdaptiveIndexCapEnabledKey)
    }

    private func effectiveIndexCap(for document: PDFDocument) -> Int {
        var cap = configuredIndexCap()
        guard adaptiveIndexCapEnabled() else { return cap }
        let pageCount = document.pageCount
        if pageCount >= 1000 {
            cap = max(minimumIndexedMarkupItems, Int(Double(cap) * 0.45))
        } else if pageCount >= 600 {
            cap = max(minimumIndexedMarkupItems, Int(Double(cap) * 0.65))
        }
        return cap
    }

    func configureWatchdogFromDefaults() {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: Self.defaultsWatchdogEnabledKey)
        let threshold = max(0.5, defaults.double(forKey: Self.defaultsWatchdogThresholdSecondsKey))
        if let watchdog {
            watchdog.update(enabled: enabled, thresholdSeconds: threshold)
            return
        }
        watchdog = MainThreadWatchdog(enabled: enabled, thresholdSeconds: threshold) { [weak self] lagSeconds in
            guard let self else { return }
            self.recordWatchdogStall(lagSeconds: lagSeconds)
        }
    }

    private func recordWatchdogStall(lagSeconds: Double) {
        guard let dir = watchdogLogsDirectoryURL() else { return }
        let pageCount = pdfView.document?.pageCount ?? 0
        let cached = totalCachedAnnotationCount()
        let listed = markupItems.count
        let totalMatching = lastKnownTotalMatchingMarkups
        let documentPath = openDocumentURL?.path ?? "Untitled"
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] stall=\(String(format: "%.2f", lagSeconds))s pages=\(pageCount) cached=\(cached) listed=\(listed) matching=\(totalMatching) doc=\(documentPath)\n"
        let fileURL = dir.appendingPathComponent("watchdog.log")
        DispatchQueue.global(qos: .utility).async {
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: fileURL.path),
                   let handle = try? FileHandle(forWritingTo: fileURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: fileURL, options: .atomic)
                }
            }
        }
    }

    private func watchdogLogsDirectoryURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("Drawbridge").appendingPathComponent("Logs")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    func scheduleMarkupsRefresh(selecting selectedAnnotation: PDFAnnotation?) {
        pendingMarkupsRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performRefreshMarkups(selecting: selectedAnnotation)
        }
        pendingMarkupsRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    func requestChromeRefresh(immediate: Bool = false) {
        if immediate {
            pendingChromeRefreshWorkItem?.cancel()
            pendingChromeRefreshWorkItem = nil
            updateStatusBar()
            refreshRulers()
            return
        }
        pendingChromeRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingChromeRefreshWorkItem = nil
            self.updateStatusBar()
            self.refreshRulers()
        }
        pendingChromeRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    func markMarkupChanged() {
        promptInitialMarkupSaveCopyIfNeeded()
        markupChangeVersion += 1
        lastMarkupEditAt = Date()
        lastUserInteractionAt = Date()
        view.window?.isDocumentEdited = true
        refreshSearchIfNeeded()
    }

    func markMarkupChangedAndScheduleAutosave() {
        markMarkupChanged()
        scheduleAutosave()
    }

    func commitMarkupMutation(
        selecting selectedAnnotation: PDFAnnotation?,
        forceImmediateRefresh: Bool = false,
        scheduleAutosave shouldScheduleAutosave: Bool = true
    ) {
        let mutationSpan = PerformanceMetrics.begin(
            "commit_markup_mutation",
            thresholdMs: 20,
            fields: [
                "force_immediate": forceImmediateRefresh ? "1" : "0",
                "schedule_autosave": shouldScheduleAutosave ? "1" : "0"
            ]
        )
        markMarkupChanged()
        performRefreshMarkups(selecting: selectedAnnotation, forceImmediate: forceImmediateRefresh)
        updatePDFContentsSummary()
        if shouldScheduleAutosave {
            scheduleAutosave()
        }
        PerformanceMetrics.end(mutationSpan, extra: ["result": "ok"])
    }

    private func promptInitialMarkupSaveCopyIfNeeded() {
        // Allow direct markup edits on the opened source PDF without forcing
        // a protective copy workflow.
        hasPromptedForInitialMarkupSaveCopy = true
        isPresentingInitialMarkupSaveCopyPrompt = false
    }

    func ensureWorkingCopyBeforeFirstMarkup() -> Bool {
        hasPromptedForInitialMarkupSaveCopy = true
        isPresentingInitialMarkupSaveCopyPrompt = false
        return true
    }

    private func suggestedMarkupCopyFilename(for sourceURL: URL) -> String {
        let datePrefix = Self.markupCopyDateFormatter.string(from: Date())
        return "\(datePrefix) - markups \(sourceURL.lastPathComponent)"
    }

    private func promptForInitialMarkupWorkingCopy(from sourceURL: URL) -> Bool {
        let explanation = NSAlert()
        explanation.messageText = "Create a marked-up copy before continuing?"
        explanation.informativeText = """
        To protect your original PDF, Drawbridge saves markups to a separate copy.

        Your source file will remain unchanged. Choose where to save the marked-up copy next.
        """
        explanation.alertStyle = .informational
        explanation.addButton(withTitle: "Choose Save Location")
        explanation.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard explanation.runModal() == .alertFirstButtonReturn else {
            return false
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.title = "Save Marked-Up Copy"
        panel.message = "Choose where to save your marked-up PDF. The original file will not be modified."
        panel.prompt = "Save Markup Copy"
        panel.nameFieldStringValue = suggestedMarkupCopyFilename(for: sourceURL)

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return false
        }

        beginBusyIndicator("Preparing Working Copy…")
        defer { endBusyIndicator() }

        do {
            let source = canonicalDocumentURL(sourceURL)
            let destination = canonicalDocumentURL(destinationURL)
            if source != destination {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
            }
            sessionDocumentURLs.removeAll { canonicalDocumentURL($0) == source }
            openDocumentURL = destination
            registerSessionDocument(destination)
            configureAutosaveURL(for: destination)
            view.window?.title = "Drawbridge - \(destination.lastPathComponent)"
            onDocumentOpened?(destination)
            // User explicitly chose a markup file; persist current in-memory markups immediately.
            if let document = pdfView.document {
                persistProjectSnapshot(document: document, for: destination, busyMessage: "Saving Changes…")
            }
            return true
        } catch {
            runAlert(
                title: "Failed to create working copy",
                informativeText: "Could not copy \(sourceURL.lastPathComponent).\n\n\(error.localizedDescription)",
                style: .warning
            )
            return false
        }
    }

    @objc private func filterMarkups() {
        markupFilterText = markupFilterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        refreshMarkups()
    }


    @objc private func selectMarkupFromTable() {
        jumpToSelectedMarkup()
        updateSelectionOverlay()
        updateToolSettingsUIForCurrentTool()
    }



    @objc func exportMarkupsCSV() {
        guard let document = pdfView.document else { beep(); return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Drawbridge-Markups.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var rows: [String] = []
        rows.append("page,type,text,x,y,width,height")

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where isUserEditableMarkup(annotation) {
                let b = annotation.bounds
                let fields = [
                    csvEscape(displayPageLabel(forPageIndex: pageIndex)),
                    csvEscape(annotation.type ?? "Unknown"),
                    csvEscape(annotation.contents ?? ""),
                    String(format: "%.4f", b.origin.x),
                    String(format: "%.4f", b.origin.y),
                    String(format: "%.4f", b.size.width),
                    String(format: "%.4f", b.size.height)
                ]
                rows.append(fields.joined(separator: ","))
            }
        }

        let csv = rows.joined(separator: "\n")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            runAlert(
                title: "Failed to export CSV",
                informativeText: error.localizedDescription,
                style: .warning
            )
        }
    }

    private struct JPEGExportPreset {
        let title: String
        let compressionQuality: CGFloat
        let dpi: CGFloat
    }

    private var mobileJPEGExportPreset: JPEGExportPreset {
        JPEGExportPreset(title: "Low (60%)", compressionQuality: 0.60, dpi: 120)
    }

    private func jpegExportPresetSelection(defaultIndex: Int = 2) -> JPEGExportPreset? {
        let presets: [JPEGExportPreset] = [
            .init(title: "Low (60%)", compressionQuality: 0.60, dpi: 120),
            .init(title: "Medium (75%)", compressionQuality: 0.75, dpi: 150),
            .init(title: "High (90%)", compressionQuality: 0.90, dpi: 200),
            .init(title: "Maximum (100%)", compressionQuality: 1.0, dpi: 300)
        ]

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 28), pullsDown: false)
        popup.addItems(withTitles: presets.map(\.title))
        let clampedDefaultIndex = max(0, min(defaultIndex, presets.count - 1))
        popup.selectItem(at: clampedDefaultIndex)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 42))
        popup.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            popup.centerYAnchor.constraint(equalTo: accessory.centerYAnchor)
        ])

        let response = runAlert(
            title: "JPEG Export Quality",
            informativeText: "Choose image quality for all exported pages.",
            buttons: ["Export", "Cancel"],
            accessoryView: accessory,
            activateApp: true
        )
        guard response == .alertFirstButtonReturn else { return nil }
        let selected = max(0, min(popup.indexOfSelectedItem, presets.count - 1))
        return presets[selected]
    }

    private func promptJPEGExportDestination(defaultFolderName: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Select a destination folder for exported JPEG pages."
        guard panel.runModal() == .OK, let root = panel.url else { return nil }

        let output = root.appendingPathComponent(defaultFolderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            return output
        } catch {
            runAlert(
                title: "Failed to create export folder",
                informativeText: error.localizedDescription,
                style: .warning
            )
            return nil
        }
    }

    private func uniqueSubdirectoryURL(baseName: String, in root: URL) -> URL {
        var candidate = root.appendingPathComponent(baseName, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(baseName) \(counter)", isDirectory: true)
            counter += 1
        }
        return candidate
    }

    private func uniqueFileURL(baseName: String, extension fileExtension: String, in folder: URL) -> URL {
        let sanitizedBase = sanitizedFilename(baseName)
        var candidate = folder.appendingPathComponent(sanitizedBase).appendingPathExtension(fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(sanitizedBase) \(counter)").appendingPathExtension(fileExtension)
            counter += 1
        }
        return candidate
    }

    private func pdfURLs(in folderURL: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { return false }
            return url.pathExtension.lowercased() == "pdf"
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private func pageJPEGImage(page: PDFPage, dpi: CGFloat) -> CGImage? {
        let displayBox = pdfView.displayBox
        var bounds = page.bounds(for: displayBox).standardized
        if bounds.width <= 1 || bounds.height <= 1 {
            bounds = page.bounds(for: .cropBox).standardized
        }
        if bounds.width <= 1 || bounds.height <= 1 {
            bounds = page.bounds(for: .mediaBox).standardized
        }
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let scale = max(1.0, dpi / 72.0)
        let targetSize = NSSize(
            width: max(1, (bounds.width * scale).rounded(.up)),
            height: max(1, (bounds.height * scale).rounded(.up))
        )
        let thumb = page.thumbnail(of: targetSize, for: displayBox)
        if let cgImage = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cgImage
        }
        guard let tiffData = thumb.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return rep.cgImage
    }

    private func sanitizedFilename(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleanedScalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let cleaned = String(cleanedScalars).trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return cleaned.isEmpty ? "Page" : cleaned
    }

    private func shortDuration(_ seconds: TimeInterval) -> String {
        let clamped = max(0, Int(seconds.rounded()))
        let m = clamped / 60
        let s = clamped % 60
        if m > 0 {
            return "\(m)m \(s)s"
        }
        return "\(s)s"
    }

    private func jpegImageURLs(in folderURL: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let extensions = Set(["jpg", "jpeg"])
        return urls.filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { return false }
            return extensions.contains(url.pathExtension.lowercased())
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private func applyImageFilenameBookmarks(to document: PDFDocument, imageURLs: [URL]) {
        let root = PDFOutline()
        let setLabelSelector = NSSelectorFromString("setLabel:")
        for (index, imageURL) in imageURLs.enumerated() {
            guard let page = document.page(at: index) else { continue }
            let title = imageURL.deletingPathExtension().lastPathComponent
            let bookmark = PDFOutline()
            bookmark.label = title
            bookmark.destination = PDFDestination(page: page, at: NSPoint(x: 0, y: page.bounds(for: .cropBox).maxY))
            root.insertChild(bookmark, at: root.numberOfChildren)

            // Best-effort page label assignment for viewers that support embedded page labels.
            if page.responds(to: setLabelSelector) {
                _ = page.perform(setLabelSelector, with: title)
            }
        }
        document.outlineRoot = root
    }

    func convertImageFolderToPDF() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        panel.message = "Select a folder containing JPG images to convert into one multi-page PDF."
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        let imageURLs = jpegImageURLs(in: folderURL)
        guard !imageURLs.isEmpty else {
            runAlert(
                title: "No JPG Files Found",
                informativeText: "No .jpg or .jpeg files were found in the selected folder.",
                style: .warning
            )
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = "\(folderURL.lastPathComponent).pdf"
        savePanel.prompt = "Convert"
        guard savePanel.runModal() == .OK, let outputURL = savePanel.url else { return }

        beginBusyIndicator("Converting Images to PDF…", detail: "0/\(imageURLs.count)")
        updateBusyIndicatorSubdetail("Building pages…")
        updateBusyIndicatorProgress(current: 0, total: imageURLs.count)
        defer { endBusyIndicator() }

        let pdf = PDFDocument()
        var failed: [String] = []
        for (idx, imageURL) in imageURLs.enumerated() {
            autoreleasepool {
                if let image = NSImage(contentsOf: imageURL),
                   let page = PDFPage(image: image) {
                    pdf.insert(page, at: pdf.pageCount)
                } else {
                    failed.append(imageURL.lastPathComponent)
                }
            }
            let done = idx + 1
            updateBusyIndicatorDetail("\(done)/\(imageURLs.count) • \(imageURL.lastPathComponent)")
            updateBusyIndicatorSubdetail("Output: \(outputURL.lastPathComponent)")
            updateBusyIndicatorProgress(current: done, total: imageURLs.count)
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }

        guard pdf.pageCount > 0 else {
            runAlert(
                title: "Conversion Failed",
                informativeText: "No images could be converted into PDF pages.",
                style: .warning
            )
            return
        }

        applyImageFilenameBookmarks(to: pdf, imageURLs: imageURLs)

        guard pdf.write(to: outputURL) else {
            runAlert(
                title: "Failed to Save PDF",
                informativeText: "Could not write the converted PDF to:\n\(outputURL.path)",
                style: .warning
            )
            return
        }

        if failed.isEmpty {
            runAlert(
                title: "Conversion Complete",
                informativeText: "Created \(outputURL.lastPathComponent) with \(pdf.pageCount) pages."
            )
        } else {
            let preview = failed.prefix(10).joined(separator: ", ")
            let suffix = failed.count > 10 ? ", …" : ""
            runAlert(
                title: "Conversion Complete with Issues",
                informativeText: """
                Created \(outputURL.lastPathComponent) with \(pdf.pageCount) pages.

                Skipped files: \(preview)\(suffix)
                """,
                style: .warning
            )
        }
    }

    private struct JPEGExportRunResult {
        let successCount: Int
        let failedPages: [Int]
        let canceled: Bool
    }

    private func runJPEGExport(
        document: PDFDocument,
        preset: JPEGExportPreset,
        exportDirectory: URL,
        progressTitle: String
    ) -> JPEGExportRunResult {
        isJPEGExportCancellationRequested = false
        beginBusyIndicator(progressTitle, detail: "Preparing export…", lockInteraction: false)
        setBusyCancelAction({ [weak self] in
            guard let self else { return }
            self.isJPEGExportCancellationRequested = true
            self.setBusyCancelAction(self.busyCancelHandler, title: "Canceling…", enabled: false)
            self.updateBusyIndicatorDetail("Stopping after current page…")
            self.updateBusyIndicatorSubdetail("")
        }, title: "Cancel Export")
        updateBusyIndicatorDetail("0/\(document.pageCount) • \(preset.title), \(Int(preset.dpi)) DPI")
        updateBusyIndicatorSubdetail("ETA --")
        updateBusyIndicatorProgress(current: 0, total: document.pageCount)
        defer { endBusyIndicator() }

        let start = Date()
        var successCount = 0
        var failedPages: [Int] = []
        for pageIndex in 0..<document.pageCount {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
            if isJPEGExportCancellationRequested {
                break
            }
            let completedBefore = pageIndex
            let percentBefore = Int((Double(completedBefore) / Double(max(1, document.pageCount)) * 100.0).rounded())
            let pageLabel = displayPageLabel(forPageIndex: pageIndex)
            updateBusyIndicatorStatus("\(progressTitle) \(percentBefore)%")
            updateBusyIndicatorDetail("Rendering \(pageIndex + 1)/\(document.pageCount) • \(pageLabel)")
            updateBusyIndicatorSubdetail("ETA calculating…")
            updateBusyIndicatorProgress(current: completedBefore, total: document.pageCount)
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))

            var exportSucceeded = false
            if let page = document.page(at: pageIndex) {
                autoreleasepool {
                    guard let image = pageJPEGImage(page: page, dpi: preset.dpi) else { return }
                    let filename = String(format: "Page-%04d - %@.jpg", pageIndex + 1, sanitizedFilename(pageLabel))
                    let destination = exportDirectory.appendingPathComponent(filename)
                    guard let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
                    let options = [kCGImageDestinationLossyCompressionQuality: preset.compressionQuality] as CFDictionary
                    CGImageDestinationAddImage(destinationRef, image, options)
                    exportSucceeded = CGImageDestinationFinalize(destinationRef)
                }
            }

            if !exportSucceeded {
                failedPages.append(pageIndex + 1)
                let completed = pageIndex + 1
                let elapsed = Date().timeIntervalSince(start)
                let avg = elapsed / Double(max(1, completed))
                let remaining = avg * Double(max(0, document.pageCount - completed))
                let percent = Int((Double(completed) / Double(max(1, document.pageCount)) * 100.0).rounded())
                updateBusyIndicatorStatus("\(progressTitle) \(percent)%")
                updateBusyIndicatorDetail("\(completed)/\(document.pageCount) • \(preset.title), \(Int(preset.dpi)) DPI")
                updateBusyIndicatorSubdetail("ETA \(shortDuration(remaining))")
                updateBusyIndicatorProgress(current: completed, total: document.pageCount)
                continue
            }

            let filename = String(format: "Page-%04d - %@.jpg", pageIndex + 1, sanitizedFilename(pageLabel))
            successCount += 1

            let completed = pageIndex + 1
            let elapsed = Date().timeIntervalSince(start)
            let avg = elapsed / Double(max(1, completed))
            let remaining = avg * Double(max(0, document.pageCount - completed))
            let percent = Int((Double(completed) / Double(max(1, document.pageCount)) * 100.0).rounded())
            updateBusyIndicatorStatus("\(progressTitle) \(percent)%")
            updateBusyIndicatorDetail("\(completed)/\(document.pageCount) • \(filename)")
            updateBusyIndicatorSubdetail("ETA \(shortDuration(remaining))")
            updateBusyIndicatorProgress(current: completed, total: document.pageCount)
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }

        return JPEGExportRunResult(
            successCount: successCount,
            failedPages: failedPages,
            canceled: isJPEGExportCancellationRequested
        )
    }

    @objc func exportPagesAsJPEGAndRebuildPDF() {
        guard let document = pdfView.document else { beep(); return }
        guard let preset = jpegExportPresetSelection(defaultIndex: 0) else { return }

        let baseName = sanitizedFilename((openDocumentURL?.deletingPathExtension().lastPathComponent) ?? "Drawbridge Export")
        guard let exportDirectory = promptJPEGExportDestination(defaultFolderName: "\(baseName) - JPG Pages") else { return }

        let exportResult = runJPEGExport(
            document: document,
            preset: preset,
            exportDirectory: exportDirectory,
            progressTitle: "Exporting JPEG Pages…"
        )
        if exportResult.canceled {
            runAlert(
                title: "JPEG Export Canceled",
                informativeText: "Exported \(exportResult.successCount) of \(document.pageCount) page(s) to:\n\(exportDirectory.path)"
            )
            return
        }
        guard exportResult.successCount > 0 else {
            runAlert(
                title: "No Pages Exported",
                informativeText: "No JPEG pages were exported, so a combined PDF could not be created.",
                style: .warning
            )
            return
        }

        let imageURLs = jpegImageURLs(in: exportDirectory)
        guard !imageURLs.isEmpty else {
            runAlert(
                title: "No JPG Files Found",
                informativeText: "The export completed, but no .jpg files were found in:\n\(exportDirectory.path)",
                style: .warning
            )
            return
        }

        let temporaryOutputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("drawbridge-export-ipad-\(UUID().uuidString)")
            .appendingPathExtension("pdf")

        beginBusyIndicator("Rebuilding PDF from JPEG Pages…", detail: "0/\(imageURLs.count)")
        updateBusyIndicatorSubdetail("Building pages…")
        updateBusyIndicatorProgress(current: 0, total: imageURLs.count)
        defer { endBusyIndicator() }

        let rebuiltPDF = PDFDocument()
        var failedImageFiles: [String] = []
        for (index, imageURL) in imageURLs.enumerated() {
            autoreleasepool {
                if let image = NSImage(contentsOf: imageURL),
                   let page = PDFPage(image: image) {
                    rebuiltPDF.insert(page, at: rebuiltPDF.pageCount)
                } else {
                    failedImageFiles.append(imageURL.lastPathComponent)
                }
            }
            let done = index + 1
            updateBusyIndicatorDetail("\(done)/\(imageURLs.count) • \(imageURL.lastPathComponent)")
            updateBusyIndicatorSubdetail("Preparing combined PDF…")
            updateBusyIndicatorProgress(current: done, total: imageURLs.count)
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }

        guard rebuiltPDF.pageCount > 0 else {
            runAlert(
                title: "Rebuild Failed",
                informativeText: "No JPG files could be converted into PDF pages.",
                style: .warning
            )
            return
        }

        guard Self.writePDFDocument(rebuiltPDF, to: temporaryOutputURL, pageLabels: [:]) else {
            runAlert(
                title: "Failed to Save PDF",
                informativeText: "Could not create the temporary combined PDF.",
                style: .warning
            )
            return
        }
        try? FileManager.default.removeItem(at: exportDirectory)

        openDocument(at: temporaryOutputURL)
        hasPromptedForInitialMarkupSaveCopy = true
        isPresentingInitialMarkupSaveCopyPrompt = false
        shouldChainAutoNameAfterBatchLink = false
        pendingExportToIPadTemporaryURL = nil
        pendingExportToIPadSuggestedFilename = nil
        let exportIssueCount = exportResult.failedPages.count
        let rebuildIssueCount = failedImageFiles.count
        let hasIssues = exportIssueCount > 0 || rebuildIssueCount > 0
        let exportSummary = "Opened the iPad PDF. Run Batch Link Sheet Numbers and Auto-Generate Sheet Names/Bookmarks manually if you want hyperlinks/bookmarks."
        pendingExportToIPadTemporaryURL = temporaryOutputURL
        pendingExportToIPadSuggestedFilename = "\(baseName) - iPhone-iPad.pdf"

        if !hasIssues {
            promptFinalizeExportToIPadSave(document: rebuiltPDF)
            runAlert(
                title: "Export to iPhone / iPad Complete",
                informativeText: """
                Exported \(exportResult.successCount) JPG page(s).
                Built a combined PDF with \(rebuiltPDF.pageCount) pages.

                \(exportSummary)
                """
            )
            return
        }

        let pageFailurePreview = exportResult.failedPages.prefix(10).map(String.init).joined(separator: ", ")
        let pageFailureSuffix = exportResult.failedPages.count > 10 ? ", …" : ""
        let imageFailurePreview = failedImageFiles.prefix(8).joined(separator: ", ")
        let imageFailureSuffix = failedImageFiles.count > 8 ? ", …" : ""
        var issues: [String] = []
        if !exportResult.failedPages.isEmpty {
            issues.append("Export failed page(s): \(pageFailurePreview)\(pageFailureSuffix)")
        }
        if !failedImageFiles.isEmpty {
            issues.append("Rebuild skipped image(s): \(imageFailurePreview)\(imageFailureSuffix)")
        }
        runAlert(
            title: "Export to iPhone / iPad Complete with Issues",
            informativeText: """
            Built a combined PDF with \(rebuiltPDF.pageCount) pages.
            \(exportSummary)

            \(issues.joined(separator: "\n"))
            """,
            style: .warning
        )
        promptFinalizeExportToIPadSave(document: rebuiltPDF)
    }

    @objc func batchExportToMobilePDFs() {
        let sourcePanel = NSOpenPanel()
        sourcePanel.canChooseFiles = false
        sourcePanel.canChooseDirectories = true
        sourcePanel.canCreateDirectories = false
        sourcePanel.allowsMultipleSelection = false
        sourcePanel.prompt = "Choose Folder"
        sourcePanel.message = "Select the folder of PDFs to batch convert for iPhone / iPad."
        guard sourcePanel.runModal() == .OK, let sourceFolder = sourcePanel.url else { return }

        let pdfFiles = pdfURLs(in: sourceFolder)
        guard !pdfFiles.isEmpty else {
            runAlert(
                title: "No PDFs Found",
                informativeText: "No PDF files were found in:\n\(sourceFolder.path)",
                style: .warning
            )
            return
        }

        let destinationPanel = NSOpenPanel()
        destinationPanel.canChooseFiles = false
        destinationPanel.canChooseDirectories = true
        destinationPanel.canCreateDirectories = true
        destinationPanel.allowsMultipleSelection = false
        destinationPanel.prompt = "Choose Folder"
        destinationPanel.message = "Select where the iPhone / iPad PDFs should be saved."
        guard destinationPanel.runModal() == .OK, let destinationRoot = destinationPanel.url else { return }

        let outputFolder = uniqueSubdirectoryURL(
            baseName: "\(sourceFolder.lastPathComponent) - iPhone iPad PDFs",
            in: destinationRoot
        )
        do {
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        } catch {
            runAlert(
                title: "Could Not Create Output Folder",
                informativeText: error.localizedDescription,
                style: .warning
            )
            return
        }

        let preset = mobileJPEGExportPreset
        var readableFiles: [(url: URL, document: PDFDocument, pageCount: Int)] = []
        var issues: [String] = []
        for url in pdfFiles {
            guard let document = PDFDocument(url: url), document.pageCount > 0 else {
                issues.append("\(url.lastPathComponent): could not open PDF")
                continue
            }
            readableFiles.append((url, document, document.pageCount))
        }

        guard !readableFiles.isEmpty else {
            runAlert(
                title: "Batch Export Failed",
                informativeText: "None of the PDFs in the selected folder could be opened.",
                style: .warning
            )
            return
        }

        let totalPages = readableFiles.reduce(0) { $0 + $1.pageCount }
        isBatchJPEGExportCancellationRequested = false
        beginBusyIndicator("Batch Exporting to iPhone / iPad…", detail: "Preparing files…", lockInteraction: false)
        setBusyCancelAction({ [weak self] in
            guard let self else { return }
            self.isBatchJPEGExportCancellationRequested = true
            self.setBusyCancelAction(self.busyCancelHandler, title: "Canceling…", enabled: false)
            self.updateBusyIndicatorDetail("Stopping after current PDF…")
            self.updateBusyIndicatorSubdetail("")
        }, title: "Cancel Export")
        updateBusyIndicatorProgress(current: 0, total: max(1, totalPages))
        defer { endBusyIndicator() }

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("drawbridge-batch-mobile-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let start = Date()
        var processedPages = 0
        var exportedFiles = 0

        for (fileIndex, fileInfo) in readableFiles.enumerated() {
            if isBatchJPEGExportCancellationRequested { break }
            let baseName = sanitizedFilename(fileInfo.url.deletingPathExtension().lastPathComponent)
            let tempImageFolder = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: tempImageFolder, withIntermediateDirectories: true)
            } catch {
                issues.append("\(fileInfo.url.lastPathComponent): could not create temporary folder")
                continue
            }

            var failedPages: [Int] = []
            var imageURLs: [URL] = []
            for pageIndex in 0..<fileInfo.document.pageCount {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
                if isBatchJPEGExportCancellationRequested { break }

                let elapsed = Date().timeIntervalSince(start)
                let average = elapsed / Double(max(1, processedPages))
                let remaining = average * Double(max(0, totalPages - processedPages))
                updateBusyIndicatorStatus("Batch Exporting to iPhone / iPad…")
                updateBusyIndicatorDetail("File \(fileIndex + 1)/\(readableFiles.count): \(fileInfo.url.lastPathComponent)")
                updateBusyIndicatorSubdetail("Page \(pageIndex + 1)/\(fileInfo.document.pageCount) • \(processedPages)/\(totalPages) done • ETA \(shortDuration(remaining))")
                updateBusyIndicatorProgress(current: processedPages, total: max(1, totalPages))

                var exportSucceeded = false
                if let page = fileInfo.document.page(at: pageIndex) {
                    autoreleasepool {
                        guard let image = pageJPEGImage(page: page, dpi: preset.dpi) else { return }
                        let destination = tempImageFolder.appendingPathComponent(String(format: "Page-%04d.jpg", pageIndex + 1))
                        guard let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
                        let options = [kCGImageDestinationLossyCompressionQuality: preset.compressionQuality] as CFDictionary
                        CGImageDestinationAddImage(destinationRef, image, options)
                        exportSucceeded = CGImageDestinationFinalize(destinationRef)
                        if exportSucceeded {
                            imageURLs.append(destination)
                        }
                    }
                }

                if !exportSucceeded {
                    failedPages.append(pageIndex + 1)
                }
                processedPages += 1
                updateBusyIndicatorProgress(current: processedPages, total: max(1, totalPages))
            }

            guard !isBatchJPEGExportCancellationRequested else { break }
            guard !imageURLs.isEmpty else {
                issues.append("\(fileInfo.url.lastPathComponent): no pages could be exported")
                continue
            }

            let rebuiltPDF = PDFDocument()
            var skippedImages = 0
            for imageURL in imageURLs.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                autoreleasepool {
                    if let image = NSImage(contentsOf: imageURL),
                       let page = PDFPage(image: image) {
                        rebuiltPDF.insert(page, at: rebuiltPDF.pageCount)
                    } else {
                        skippedImages += 1
                    }
                }
            }

            guard rebuiltPDF.pageCount > 0 else {
                issues.append("\(fileInfo.url.lastPathComponent): could not rebuild PDF")
                continue
            }

            let outputURL = uniqueFileURL(baseName: "\(baseName) - iPhone-iPad", extension: "pdf", in: outputFolder)
            if Self.writePDFDocument(rebuiltPDF, to: outputURL, pageLabels: [:]) {
                exportedFiles += 1
            } else {
                issues.append("\(fileInfo.url.lastPathComponent): could not write output PDF")
                continue
            }

            if !failedPages.isEmpty {
                let preview = failedPages.prefix(8).map(String.init).joined(separator: ", ")
                let suffix = failedPages.count > 8 ? ", …" : ""
                issues.append("\(fileInfo.url.lastPathComponent): failed page(s) \(preview)\(suffix)")
            }
            if skippedImages > 0 {
                issues.append("\(fileInfo.url.lastPathComponent): skipped \(skippedImages) exported image(s)")
            }
        }

        if isBatchJPEGExportCancellationRequested {
            let response = runAlert(
                title: "Batch Export Canceled",
                informativeText: "Created \(exportedFiles) PDF(s) in:\n\(outputFolder.path)",
                buttons: ["Reveal in Finder", "OK"],
                activateApp: true
            )
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([outputFolder])
            }
            return
        }

        let issueText: String
        if issues.isEmpty {
            issueText = ""
        } else {
            let preview = issues.prefix(10).joined(separator: "\n")
            let suffix = issues.count > 10 ? "\n…" : ""
            issueText = "\n\nIssues:\n\(preview)\(suffix)"
        }
        let response = runAlert(
            title: issues.isEmpty ? "Batch Export Complete" : "Batch Export Complete with Issues",
            informativeText: "Created \(exportedFiles) iPhone / iPad PDF(s) in:\n\(outputFolder.path)\(issueText)",
            style: issues.isEmpty ? .informational : .warning,
            buttons: ["Reveal in Finder", "OK"],
            activateApp: true
        )
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([outputFolder])
        }
    }

    @objc func exportPagesAsJPEG() {
        guard let document = pdfView.document else { beep(); return }
        guard let preset = jpegExportPresetSelection() else { return }

        let baseName = sanitizedFilename((openDocumentURL?.deletingPathExtension().lastPathComponent) ?? "Drawbridge Export")
        guard let exportDirectory = promptJPEGExportDestination(defaultFolderName: "\(baseName) - JPG Pages") else { return }

        let result = runJPEGExport(
            document: document,
            preset: preset,
            exportDirectory: exportDirectory,
            progressTitle: "Exporting JPEG Pages…"
        )
        if result.canceled {
            runAlert(
                title: "JPEG Export Canceled",
                informativeText: "Exported \(result.successCount) of \(document.pageCount) page(s) to:\n\(exportDirectory.path)"
            )
            return
        }

        if result.failedPages.isEmpty {
            runAlert(
                title: "JPEG Export Complete",
                informativeText: "Exported \(result.successCount) page(s) to:\n\(exportDirectory.path)"
            )
            return
        }

        let failurePreview = result.failedPages.prefix(12).map(String.init).joined(separator: ", ")
        let suffix = result.failedPages.count > 12 ? ", …" : ""
        runAlert(
            title: "JPEG Export Completed with Issues",
            informativeText: """
            Exported \(result.successCount) page(s) to:
            \(exportDirectory.path)

            Failed page(s): \(failurePreview)\(suffix)
            """,
            style: .warning
        )
    }

    @objc func batchExportPDFsAsJPEG() {
        guard let preset = jpegExportPresetSelection() else { return }

        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.pdf]
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.prompt = "Select"
        openPanel.message = "Select PDF files to batch export as JPG pages."
        guard openPanel.runModal() == .OK else { return }

        let selected = openPanel.urls
            .map { $0.standardizedFileURL }
            .filter { $0.pathExtension.lowercased() == "pdf" }
        guard guardOrBeep(!selected.isEmpty) else { return }

        let destinationPanel = NSOpenPanel()
        destinationPanel.canChooseFiles = false
        destinationPanel.canChooseDirectories = true
        destinationPanel.canCreateDirectories = true
        destinationPanel.allowsMultipleSelection = false
        destinationPanel.prompt = "Choose Folder"
        destinationPanel.message = "Select the destination root folder. One JPG folder will be created per PDF."
        guard destinationPanel.runModal() == .OK, let exportRoot = destinationPanel.url else { return }

        var filesWithPages: [(url: URL, document: PDFDocument, pageCount: Int)] = []
        var unreadableFiles: [String] = []
        for url in selected {
            guard let document = PDFDocument(url: url), document.pageCount > 0 else {
                unreadableFiles.append(url.lastPathComponent)
                continue
            }
            filesWithPages.append((url, document, document.pageCount))
        }

        guard !filesWithPages.isEmpty else {
            runAlert(
                title: "Batch Export Failed",
                informativeText: "None of the selected files could be opened as valid PDFs.",
                style: .warning
            )
            return
        }

        let totalPages = filesWithPages.reduce(0) { $0 + $1.pageCount }
        isBatchJPEGExportCancellationRequested = false
        beginBusyIndicator("Batch Exporting JPG Pages…", detail: "Preparing files…", lockInteraction: false)
        setBusyCancelAction({ [weak self] in
            guard let self else { return }
            self.isBatchJPEGExportCancellationRequested = true
            self.setBusyCancelAction(self.busyCancelHandler, title: "Canceling…", enabled: false)
            self.updateBusyIndicatorDetail("Stopping after current page…")
            self.updateBusyIndicatorSubdetail("")
        }, title: "Cancel Export")
        updateBusyIndicatorProgress(current: 0, total: max(1, totalPages))
        defer { endBusyIndicator() }

        let start = Date()
        var processedPages = 0
        var exportedPages = 0
        var exportedFiles = 0
        var fileIssues: [String] = []

        for (fileIndex, fileInfo) in filesWithPages.enumerated() {
            if isBatchJPEGExportCancellationRequested { break }
            let document = fileInfo.document

            let baseName = sanitizedFilename(fileInfo.url.deletingPathExtension().lastPathComponent)
            let exportFolder = uniqueSubdirectoryURL(baseName: "\(baseName) - JPG Pages", in: exportRoot)
            do {
                try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
            } catch {
                fileIssues.append("\(fileInfo.url.lastPathComponent): failed to create output folder")
                continue
            }

            var successForFile = 0
            var failedForFile = 0
            for pageIndex in 0..<document.pageCount {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
                if isBatchJPEGExportCancellationRequested { break }

                let page = document.page(at: pageIndex)
                let pageLabel = (page?.label).flatMap { $0.isEmpty ? nil : $0 } ?? "Page \(pageIndex + 1)"
                updateBusyIndicatorStatus("Batch Exporting JPG Pages…")
                updateBusyIndicatorDetail("File \(fileIndex + 1)/\(filesWithPages.count): \(fileInfo.url.lastPathComponent) • Page \(pageIndex + 1)/\(document.pageCount)")
                let elapsed = Date().timeIntervalSince(start)
                let avg = elapsed / Double(max(1, processedPages))
                let remaining = avg * Double(max(0, totalPages - processedPages))
                updateBusyIndicatorSubdetail("Exported \(processedPages)/\(totalPages) pages • ETA \(shortDuration(remaining))")
                updateBusyIndicatorProgress(current: processedPages, total: max(1, totalPages))

                var exportSucceeded = false
                if let page {
                    autoreleasepool {
                        guard let image = pageJPEGImage(page: page, dpi: preset.dpi) else { return }
                        let filename = String(format: "Page-%04d - %@.jpg", pageIndex + 1, sanitizedFilename(pageLabel))
                        let destination = exportFolder.appendingPathComponent(filename)
                        guard let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
                        let options = [kCGImageDestinationLossyCompressionQuality: preset.compressionQuality] as CFDictionary
                        CGImageDestinationAddImage(destinationRef, image, options)
                        exportSucceeded = CGImageDestinationFinalize(destinationRef)
                    }
                }

                if exportSucceeded {
                    successForFile += 1
                    exportedPages += 1
                } else {
                    failedForFile += 1
                }
                processedPages += 1
            }

            if successForFile > 0 {
                exportedFiles += 1
            }
            if failedForFile > 0 {
                fileIssues.append("\(fileInfo.url.lastPathComponent): failed \(failedForFile) page(s)")
            }
        }

        if isBatchJPEGExportCancellationRequested {
            runAlert(
                title: "Batch JPG Export Canceled",
                informativeText: "Exported \(exportedPages) page(s) across \(exportedFiles) PDF(s) to:\n\(exportRoot.path)"
            )
            return
        }

        if !unreadableFiles.isEmpty {
            let preview = unreadableFiles.prefix(8).joined(separator: ", ")
            let suffix = unreadableFiles.count > 8 ? ", …" : ""
            fileIssues.append("Unreadable PDF(s): \(preview)\(suffix)")
        }

        if fileIssues.isEmpty {
            runAlert(
                title: "Batch JPG Export Complete",
                informativeText: "Exported \(exportedPages) page(s) from \(exportedFiles) PDF(s) to:\n\(exportRoot.path)"
            )
            return
        }

        let preview = fileIssues.prefix(8).joined(separator: "\n")
        let suffix = fileIssues.count > 8 ? "\n…" : ""
        runAlert(
            title: "Batch JPG Export Complete with Issues",
            informativeText: """
            Exported \(exportedPages) page(s) from \(exportedFiles) PDF(s) to:
            \(exportRoot.path)

            \(preview)\(suffix)
            """,
            style: .warning
        )
    }


    func restoreSourcePageGeometryIfNeeded(to document: PDFDocument) {
        guard !displayPageGeometryOverrides.isEmpty else { return }
        for (pageIndex, geometry) in displayPageGeometryOverrides {
            guard pageIndex >= 0,
                  pageIndex < document.pageCount,
                  let page = document.page(at: pageIndex) else { continue }
            geometry.apply(to: page)
        }
    }

    func reapplyDisplayPageGeometryOverridesIfNeeded(to document: PDFDocument? = nil) {
        guard !displayPageGeometryOverrides.isEmpty else { return }
        let targetDocument = document ?? pdfView.document
        guard let targetDocument else { return }
        for pageIndex in displayPageGeometryOverrides.keys {
            guard pageIndex >= 0,
                  pageIndex < targetDocument.pageCount,
                  let page = targetDocument.page(at: pageIndex),
                  shouldDisplayPageWithNativeGeometry(page) else { continue }
            applyNativeLandscapeDisplayGeometry(to: page)
        }
    }

    private func applyReadablePageDisplayGeometryIfNeeded(to document: PDFDocument) {
        displayPageGeometryOverrides.removeAll(keepingCapacity: false)
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex),
                  shouldDisplayPageWithNativeGeometry(page) else { continue }
            displayPageGeometryOverrides[pageIndex] = PDFPageStoredGeometry(page: page)
            applyNativeLandscapeDisplayGeometry(to: page)
        }
    }

    private func shouldDisplayPageWithNativeGeometry(_ page: PDFPage) -> Bool {
        let rotation = ((page.rotation % 360) + 360) % 360
        guard rotation == 90 || rotation == 270 else { return false }
        let bounds = page.bounds(for: .cropBox).standardized
        guard bounds.height > bounds.width * 1.1 else { return false }
        return pageHasMostlyHorizontalNativeText(page, in: bounds)
    }

    private func pageHasMostlyHorizontalNativeText(_ page: PDFPage, in bounds: NSRect) -> Bool {
        guard let selection = page.selection(for: bounds) else { return false }
        var horizontalLines = 0
        var verticalLines = 0
        var sampledLines = 0
        for line in selection.selectionsByLine().prefix(120) {
            let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 3 else { continue }
            let lineBounds = line.bounds(for: page).standardized
            guard lineBounds.width > 2, lineBounds.height > 2 else { continue }
            sampledLines += 1
            if lineBounds.width > lineBounds.height * 2.2 {
                horizontalLines += 1
            } else if lineBounds.height > lineBounds.width * 2.2 {
                verticalLines += 1
            }
        }
        guard sampledLines >= 3 else { return false }
        let minimumHorizontalLines = sampledLines < 8 ? 3 : 8
        return horizontalLines >= minimumHorizontalLines && horizontalLines > verticalLines * 2
    }

    private func applyNativeLandscapeDisplayGeometry(to page: PDFPage) {
        func swapped(_ rect: NSRect) -> NSRect {
            NSRect(x: rect.origin.x, y: rect.origin.y, width: rect.height, height: rect.width)
        }
        let mediaBox = page.bounds(for: .mediaBox)
        let cropBox = page.bounds(for: .cropBox)
        let bleedBox = page.bounds(for: .bleedBox)
        let trimBox = page.bounds(for: .trimBox)
        let artBox = page.bounds(for: .artBox)
        page.rotation = 0
        page.setBounds(swapped(mediaBox), for: .mediaBox)
        page.setBounds(swapped(cropBox), for: .cropBox)
        page.setBounds(swapped(bleedBox), for: .bleedBox)
        page.setBounds(swapped(trimBox), for: .trimBox)
        page.setBounds(swapped(artBox), for: .artBox)
    }

    func openDocument(at url: URL) {
        let openSpan = PerformanceMetrics.begin(
            "open_document",
            thresholdMs: 250,
            fields: ["file": url.lastPathComponent]
        )
        cancelAutoNameCapture()
        beginBusyIndicator("Loading PDF…")
        defer { endBusyIndicator() }
        guard let document = PDFDocument(url: url) else {
            PerformanceMetrics.end(openSpan, extra: ["result": "invalid_pdf"])
            runAlert(
                title: "Unable to open PDF",
                informativeText: "\(url.lastPathComponent) is not a valid PDF.",
                style: .critical
            )
            return
        }
        applyReadablePageDisplayGeometryIfNeeded(to: document)
        pdfView.document = document
        clearMarkupCache()
        pageScaleLocks.removeAll(keepingCapacity: false)
        lastScaleLockAppliedPageIndex = -1
        lastExplicitScaleSetDocumentID = nil
        lastExplicitScaleSetPageIndex = -1
        explicitScaleSetDocumentID = nil
        explicitScaleSetPageIndexes.removeAll(keepingCapacity: false)
        pendingScaleReminderSuppressionDocumentID = nil
        pendingScaleReminderSuppressionPageIndex = -1
        pendingScaleReminderSuppressionOneShot = false
        pageLabelOverrides.removeAll()
        hasPromptedForInitialMarkupSaveCopy = false
        isPresentingInitialMarkupSaveCopyPrompt = false
        let annotationOptimization = optimizeDocumentAnnotationsIfNeeded(in: document)
        loadSidecarSnapshotIfAvailable(for: url, document: document)
        applySnapshotLayerVisibility()
        openDocumentURL = url
        registerSessionDocument(url)
        configureAutosaveURL(for: url)
        resetSearchState(clearQuery: false)
        refreshSearchIfNeeded()
        if let snapshot = loadMarkupIndexSnapshot(for: url), snapshot.pageCount == document.pageCount {
            markupsCountLabel.stringValue = "Indexed \(snapshot.totalAnnotations) (refreshing…)"
        }
        view.window?.title = "Drawbridge - \(url.lastPathComponent)"
        view.window?.makeFirstResponder(pdfView)
        markDocumentClean(updateStatusBarValue: false)
        refreshMarkups()
        updateEmptyStateVisibility()
        requestChromeRefresh()
        onDocumentOpened?(url)
        PerformanceMetrics.end(
            openSpan,
            extra: [
                "result": "ok",
                "pages": "\(document.pageCount)",
                "cached_markups": "\(totalCachedAnnotationCount())",
                "rehydrated_images": "\(annotationOptimization.rehydratedImages)",
                "rehydrated_snapshots": "\(annotationOptimization.rehydratedSnapshots)",
                "normalized_fonts": "\(annotationOptimization.normalizedFonts)",
                "repaired_ink_paths": "\(annotationOptimization.repairedInkPaths)"
            ]
        )
    }

    private func optimizeDocumentAnnotationsIfNeeded(in document: PDFDocument) -> (
        rehydratedImages: Int,
        rehydratedSnapshots: Int,
        normalizedFonts: Int,
        repairedInkPaths: Int
    ) {
        var rehydratedImages = 0
        var rehydratedSnapshots = 0
        var normalizedFonts = 0
        var repairedInkPaths = 0
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for original in page.annotations {
                var annotation = original
                if let contents = original.contents {
                    if !(original is ImageMarkupAnnotation),
                       contents.hasPrefix(ImageMarkupAnnotation.contentsPrefix) {
                        let replacement = ImageMarkupAnnotation(
                            bounds: original.bounds,
                            imageURL: URL(fileURLWithPath: String(contents.dropFirst(ImageMarkupAnnotation.contentsPrefix.count))),
                            contents: contents
                        )
                        replacement.border = original.border
                        replacement.color = original.color
                        replacement.shouldDisplay = original.shouldDisplay
                        replacement.shouldPrint = original.shouldPrint
                        page.removeAnnotation(original)
                        page.addAnnotation(replacement)
                        annotation = replacement
                        rehydratedImages += 1
                    } else if !(original is PDFSnapshotAnnotation),
                              contents.hasPrefix(PDFSnapshotAnnotation.contentsPrefix) {
                        let replacement = PDFSnapshotAnnotation(
                            bounds: original.bounds,
                            snapshotURL: URL(fileURLWithPath: String(contents.dropFirst(PDFSnapshotAnnotation.contentsPrefix.count))),
                            contents: contents
                        )
                        replacement.border = original.border
                        replacement.color = original.color
                        replacement.shouldDisplay = original.shouldDisplay
                        replacement.shouldPrint = original.shouldPrint
                        page.removeAnnotation(original)
                        page.addAnnotation(replacement)
                        annotation = replacement
                        rehydratedSnapshots += 1
                    }
                }

                let type = (annotation.type ?? "").lowercased()
                if type.contains("link") || annotation.destination != nil || annotation.action != nil {
                    if let border = annotation.border, border.lineWidth > 0 {
                        border.lineWidth = 0
                        annotation.border = border
                    }
                }
                if type.contains("freetext") {
                    let size = max(6.0, annotation.font?.pointSize ?? 15.0)
                    let currentName = annotation.font?.fontName ?? ""
                    let currentSize = annotation.font?.pointSize ?? -1
                    if abs(currentSize - size) > 0.01 || !currentName.contains("SF") {
                        annotation.font = resolveFont(family: "San Francisco", size: size)
                        normalizedFonts += 1
                    }
                    // Legacy cleanup: older builds stored textbox background in interiorColor.
                    // Current rendering uses color, so normalize to avoid black-filled boxes.
                    if let legacyBackground = annotation.interiorColor {
                        annotation.color = legacyBackground
                        annotation.interiorColor = nil
                        normalizedFonts += 1
                    }
                }
                if type.contains("ink"),
                   let target = annotation.border?.lineWidth,
                   target > 0,
                   let paths = annotation.paths,
                   !paths.isEmpty {
                    for path in paths where abs(path.lineWidth - target) > 0.01 {
                        path.lineWidth = target
                        repairedInkPaths += 1
                    }
                }
            }
        }
        return (rehydratedImages, rehydratedSnapshots, normalizedFonts, repairedInkPaths)
    }

    private func presentDroppedImageScaleDialog(page: PDFPage, annotation: PDFAnnotation, baseBounds: NSRect) {
        let alert = NSAlert()
        alert.messageText = "Scale Image"
        alert.informativeText = "Set inserted image size."
        alert.alertStyle = .informational

        let presetPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 140, height: 24), pullsDown: false)
        presetPopup.addItems(withTitles: ["50%", "75%", "100%", "125%", "150%", "200%", "Custom"])
        presetPopup.selectItem(withTitle: "100%")
        presetPopup.controlSize = .regular

        let customField = NSTextField(frame: NSRect(x: 0, y: 0, width: 96, height: 24))
        customField.placeholderString = "100"
        customField.stringValue = "100"
        customField.alignment = .right
        customField.controlSize = .regular
        customField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        customField.translatesAutoresizingMaskIntoConstraints = false
        customField.widthAnchor.constraint(equalToConstant: 96).isActive = true

        presetPopup.target = self
        presetPopup.action = #selector(imageScalePresetChanged(_:))
        presetPopup.identifier = NSUserInterfaceItemIdentifier("image-scale-preset")
        customField.identifier = NSUserInterfaceItemIdentifier("image-scale-custom")

        let row = NSStackView(views: [
            NSTextField(labelWithString: "Scale:"),
            presetPopup,
            customField,
            NSTextField(labelWithString: "%")
        ])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        alert.accessoryView = row
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Keep")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let fallbackFromPreset: Double = Double((presetPopup.titleOfSelectedItem ?? "100%").replacingOccurrences(of: "%", with: "")) ?? 100
        let typedPercent = customField.doubleValue > 0 ? customField.doubleValue : fallbackFromPreset
        let percent = max(5, CGFloat(typedPercent))

        let factor = percent / 100.0
        let center = NSPoint(x: baseBounds.midX, y: baseBounds.midY)
        var newBounds = NSRect(
            x: center.x - (baseBounds.width * factor) * 0.5,
            y: center.y - (baseBounds.height * factor) * 0.5,
            width: baseBounds.width * factor,
            height: baseBounds.height * factor
        )
        let pageBounds = page.bounds(for: pdfView.displayBox)
        if newBounds.minX < pageBounds.minX { newBounds.origin.x = pageBounds.minX }
        if newBounds.maxX > pageBounds.maxX { newBounds.origin.x = pageBounds.maxX - newBounds.width }
        if newBounds.minY < pageBounds.minY { newBounds.origin.y = pageBounds.minY }
        if newBounds.maxY > pageBounds.maxY { newBounds.origin.y = pageBounds.maxY - newBounds.height }
        let before = snapshot(for: annotation)
        annotation.bounds = newBounds
        markPageMarkupCacheDirty(page)
        registerAnnotationStateUndo(annotation: annotation, previous: before, actionName: "Scale Image")
        commitMarkupMutation(selecting: annotation)
    }

    @objc private func imageScalePresetChanged(_ sender: NSPopUpButton) {
        guard let row = sender.superview as? NSStackView else { return }
        guard let customField = row.arrangedSubviews.first(where: { $0.identifier == NSUserInterfaceItemIdentifier("image-scale-custom") }) as? NSTextField else {
            return
        }
        guard let selected = sender.titleOfSelectedItem else { return }
        if selected == "Custom" {
            return
        }
        customField.stringValue = selected.replacingOccurrences(of: "%", with: "")
    }

    func registerSessionDocument(_ url: URL) {
        let normalized = canonicalDocumentURL(url)
        sessionDocumentURLs.removeAll { canonicalDocumentURL($0) == normalized }
        sessionDocumentURLs.append(normalized)
        refreshDocumentTabs()
    }

    func unregisterSessionDocument(_ url: URL) {
        let normalized = canonicalDocumentURL(url)
        sessionDocumentURLs.removeAll { canonicalDocumentURL($0) == normalized }
        refreshDocumentTabs()
    }

    func canonicalDocumentURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    func clearToStartState() {
        cancelAutoNameCapture()
        pdfView.document = nil
        clearMarkupCache()
        pageScaleLocks.removeAll(keepingCapacity: false)
        lastScaleLockAppliedPageIndex = -1
        lastExplicitScaleSetDocumentID = nil
        lastExplicitScaleSetPageIndex = -1
        explicitScaleSetDocumentID = nil
        explicitScaleSetPageIndexes.removeAll(keepingCapacity: false)
        pendingScaleReminderSuppressionDocumentID = nil
        pendingScaleReminderSuppressionPageIndex = -1
        pendingScaleReminderSuppressionOneShot = false
        pageLabelOverrides.removeAll()
        flattenedPDFItems.removeAll(keepingCapacity: false)
        openDocumentURL = nil
        hasPromptedForInitialMarkupSaveCopy = true
        isPresentingInitialMarkupSaveCopyPrompt = false
        pendingCalibrationDistanceInPoints = nil
        persistenceCoordinator.resetState()
        pendingMarkupsRefreshWorkItem?.cancel()
        pendingMarkupsRefreshWorkItem = nil
        pendingSearchWorkItem?.cancel()
        pendingSearchWorkItem = nil
        autosaveURL = nil
        markDocumentClean(updateStatusBarValue: false)
        markupsTable.deselectAll(nil)
        clearSelectionOverlayLayers()
        refreshMarkups()
        resetSearchState(clearQuery: true)
        view.window?.title = "Drawbridge"
        updateEmptyStateVisibility()
        requestChromeRefresh(immediate: true)
        refreshDocumentTabs()
    }

    private func startMarkupsRefreshTimer() {
        markupsTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.markupsRefreshTick()
            }
        }
    }

    @objc private func markupsRefreshTick() {
        if isSavingDocumentOperation { return }
        updateStatusBar()
    }


    private func markupIndexSnapshotsDirectoryURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport
            .appendingPathComponent("Drawbridge")
            .appendingPathComponent("MarkupIndexSnapshots")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    private func markupIndexSnapshotDocumentKey(for sourceURL: URL?) -> String {
        let raw = sourceURL?.standardizedFileURL.path ?? "Untitled"
        let b64 = Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return b64.isEmpty ? "untitled" : b64
    }

    private func markupIndexSnapshotURL(for sourceURL: URL?) -> URL? {
        guard let dir = markupIndexSnapshotsDirectoryURL() else { return nil }
        let key = markupIndexSnapshotDocumentKey(for: sourceURL)
        return dir.appendingPathComponent("\(key).json")
    }

    private func loadMarkupIndexSnapshot(for sourceURL: URL?) -> MarkupIndexSnapshot? {
        guard let fileURL = markupIndexSnapshotURL(for: sourceURL),
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MarkupIndexSnapshot.self, from: data)
    }

    private func persistMarkupIndexSnapshot(document _: PDFDocument) {
        return
    }

    private var isSidecarAutosaveMode: Bool {
        false
    }

    private func jumpToSelectedMarkup() {
        let row = markupsTable.selectedRow
        guard row >= 0, row < markupItems.count else { return }

        let item = markupItems[row]
        guard let page = pdfView.document?.page(at: item.pageIndex) else { return }

        let destination = PDFDestination(page: page, at: NSPoint(x: item.annotation.bounds.minX, y: item.annotation.bounds.maxY))
        pdfView.navigateToDestinationWithHistory(destination)
        updateSelectionOverlay()
    }


    func currentSelectedAnnotation() -> PDFAnnotation? {
        currentSelectedMarkupItem()?.annotation
    }

    private func restoreSelection(for annotation: PDFAnnotation?) {
        guard let annotation else {
            clearMarkupTableSelectionUI(updateStatusBarValue: false)
            return
        }
        guard let row = markupItems.firstIndex(where: { $0.annotation === annotation }) else {
            clearMarkupTableSelectionUI(updateStatusBarValue: false)
            return
        }
        applyMarkupTableSelectionRows(IndexSet(integer: row), updateStatusBarValue: false)
    }

    private func clearSelectionOverlayLayers() {
        selectedMarkupOverlayLayer.isHidden = true
        selectedMarkupOverlayLayer.path = nil
        selectedTextOverlayLayer.isHidden = true
        selectedTextOverlayLayer.path = nil
        selectedLineEndpointHaloLayer.isHidden = true
        selectedLineEndpointHaloLayer.path = nil
        selectedLineEndpointOverlayLayer.isHidden = true
        selectedLineEndpointOverlayLayer.path = nil
    }

    func clearMarkupTableSelectionUI(updateStatusBarValue: Bool = true) {
        markupsTable.deselectAll(nil)
        clearSelectionOverlayLayers()
        updateToolSettingsUIForCurrentTool()
        if updateStatusBarValue {
            updateStatusBar()
        }
    }

    func applyMarkupTableSelectionRows(_ rows: IndexSet, updateStatusBarValue: Bool = true) {
        markupsTable.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first {
            markupsTable.scrollRowToVisible(first)
        }
        updateSelectionOverlay()
        updateToolSettingsUIForCurrentTool()
        if updateStatusBarValue {
            updateStatusBar()
        }
    }

    func updateSelectionOverlay() {
        let selectedItems = currentSelectedMarkupItems()
        guard !selectedItems.isEmpty else {
            if isPolygonVertexEditModeEnabled {
                setPolygonVertexEditMode(false)
            }
            clearSelectionOverlayLayers()
            return
        }
        if isPolygonVertexEditModeEnabled && !hasEditablePolygonSelection() {
            setPolygonVertexEditMode(false)
        }

        let genericPath = CGMutablePath()
        let textPath = CGMutablePath()
        let lineEndpointHaloPath = CGMutablePath()
        let lineEndpointPath = CGMutablePath()
        var addedGeneric = false
        var addedText = false
        var addedLineEndpoints = false
        for item in selectedItems {
            guard let page = pdfView.document?.page(at: item.pageIndex) else { continue }
            let bounds = item.annotation.bounds
            let p1 = pdfView.convert(bounds.origin, from: page)
            let p2 = pdfView.convert(NSPoint(x: bounds.maxX, y: bounds.maxY), from: page)
            let annotationType = (item.annotation.type ?? "").lowercased()
            let isFreeText = annotationType.contains("freetext")
            let overlayInset: CGFloat = isFreeText ? -4 : (annotationType.contains("ink") ? -1 : -3)
            let rect = NSRect(
                x: min(p1.x, p2.x),
                y: min(p1.y, p2.y),
                width: abs(p2.x - p1.x),
                height: abs(p2.y - p1.y)
            ).insetBy(dx: overlayInset, dy: overlayInset)

            guard rect.width > 2, rect.height > 2 else { continue }
            if isFreeText {
                addedText = true
                textPath.addRoundedRect(in: rect, cornerWidth: 6, cornerHeight: 6)
            } else {
                addedGeneric = true
                genericPath.addRoundedRect(in: rect, cornerWidth: 4, cornerHeight: 4)
            }

            if let segment = lineSegmentInPageForOverlay(item.annotation) {
                let haloSize: CGFloat = 15
                let coreSize: CGFloat = 10
                let startInView = pdfView.convert(segment.0, from: page)
                let endInView = pdfView.convert(segment.1, from: page)
                let haloHandles = [
                    NSRect(x: startInView.x - haloSize * 0.5, y: startInView.y - haloSize * 0.5, width: haloSize, height: haloSize),
                    NSRect(x: endInView.x - haloSize * 0.5, y: endInView.y - haloSize * 0.5, width: haloSize, height: haloSize)
                ]
                let coreHandles = [
                    NSRect(x: startInView.x - coreSize * 0.5, y: startInView.y - coreSize * 0.5, width: coreSize, height: coreSize),
                    NSRect(x: endInView.x - coreSize * 0.5, y: endInView.y - coreSize * 0.5, width: coreSize, height: coreSize)
                ]
                for h in haloHandles {
                    lineEndpointHaloPath.addEllipse(in: h)
                }
                for h in coreHandles {
                    lineEndpointPath.addEllipse(in: h)
                }
                addedLineEndpoints = true
            } else if let vertices = pdfView.polygonVerticesInPage(for: item.annotation), vertices.count >= 3 {
                let haloSize: CGFloat = 14
                let coreSize: CGFloat = 9
                for vertex in vertices {
                    let point = pdfView.convert(vertex, from: page)
                    let halo = NSRect(x: point.x - haloSize * 0.5, y: point.y - haloSize * 0.5, width: haloSize, height: haloSize)
                    let core = NSRect(x: point.x - coreSize * 0.5, y: point.y - coreSize * 0.5, width: coreSize, height: coreSize)
                    lineEndpointHaloPath.addEllipse(in: halo)
                    lineEndpointPath.addEllipse(in: core)
                }
                addedLineEndpoints = true
            } else {
                let handleSize: CGFloat = isFreeText ? 8 : 6
                let handles = [
                    NSRect(x: rect.minX - handleSize * 0.5, y: rect.minY - handleSize * 0.5, width: handleSize, height: handleSize),
                    NSRect(x: rect.maxX - handleSize * 0.5, y: rect.minY - handleSize * 0.5, width: handleSize, height: handleSize),
                    NSRect(x: rect.minX - handleSize * 0.5, y: rect.maxY - handleSize * 0.5, width: handleSize, height: handleSize),
                    NSRect(x: rect.maxX - handleSize * 0.5, y: rect.maxY - handleSize * 0.5, width: handleSize, height: handleSize)
                ]
                for h in handles {
                    if isFreeText {
                        textPath.addEllipse(in: h)
                    } else {
                        genericPath.addRect(h)
                    }
                }
            }
        }

        selectedMarkupOverlayLayer.path = genericPath
        selectedMarkupOverlayLayer.isHidden = !addedGeneric
        selectedTextOverlayLayer.path = textPath
        selectedTextOverlayLayer.isHidden = !addedText
        selectedLineEndpointHaloLayer.path = lineEndpointHaloPath
        selectedLineEndpointHaloLayer.isHidden = !addedLineEndpoints
        selectedLineEndpointOverlayLayer.path = lineEndpointPath
        selectedLineEndpointOverlayLayer.isHidden = !addedLineEndpoints
    }

    private func lineSegmentInPageForOverlay(_ annotation: PDFAnnotation) -> (NSPoint, NSPoint)? {
        guard let (first, last) = pdfView.primaryLineSegmentInPage(for: annotation) else { return nil }
        if hypot(last.x - first.x, last.y - first.y) <= 0.01 {
            return nil
        }
        return (first, last)
    }

    private func selectMarkupsFromFence(
        page: PDFPage,
        annotations: [PDFAnnotation],
        enablesGroupedDrag: Bool = false,
        refreshBeforeSelecting: Bool = true
    ) {
        guard let document = pdfView.document else { return }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return }

        var selected = Set(annotations.map(ObjectIdentifier.init))
        for annotation in annotations {
            for sibling in relatedCalloutAnnotations(for: annotation, on: page) {
                selected.insert(ObjectIdentifier(sibling))
            }
        }
        if refreshBeforeSelecting {
            performRefreshMarkups(selecting: nil)
        }
        let rows = IndexSet(markupItems.enumerated().compactMap { idx, item in
            guard item.pageIndex == pageIndex else { return nil }
            return selected.contains(ObjectIdentifier(item.annotation)) ? idx : nil
        })
        if rows.isEmpty {
            clearGroupedPasteDragSelection()
            clearMarkupTableSelectionUI(updateStatusBarValue: false)
            return
        }
        if enablesGroupedDrag {
            groupedPasteDragPageID = ObjectIdentifier(page)
            groupedPasteDragAnnotationIDs = selected
        } else {
            clearGroupedPasteDragSelection()
        }
        applyMarkupTableSelectionRows(rows)
    }

    private func clearGroupedPasteDragSelection() {
        groupedPasteDragPageID = nil
        groupedPasteDragAnnotationIDs.removeAll(keepingCapacity: false)
    }

    private func shouldDragAsGroupedPasteSelection(on page: PDFPage, selectedSet: Set<ObjectIdentifier>, anchor: PDFAnnotation) -> Bool {
        let anchorID = ObjectIdentifier(anchor)
        return MarkupInteractionPolicy.shouldDragGroupedPasteSelection(
            selectedAnnotationIDs: selectedSet,
            anchorAnnotationID: anchorID,
            currentPageID: ObjectIdentifier(page),
            groupedPastePageID: groupedPasteDragPageID,
            groupedPasteAnnotationIDs: groupedPasteDragAnnotationIDs
        )
    }




    func updateMeasurementSummary() {
        guard let document = pdfView.document else {
            measurementCountLabel.stringValue = "Measurements: 0"
            measurementTotalLabel.stringValue = "Total Length: 0 \(pdfView.measurementUnitLabel)"
            return
        }

        let docID = ObjectIdentifier(document)
        if cachedMarkupDocumentID == docID,
           dirtyMarkupPageIndexes.isEmpty,
           measurementSummaryByPage.count == document.pageCount {
            let totalInDisplayUnits = cachedMeasurementTotalPoints * pdfView.measurementUnitsPerPoint
            measurementCountLabel.stringValue = "Measurements: \(cachedMeasurementCount)"
            measurementTotalLabel.stringValue = String(
                format: "Total Length: %.2f %@",
                totalInDisplayUnits,
                pdfView.measurementUnitLabel
            )
            return
        }

        var summaries: [Int: (count: Int, totalPoints: CGFloat)] = [:]
        summaries.reserveCapacity(document.pageCount)
        var totalCount = 0
        var totalPoints: CGFloat = 0
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                summaries[pageIndex] = (0, 0)
                continue
            }
            let summary = measurementSummary(for: page.annotations.filter { !pdfView.isHatchOverlayAnnotation($0) })
            summaries[pageIndex] = summary
            totalCount += summary.count
            totalPoints += summary.totalPoints
        }

        measurementSummaryByPage = summaries
        cachedMeasurementCount = totalCount
        cachedMeasurementTotalPoints = totalPoints

        let totalInDisplayUnits = totalPoints * pdfView.measurementUnitsPerPoint
        measurementCountLabel.stringValue = "Measurements: \(totalCount)"
        measurementTotalLabel.stringValue = String(format: "Total Length: %.2f %@", totalInDisplayUnits, pdfView.measurementUnitLabel)
    }

    func updateStatusBar() {
        statusToolLabel.stringValue = "Tool: \(currentToolName())"
        applyScaleLockForCurrentPageIfNeeded()

        if let document = pdfView.document,
           let page = pdfView.currentPage {
            let index = document.index(for: page)
            let label = displayPageLabel(forPageIndex: index)
            statusPageSizeLabel.stringValue = "Size: \(formattedPageSize(for: page))"
            statusPageLabel.stringValue = "Page: \(label)"
            pageJumpField.stringValue = label
            if sidebarCurrentPageIndex != index {
                sidebarCurrentPageIndex = index
                pagesTableView.reloadData()
                bookmarksOutlineView.reloadData()
                if navigationModeControl.selectedSegment == 0, pagesTableView.numberOfRows > index {
                    pagesTableView.scrollRowToVisible(index)
                }
            }
            pageJumpField.isEnabled = false
            autoNameSheetsButton.isEnabled = true
            batchLinkSheetsButton.isEnabled = true
        } else {
            statusPageSizeLabel.stringValue = "Size: -"
            statusPageLabel.stringValue = "Page: -"
            pageJumpField.stringValue = ""
            if sidebarCurrentPageIndex != -1 {
                sidebarCurrentPageIndex = -1
                pagesTableView.reloadData()
                bookmarksOutlineView.reloadData()
            }
            pagesTableView.deselectAll(nil)
            pageJumpField.isEnabled = false
            autoNameSheetsButton.isEnabled = false
            batchLinkSheetsButton.isEnabled = false
        }

        let zoomPercent = Int(round(pdfView.scaleFactor * 100))
        statusZoomLabel.stringValue = "Zoom: \(zoomPercent)%"
        let scaleText = measurementScaleField.stringValue.isEmpty ? "1.0" : measurementScaleField.stringValue
        let unit = measurementUnitPopup.titleOfSelectedItem ?? pdfView.measurementUnitLabel
        let lockedSuffix: String
        if let document = pdfView.document,
           let page = pdfView.currentPage,
           pageScaleLocks[document.index(for: page)] != nil {
            lockedSuffix = " [Locked]"
        } else {
            lockedSuffix = ""
        }
        statusScaleLabel.stringValue = "Scale: \(scaleText) \(unit)\(lockedSuffix)"
    }

    func currentToolName() -> String {
        if pdfView.toolMode == .select, isPolygonVertexEditModeEnabled {
            return "Selection (Vertex Edit)"
        }
        return pdfView.toolMode.statusDisplayName
    }

    private func segmentIndex(for mode: ToolMode) -> Int {
        mode.primaryToolbarSegmentIndex ?? -1
    }

    private func takeoffSegmentIndex(for mode: ToolMode) -> Int {
        mode.takeoffToolbarSegmentIndex ?? -1
    }

    private func isDrawingScaleConfigured() -> Bool {
        guard pdfView.document != nil, pdfView.currentPage != nil else {
            return true
        }
        return hasScaleLockForCurrentPage()
    }

    private func hasScaleLockForCurrentPage() -> Bool {
        guard let document = pdfView.document,
              let pageIndex = currentPageIndexForScaleContext(in: document) else {
            return false
        }
        return pageScaleLocks[pageIndex] != nil
    }

    private func shouldWarnAboutMissingScaleForCurrentPage() -> Bool {
        guard let document = pdfView.document,
              let pageIndex = currentPageIndexForScaleContext(in: document) else {
            return false
        }
        if explicitScaleSetDocumentID == ObjectIdentifier(document),
           explicitScaleSetPageIndexes.contains(pageIndex) {
            return false
        }
        if isScalePresetControlConfiguredForCurrentPage() {
            return false
        }
        if pageIndex >= 0,
           lastExplicitScaleSetDocumentID == ObjectIdentifier(document),
           lastExplicitScaleSetPageIndex == pageIndex {
            return false
        }
        return !hasScaleLockForCurrentPage()
    }

    private func consumePendingScaleReminderSuppressionForCurrentPage() -> Bool {
        if pendingScaleReminderSuppressionOneShot {
            pendingScaleReminderSuppressionOneShot = false
            return true
        }
        guard let document = pdfView.document,
              let pageIndex = currentPageIndexForScaleContext(in: document) else {
            return false
        }
        if pendingScaleReminderSuppressionDocumentID == ObjectIdentifier(document),
           pendingScaleReminderSuppressionPageIndex == pageIndex {
            pendingScaleReminderSuppressionDocumentID = nil
            pendingScaleReminderSuppressionPageIndex = -1
            return true
        }
        return false
    }

    func currentPageIndexForScaleContext(in document: PDFDocument) -> Int? {
        if let page = pdfView.currentPage {
            let current = document.index(for: page)
            if current >= 0 {
                return current
            }
        }
        if sidebarCurrentPageIndex >= 0, sidebarCurrentPageIndex < document.pageCount {
            return sidebarCurrentPageIndex
        }
        return nil
    }

    private func isScalePresetControlConfiguredForCurrentPage() -> Bool {
        let title = (scalePresetPopup.titleOfSelectedItem ?? scalePresetPopup.title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        return title != "Scale: Not Set"
    }

    private func showAreaScaleRequiredWarning() {
        runAlert(
            title: "Set Drawing Scale First",
            informativeText: "Area takeoff requires a drawing scale. Set scale before using the Area tool.",
            style: .warning
        )
    }

    func displayPageLabel(forPageIndex pageIndex: Int) -> String {
        if let override = pageLabelOverrides[pageIndex],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override
        }
        guard let doc = pdfView.document else { return "\(pageIndex + 1)" }
        guard let page = doc.page(at: pageIndex) else { return "\(pageIndex + 1)" }
        let label = page.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? "\(pageIndex + 1)" : label
    }

    func applyPageLabelOverridesToDocumentIfNeeded(_ document: PDFDocument) {
        guard !pageLabelOverrides.isEmpty else { return }
        let setLabelSelector = NSSelectorFromString("setLabel:")
        for (pageIndex, rawLabel) in pageLabelOverrides {
            guard pageIndex >= 0, pageIndex < document.pageCount else { continue }
            let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, let page = document.page(at: pageIndex) else { continue }
            if page.responds(to: setLabelSelector) {
                _ = page.perform(setLabelSelector, with: label)
            }
        }
    }

    func embeddedPageLabelsForSave(in document: PDFDocument) -> [Int: String] {
        var labels: [Int: String] = [:]
        labels.reserveCapacity(document.pageCount)
        for pageIndex in 0..<document.pageCount {
            let label = displayPageLabel(forPageIndex: pageIndex).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label != "\(pageIndex + 1)" else { continue }
            labels[pageIndex] = label
        }
        return labels
    }

    private func formattedPageSize(for page: PDFPage) -> String {
        let bounds = page.bounds(for: .mediaBox)
        let widthInches = max(0, bounds.width) / 72.0
        let heightInches = max(0, bounds.height) / 72.0
        return "\(formatInches(heightInches)) H x \(formatInches(widthInches)) W"
    }

    private func formatInches(_ value: CGFloat) -> String {
        let rounded = (value * 100).rounded() / 100
        if abs(rounded - rounded.rounded()) < 0.01 {
            return String(format: "%.0f\"", rounded)
        }
        return String(format: "%.2f\"", rounded)
    }

    func sidebarPageCount() -> Int {
        pdfView.document?.pageCount ?? 0
    }

    func sidebarPageLabel(at index: Int) -> String? {
        guard index >= 0, index < sidebarPageCount() else { return nil }
        return displayPageLabel(forPageIndex: index)
    }

    func isSidebarCurrentPage(_ index: Int) -> Bool {
        index == sidebarCurrentPageIndex
    }

    private func displayBookmarkTitle(for outline: PDFOutline) -> String {
        let key = bookmarkKey(for: outline)
        if let override = bookmarkLabelOverrides[key], !override.isEmpty {
            return override
        }
        let title = outline.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title! : "(Untitled)"
    }

    private func bookmarkKey(for outline: PDFOutline) -> String {
        var parts: [String] = []
        var current: PDFOutline? = outline
        while let node = current {
            if let parent = node.parent {
                var index = 0
                for i in 0..<parent.numberOfChildren {
                    if parent.child(at: i) === node {
                        index = i
                        break
                    }
                }
                parts.append(String(index))
                current = parent
            } else {
                current = nil
            }
        }
        return parts.reversed().joined(separator: ".")
    }

    private func destinationPageIndex(for outline: PDFOutline) -> Int? {
        if let destination = outline.destination, let page = destination.page {
            return pdfView.document?.index(for: page)
        }
        for idx in 0..<outline.numberOfChildren {
            if let child = outline.child(at: idx),
               let childPageIndex = destinationPageIndex(for: child) {
                return childPageIndex
            }
        }
        return nil
    }

    private func firstBookmarkForPageIndex(_ pageIndex: Int) -> PDFOutline? {
        guard let root = pdfView.document?.outlineRoot else { return nil }
        for idx in 0..<root.numberOfChildren {
            if let child = root.child(at: idx),
               let found = firstBookmarkForPageIndex(pageIndex, in: child) {
                return found
            }
        }
        return nil
    }

    private func firstBookmarkForPageIndex(_ pageIndex: Int, in node: PDFOutline) -> PDFOutline? {
        if destinationPageIndex(for: node) == pageIndex {
            return node
        }
        for idx in 0..<node.numberOfChildren {
            if let child = node.child(at: idx),
               let found = firstBookmarkForPageIndex(pageIndex, in: child) {
                return found
            }
        }
        return nil
    }

    private func bookmarkContainsCurrentPage(_ outline: PDFOutline) -> Bool {
        guard sidebarCurrentPageIndex >= 0 else { return false }
        return destinationPageIndex(for: outline) == sidebarCurrentPageIndex
    }

    private func selectedSidebarPageIndexesForDeletion() -> [Int] {
        guard let document = pdfView.document else { return [] }
        let clickedRow = pagesTableView.clickedRow
        if clickedRow >= 0,
           clickedRow < document.pageCount,
           !pagesTableView.selectedRowIndexes.contains(clickedRow) {
            return [clickedRow]
        }
        var indexes = Array(pagesTableView.selectedRowIndexes).filter { $0 >= 0 && $0 < document.pageCount }
        if indexes.isEmpty {
            let selected = pagesTableView.selectedRow
            if selected >= 0, selected < document.pageCount {
                indexes = [selected]
            }
        }
        return indexes.sorted()
    }

    private func directDestinationPageIndex(for outline: PDFOutline, in document: PDFDocument) -> Int? {
        if let destinationPage = outline.destination?.page {
            let index = document.index(for: destinationPage)
            return index >= 0 ? index : nil
        }
        if let goToAction = outline.action as? PDFActionGoTo,
           let destinationPage = goToAction.destination.page {
            let index = document.index(for: destinationPage)
            return index >= 0 ? index : nil
        }
        return nil
    }

    private func countBookmarksDirectlyTargetingPages(_ pageIndexes: Set<Int>, in document: PDFDocument) -> Int {
        guard !pageIndexes.isEmpty, let root = document.outlineRoot else { return 0 }
        var count = 0
        func walk(_ node: PDFOutline) {
            if let targetIndex = directDestinationPageIndex(for: node, in: document),
               pageIndexes.contains(targetIndex) {
                count += 1
            }
            guard node.numberOfChildren > 0 else { return }
            for childIndex in 0..<node.numberOfChildren {
                if let child = node.child(at: childIndex) {
                    walk(child)
                }
            }
        }
        walk(root)
        return count
    }

    private func removeBookmarksTargetingPages(_ pageIndexes: Set<Int>, in document: PDFDocument) -> Int {
        guard !pageIndexes.isEmpty, let root = document.outlineRoot else { return 0 }
        var removedCount = 0

        func cloneWithoutRemovedNodes(_ node: PDFOutline) -> PDFOutline? {
            if let targetIndex = directDestinationPageIndex(for: node, in: document),
               pageIndexes.contains(targetIndex) {
                removedCount += 1
                return nil
            }

            let clone = PDFOutline()
            clone.label = node.label
            clone.destination = node.destination
            clone.action = node.action
            clone.isOpen = node.isOpen
            for childIndex in 0..<node.numberOfChildren {
                guard let child = node.child(at: childIndex),
                      let clonedChild = cloneWithoutRemovedNodes(child) else { continue }
                clone.insertChild(clonedChild, at: clone.numberOfChildren)
            }
            return clone
        }

        let newRoot = PDFOutline()
        for childIndex in 0..<root.numberOfChildren {
            guard let child = root.child(at: childIndex),
                  let clonedChild = cloneWithoutRemovedNodes(child) else { continue }
            newRoot.insertChild(clonedChild, at: newRoot.numberOfChildren)
        }
        document.outlineRoot = newRoot
        return removedCount
    }

    private func remapPageIndexedStateAfterDeletingPages(_ removedPageIndexes: [Int]) {
        let sortedRemoved = removedPageIndexes.sorted()
        guard !sortedRemoved.isEmpty else { return }
        let removedSet = Set(sortedRemoved)

        func remapIndex(_ oldIndex: Int) -> Int? {
            if removedSet.contains(oldIndex) { return nil }
            var shift = 0
            for removed in sortedRemoved {
                if removed < oldIndex {
                    shift += 1
                } else {
                    break
                }
            }
            return oldIndex - shift
        }

        var remappedPageLabels: [Int: String] = [:]
        for (pageIndex, label) in pageLabelOverrides {
            guard let newIndex = remapIndex(pageIndex) else { continue }
            remappedPageLabels[newIndex] = label
        }
        pageLabelOverrides = remappedPageLabels

        var remappedPageScaleLocks: [Int: PageScaleLock] = [:]
        for (pageIndex, lock) in pageScaleLocks {
            guard let newIndex = remapIndex(pageIndex) else { continue }
            remappedPageScaleLocks[newIndex] = lock
        }
        pageScaleLocks = remappedPageScaleLocks

        explicitScaleSetPageIndexes = Set(explicitScaleSetPageIndexes.compactMap(remapIndex))
        lastScaleLockAppliedPageIndex = remapIndex(lastScaleLockAppliedPageIndex) ?? -1
        lastExplicitScaleSetPageIndex = remapIndex(lastExplicitScaleSetPageIndex) ?? -1
        pendingScaleReminderSuppressionPageIndex = remapIndex(pendingScaleReminderSuppressionPageIndex) ?? -1
        sidebarCurrentPageIndex = remapIndex(sidebarCurrentPageIndex) ?? -1
    }

    func startAutoGenerateSheetNamesFlow() {
        guard let document = pdfView.document,
              let currentPage = pdfView.currentPage else {
            beep()
            return
        }
        let bookmarkPrompt = NSAlert()
        bookmarkPrompt.messageText = "Delete Existing Bookmarks and Page Names?"
        bookmarkPrompt.informativeText = "Would you like to delete all existing bookmarks and page names before running Auto Sheet Names and Numbers?"
        bookmarkPrompt.alertStyle = .warning
        bookmarkPrompt.addButton(withTitle: "Yes, Delete Both")
        bookmarkPrompt.addButton(withTitle: "No, Keep Existing")
        bookmarkPrompt.addButton(withTitle: "Cancel")
        let bookmarkPromptResponse = bookmarkPrompt.runModal()
        if bookmarkPromptResponse == .alertFirstButtonReturn {
            clearAllBookmarks(in: document)
        } else if bookmarkPromptResponse == .alertThirdButtonReturn {
            return
        }
        autoNameReferencePageIndex = document.index(for: currentPage)
        guard guardOrBeep((autoNameReferencePageIndex ?? -1) >= 0) else { return }
        pendingSheetNumberZone = nil
        pendingSheetTitleZone = nil
        autoNameCapturePhase = .sheetNumber
        autoNamePreviousToolMode = pdfView.toolMode
        setTool(.select)
        let alert = NSAlert()
        alert.messageText = "Step 1 of 2: Capture SHEET NUMBER"
        alert.informativeText = "Drag a rectangle over the SHEET NUMBER area on the current page, then release."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Capture SHEET NUMBER")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            cancelAutoNameCapture()
            return
        }
        beginRegionCaptureForAutoName()
    }

    private func beginRegionCaptureForAutoName() {
        pdfView.beginRegionCaptureMode()
    }

    private func cancelAutoNameCapture() {
        pdfView.cancelRegionCaptureMode()
        autoNameCapturePhase = nil
        autoNameReferencePageIndex = nil
        pendingSheetNumberZone = nil
        pendingSheetTitleZone = nil
        if let previous = autoNamePreviousToolMode {
            setTool(previous)
        }
        autoNamePreviousToolMode = nil
    }

    private func handleAutoNameRegionCaptured(on page: PDFPage, rectInPage: NSRect) {
        guard let document = pdfView.document else { return }
        guard let phase = autoNameCapturePhase,
              let referenceIndex = autoNameReferencePageIndex,
              let referencePage = document.page(at: referenceIndex) else {
            cancelAutoNameCapture()
            return
        }
        let currentIndex = document.index(for: page)
        guard currentIndex == referenceIndex else {
            runAlert(
                title: "Capture On Reference Page",
                informativeText: "Please capture zones on the same page where you started.",
                style: .warning
            )
            beginRegionCaptureForAutoName()
            return
        }

        let normalized = normalize(rectInPage: rectInPage, for: referencePage)
        switch phase {
        case .sheetNumber:
            pendingSheetNumberZone = normalized
            autoNameCapturePhase = .sheetTitle
            let alert = NSAlert()
            alert.messageText = "Step 2 of 2: Capture SHEET NAME"
            alert.informativeText = "Now drag a rectangle over the SHEET NAME area, then release."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Capture SHEET NAME")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                beginRegionCaptureForAutoName()
            } else {
                cancelAutoNameCapture()
            }
        case .sheetTitle:
            pendingSheetTitleZone = normalized
            autoNameCapturePhase = nil
            let confirmation = NSAlert()
            confirmation.messageText = "Use These OCR Zones?"
            confirmation.informativeText = "Proceed with the selected SHEET NUMBER and SHEET NAME areas for all pages?"
            confirmation.alertStyle = .informational
            confirmation.addButton(withTitle: "Run OCR")
            confirmation.addButton(withTitle: "Recapture Zones")
            confirmation.addButton(withTitle: "Cancel")
            let response = confirmation.runModal()
            if response == .alertFirstButtonReturn {
                runAutoNameExtraction()
            } else if response == .alertSecondButtonReturn {
                pendingSheetNumberZone = nil
                pendingSheetTitleZone = nil
                autoNameCapturePhase = .sheetNumber
                let alert = NSAlert()
                alert.messageText = "Step 1 of 2: Capture SHEET NUMBER"
                alert.informativeText = "Drag a rectangle over the SHEET NUMBER area on the current page, then release."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Capture SHEET NUMBER")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    beginRegionCaptureForAutoName()
                } else {
                    cancelAutoNameCapture()
                }
            } else {
                cancelAutoNameCapture()
            }
        }
    }

    private func runAutoNameExtraction() {
        guard let document = pdfView.document,
              let numberZone = pendingSheetNumberZone,
              let titleZone = pendingSheetTitleZone else {
            cancelAutoNameCapture()
            return
        }
        beginBusyIndicator("Reading Sheet Names…")
        defer {
            endBusyIndicator()
            if let previous = autoNamePreviousToolMode {
                setTool(previous)
            }
            autoNamePreviousToolMode = nil
            autoNameReferencePageIndex = nil
            autoNameCapturePhase = nil
            pendingSheetNumberZone = nil
            pendingSheetTitleZone = nil
        }

        var generated: [AutoNamedSheet] = []
        generated.reserveCapacity(document.pageCount)
        var detectedSheetNumberCount = 0
        for pageIndex in 0..<document.pageCount {
            autoreleasepool {
                guard let page = document.page(at: pageIndex) else { return }
                let titleRect = denormalize(rect: titleZone, for: page)
                // Reduced padding: 8% horizontal, 4% vertical
                let hPadding = max(titleRect.width * 0.08, 6.0)
                let vPadding = max(titleRect.height * 0.04, 3.0)
                let expandedTitleRect = titleRect.insetBy(dx: -hPadding, dy: -vPadding).intersection(page.bounds(for: pdfView.displayBox))

                let labelCanonicalTokens = Set(extractSheetTokens(from: page.label ?? "").map(canonicalizeSheetToken))
                let labelSheetInfo = sheetInfoFromPageLabel(page.label ?? "")
                let number: String
                if let labelNumber = labelSheetInfo.number {
                    number = labelNumber
                    detectedSheetNumberCount += 1
                } else if let token = detectAutoNameSheetNumber(on: page, normalizedZone: numberZone, labelCanonicalTokens: labelCanonicalTokens) {
                    number = token
                    detectedSheetNumberCount += 1
                } else {
                    let labelTokens = extractSheetTokens(from: page.label ?? "")
                    number = preferredSheetToken(from: labelTokens, labelCanonicalTokens: labelCanonicalTokens) ?? "Page \(pageIndex + 1)"
                }
                let detectedTitle = detectAutoNameSheetTitle(on: page, primaryRect: expandedTitleRect)
                let title = labelSheetInfo.title ?? detectedTitle
                generated.append(
                    AutoNamedSheet(
                        pageIndex: pageIndex,
                        sheetNumber: number,
                        sheetTitle: title
                    )
                )
            }
        }

        guard detectedSheetNumberCount > 0 else {
            runAlert(
                title: "No Sheet Numbers Detected",
                informativeText: "Drawbridge could not detect valid sheet-number tokens from the captured SHEET NUMBER zone. Try recapturing a tighter box around the visible sheet number.",
                style: .warning
            )
            return
        }

        guard !generated.isEmpty else {
            runAlert(
                title: "No Pages Found",
                informativeText: "Could not generate names for this document.",
                style: .warning
            )
            return
        }

        let previewLines = generated.prefix(20).map { sheet in
            let title = sheet.sheetTitle.isEmpty ? "(untitled)" : sheet.sheetTitle
            return "\(sheet.pageIndex + 1). \(sheet.sheetNumber) - \(title)"
        }
        let overflowNote = generated.count > 20 ? "\n…and \(generated.count - 20) more pages." : ""
        let confirmation = NSAlert()
        confirmation.messageText = "Apply Auto-Generated Sheet Names?"
        confirmation.informativeText = previewLines.joined(separator: "\n") + overflowNote
        confirmation.alertStyle = .informational
        confirmation.addButton(withTitle: "Continue")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        let applyPagesPrompt = NSAlert()
        applyPagesPrompt.messageText = "Apply to Pages too?"
        applyPagesPrompt.informativeText = "Would you like to apply detected SHEET NUMBER values to the Pages list labels as well?"
        applyPagesPrompt.alertStyle = .informational
        applyPagesPrompt.addButton(withTitle: "Apply to Bookmarks + Pages")
        applyPagesPrompt.addButton(withTitle: "Apply to Bookmarks Only")
        applyPagesPrompt.addButton(withTitle: "Cancel")

        let applyPagesResponse = applyPagesPrompt.runModal()
        if applyPagesResponse == .alertThirdButtonReturn {
            return
        }
        let applyPageLabels = (applyPagesResponse == .alertFirstButtonReturn)
        applyAutoNamedSheets(generated, to: document, applyPageLabels: applyPageLabels)
    }

    func startAutoLinkSheetNumbersFlow() {
        guard let document = pdfView.document,
              let currentPage = pdfView.currentPage else {
            beep()
            return
        }
        autoLinkCaptureReferencePageIndex = document.index(for: currentPage)
        guard guardOrBeep((autoLinkCaptureReferencePageIndex ?? -1) >= 0) else { return }
        autoLinkPreviousToolMode = pdfView.toolMode
        setTool(.select)

        let alert = NSAlert()
        alert.messageText = "Batch Link: Capture SHEET NUMBER Zone"
        alert.informativeText = "Drag a rectangle over the SHEET NUMBER area on a typical sheet. Drawbridge will OCR this zone across all pages and create hyperlinks to associated pages."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Capture Zone")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            cancelAutoLinkCapture()
            return
        }
        pdfView.beginRegionCaptureMode()
    }

    private func cancelAutoLinkCapture() {
        pdfView.cancelRegionCaptureMode()
        autoLinkCaptureReferencePageIndex = nil
        if let previous = autoLinkPreviousToolMode {
            setTool(previous)
        }
        autoLinkPreviousToolMode = nil
        shouldChainAutoNameAfterBatchLink = false
    }

    private func handleAutoLinkRegionCaptured(on page: PDFPage, rectInPage: NSRect) {
        guard let document = pdfView.document,
              let referenceIndex = autoLinkCaptureReferencePageIndex,
              let referencePage = document.page(at: referenceIndex) else {
            cancelAutoLinkCapture()
            return
        }
        let currentIndex = document.index(for: page)
        guard currentIndex == referenceIndex else {
            runAlert(
                title: "Capture On Reference Page",
                informativeText: "Please capture on the same page where Batch Link started.",
                style: .warning
            )
            pdfView.beginRegionCaptureMode()
            return
        }

        let normalizedZone = normalize(rectInPage: rectInPage, for: referencePage)
        runBatchLinkUsingSheetNumberZone(normalizedZone)
    }

    private func runBatchLinkUsingSheetNumberZone(_ normalizedZone: NormalizedPageRect) {
        guard let document = pdfView.document else {
            cancelAutoLinkCapture()
            return
        }
        let preservedPageRotations = Self.pageRotations(in: document)
        var completedBatchLink = false
        guard let referenceIndex = autoLinkCaptureReferencePageIndex,
              referenceIndex >= 0,
              referenceIndex < document.pageCount else {
            cancelAutoLinkCapture()
            return
        }

        beginBusyIndicator("Batch Linking Sheet Numbers…", detail: "Reading sheet numbers…")
        defer {
            Self.restorePageRotations(preservedPageRotations, to: document)
            endBusyIndicator()
            if let previous = autoLinkPreviousToolMode {
                setTool(previous)
            }
            autoLinkPreviousToolMode = nil
            autoLinkCaptureReferencePageIndex = nil
            if !completedBatchLink {
                shouldChainAutoNameAfterBatchLink = false
            }
        }

        var sheetTokenToPageIndex: [String: Int] = [:]
        var canonicalSheetTokenToPageIndex: [String: Int] = [:]
        var tokenConfidenceByToken: [String: Int] = [:]
        var tokenConfidenceByCanonical: [String: Int] = [:]
        var zonePageDiagnostics: [BatchLinkZonePageDiagnostic] = []
        let batchStartedAt = Date()
        var stageStartedAt = Date()

        func recordSheetToken(_ token: String, pageIndex: Int, confidence: Int) {
            let existingTokenConfidence = tokenConfidenceByToken[token] ?? 0
            if existingTokenConfidence <= confidence {
                sheetTokenToPageIndex[token] = pageIndex
                tokenConfidenceByToken[token] = confidence
            }
            let canonical = canonicalizeSheetToken(token)
            if !canonical.isEmpty {
                let existingCanonicalConfidence = tokenConfidenceByCanonical[canonical] ?? 0
                if existingCanonicalConfidence <= confidence {
                    canonicalSheetTokenToPageIndex[canonical] = pageIndex
                    tokenConfidenceByCanonical[canonical] = confidence
                }
            }
        }

        func contextualSubdetail(prefix: String, current: Int, total: Int) -> String {
            let safeTotal = max(1, total)
            let done = max(0, min(current, safeTotal))
            let percent = Int((Double(done) / Double(safeTotal) * 100).rounded())
            let elapsed = shortDuration(Date().timeIntervalSince(batchStartedAt))
            guard done > 0 else {
                return "\(prefix) • \(done)/\(safeTotal) (\(percent)%) • ETA -- • elapsed \(elapsed)"
            }
            let stageElapsed = Date().timeIntervalSince(stageStartedAt)
            let remaining = stageElapsed * Double(safeTotal - done) / Double(done)
            return "\(prefix) • \(done)/\(safeTotal) (\(percent)%) • ETA \(shortDuration(remaining)) • elapsed \(elapsed)"
        }

        updateBusyIndicatorStatus("Batch Linking Sheet Numbers…")
        updateBusyIndicatorDetail("Step 1/3: Reading sheet numbers…")
        updateBusyIndicatorSubdetail(contextualSubdetail(prefix: "0 found", current: 0, total: document.pageCount))
        updateBusyIndicatorProgress(current: 0, total: document.pageCount)
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            updateBusyIndicatorProgress(current: pageIndex + 1, total: document.pageCount)
            updateBusyIndicatorDetail("Step 1/3: Reading sheet numbers… \(pageIndex + 1)/\(document.pageCount)")
            let labelCanonicalTokens = Set(extractSheetTokens(from: page.label ?? "").map(canonicalizeSheetToken))
            if let labelToken = sheetInfoFromPageLabel(page.label ?? "").number {
                recordSheetToken(labelToken, pageIndex: pageIndex, confidence: 5)
                zonePageDiagnostics.append(
                    BatchLinkZonePageDiagnostic(
                        pageIndex: pageIndex,
                        pageLabel: page.label ?? "",
                        detectedToken: labelToken,
                        strategy: "page label",
                        rawTextPreview: truncatedZoneDiagnosticText(page.label ?? ""),
                        failureReason: nil,
                        usedFallback: true
                    )
                )
                updateBusyIndicatorSubdetail(
                    contextualSubdetail(
                        prefix: "\(sheetTokenToPageIndex.count) found",
                        current: pageIndex + 1,
                        total: document.pageCount
                    )
                )
                continue
            }

            let detected = detectSheetTokenForBatchLink(on: page, normalizedZone: normalizedZone, labelCanonicalTokens: labelCanonicalTokens)
            guard let token = detected.token else {
                zonePageDiagnostics.append(
                    BatchLinkZonePageDiagnostic(
                        pageIndex: pageIndex,
                        pageLabel: page.label ?? "",
                        detectedToken: nil,
                        strategy: detected.strategy,
                        rawTextPreview: detected.rawTextPreview,
                        failureReason: detected.failureReason,
                        usedFallback: false
                    )
                )
                updateBusyIndicatorSubdetail(
                    contextualSubdetail(
                        prefix: "\(sheetTokenToPageIndex.count) found",
                        current: pageIndex + 1,
                        total: document.pageCount
                    )
                )
                continue
            }

            zonePageDiagnostics.append(
                BatchLinkZonePageDiagnostic(
                    pageIndex: pageIndex,
                    pageLabel: page.label ?? "",
                    detectedToken: token,
                    strategy: detected.strategy,
                    rawTextPreview: detected.rawTextPreview,
                    failureReason: nil,
                    usedFallback: detected.usedFallback
                )
            )

            let canonical = canonicalizeSheetToken(token)
            let zoneConfidence = (!canonical.isEmpty && labelCanonicalTokens.contains(canonical)) ? 3 : 2
            recordSheetToken(token, pageIndex: pageIndex, confidence: zoneConfidence)
            updateBusyIndicatorSubdetail(
                contextualSubdetail(
                    prefix: "\(sheetTokenToPageIndex.count) found",
                    current: pageIndex + 1,
                    total: document.pageCount
                )
            )
        }

        supplementSheetTokenMapFromExistingLabelsAndBookmarks(
            document: document,
            sheetTokenToPageIndex: &sheetTokenToPageIndex,
            canonicalSheetTokenToPageIndex: &canonicalSheetTokenToPageIndex,
            tokenConfidenceByToken: &tokenConfidenceByToken,
            tokenConfidenceByCanonical: &tokenConfidenceByCanonical
        )

        let zoneDetectedCount = zonePageDiagnostics.reduce(0) { partial, diagnostic in
            partial + (diagnostic.detectedToken == nil ? 0 : 1)
        }
        let zoneFallbackRecoveredCount = zonePageDiagnostics.reduce(0) { partial, diagnostic in
            partial + ((diagnostic.detectedToken != nil && diagnostic.usedFallback) ? 1 : 0)
        }

        guard !sheetTokenToPageIndex.isEmpty else {
            let response = runAlert(
                title: "No Sheet Numbers Detected",
                informativeText: "Could not detect sheet numbers from the captured zone.\n\nZone read: \(zoneDetectedCount)/\(document.pageCount) pages (\(zoneFallbackRecoveredCount) recovered by fallback probes).",
                style: .warning,
                buttons: ["OK", "Show Diagnostics"]
            )
            if response == .alertSecondButtonReturn {
                showBatchLinkZoneDiagnostics(document: document, diagnostics: zonePageDiagnostics)
            }
            return
        }

        let clearPrompt = NSAlert()
        clearPrompt.messageText = "Replace Existing Batch Links?"
        clearPrompt.informativeText = "Delete existing auto-generated sheet links before creating new ones?"
        clearPrompt.alertStyle = .informational
        clearPrompt.addButton(withTitle: "Yes, Replace")
        clearPrompt.addButton(withTitle: "No, Keep Existing")
        clearPrompt.addButton(withTitle: "Cancel")
        let clearResponse = clearPrompt.runModal()
        if clearResponse == .alertThirdButtonReturn {
            return
        }
        let shouldClearExisting = (clearResponse == .alertFirstButtonReturn)

        if shouldClearExisting {
            stageStartedAt = Date()
            updateBusyIndicatorStatus("Batch Linking Sheet Numbers…")
            updateBusyIndicatorDetail("Step 0/3: Removing existing batch links…")
            updateBusyIndicatorSubdetail(contextualSubdetail(prefix: "0 links removed", current: 0, total: document.pageCount))
            updateBusyIndicatorProgress(current: 0, total: max(1, document.pageCount))
            var removedLinks = 0
            removeAutoSheetLinks(in: document) { currentPage, totalPages, removedSoFar in
                removedLinks = removedSoFar
                self.updateBusyIndicatorProgress(current: currentPage, total: max(1, totalPages))
                self.updateBusyIndicatorDetail("Step 0/3: Removing existing batch links… \(currentPage)/\(totalPages)")
                self.updateBusyIndicatorSubdetail(
                    contextualSubdetail(
                        prefix: "\(removedSoFar) links removed",
                        current: currentPage,
                        total: totalPages
                    )
                )
            }
            updateBusyIndicatorSubdetail(
                contextualSubdetail(
                    prefix: "\(removedLinks) links removed",
                    current: document.pageCount,
                    total: document.pageCount
                )
            )
        }

        stageStartedAt = Date()
        updateBusyIndicatorStatus("Batch Linking Sheet Numbers…")
        updateBusyIndicatorDetail("Step 2/3: Linking text matches…")
        updateBusyIndicatorSubdetail(contextualSubdetail(prefix: "0 links created", current: 0, total: 1))
        var addedLinks = 0
        var touchedPageIDs = Set<ObjectIdentifier>()
        typealias LinkTarget = (destination: PDFDestination, targetPageIndex: Int)
        var linkTargetsByToken: [String: LinkTarget] = [:]
        var linkTargetsByCanonicalToken: [String: LinkTarget] = [:]
        for (sheetToken, targetPageIndex) in sheetTokenToPageIndex.sorted(by: { $0.key < $1.key }) {
            guard targetPageIndex >= 0,
                  targetPageIndex < document.pageCount,
                  let targetPage = document.page(at: targetPageIndex) else { continue }
            let target: LinkTarget = (bookmarkStyleDestination(for: targetPage), targetPageIndex)
            linkTargetsByToken[sheetToken] = target
            let canonical = canonicalizeSheetToken(sheetToken)
            if !canonical.isEmpty {
                linkTargetsByCanonicalToken[canonical] = target
            }
        }
        for (canonical, targetPageIndex) in canonicalSheetTokenToPageIndex {
            guard linkTargetsByCanonicalToken[canonical] == nil,
                  targetPageIndex >= 0,
                  targetPageIndex < document.pageCount,
                  let targetPage = document.page(at: targetPageIndex) else { continue }
            linkTargetsByCanonicalToken[canonical] = (bookmarkStyleDestination(for: targetPage), targetPageIndex)
        }

        var createdBoundsKeys = Set<String>()
        let sortedTargets = linkTargetsByToken.sorted(by: { $0.key < $1.key })
        let linkingTargetTotal = max(1, sortedTargets.count)
        updateBusyIndicatorSubdetail(contextualSubdetail(prefix: "\(addedLinks) links created", current: 0, total: linkingTargetTotal))
        updateBusyIndicatorProgress(current: 0, total: max(1, sortedTargets.count))
        for (targetIndex, pair) in sortedTargets.enumerated() {
            let (sheetToken, target) = pair
            updateBusyIndicatorProgress(current: targetIndex + 1, total: max(1, sortedTargets.count))
            updateBusyIndicatorDetail("Step 2/3: Linking text matches… \(targetIndex + 1)/\(sortedTargets.count)")
            let selections = document.findString(sheetToken, withOptions: [.caseInsensitive])
            for selection in selections {
                for page in selection.pages {
                    guard let sourcePageIndex = pageIndex(for: page, in: document) else { continue }
                    if target.targetPageIndex == sourcePageIndex {
                        continue
                    }
                    let bounds = selection.bounds(for: page).insetBy(dx: -1.5, dy: -1.0)
                    guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
                    let key = "\(sourcePageIndex):\(sheetToken):\(bounds.origin.x.rounded()):\(bounds.origin.y.rounded()):\(bounds.width.rounded()):\(bounds.height.rounded())"
                    if createdBoundsKeys.contains(key) { continue }
                    createdBoundsKeys.insert(key)
                    addAutoSheetLink(on: page, bounds: bounds, destination: target.destination)
                    touchedPageIDs.insert(ObjectIdentifier(page))
                    addedLinks += 1
                }
            }
            updateBusyIndicatorSubdetail(
                contextualSubdetail(
                    prefix: "\(addedLinks) links created",
                    current: targetIndex + 1,
                    total: linkingTargetTotal
                )
            )
        }

        // Supplementary pass for selectable text that can be missed by findString
        // (font encoding quirks, punctuation boundaries, etc.).
        stageStartedAt = Date()
        updateBusyIndicatorDetail("Step 2/3: Scanning selectable text…")
        updateBusyIndicatorProgress(current: 0, total: document.pageCount)
        updateBusyIndicatorSubdetail(contextualSubdetail(prefix: "\(addedLinks) links created", current: 0, total: document.pageCount))
        for sourcePageIndex in 0..<document.pageCount {
            guard let page = document.page(at: sourcePageIndex) else { continue }
            updateBusyIndicatorProgress(current: sourcePageIndex + 1, total: document.pageCount)
            updateBusyIndicatorDetail("Step 2/3: Scanning selectable text… \(sourcePageIndex + 1)/\(document.pageCount)")
            let hits = selectableSheetTokenHits(on: page)
            for hit in hits {
                let canonical = canonicalizeSheetToken(hit.token)
                let target = linkTargetsByToken[hit.token] ?? linkTargetsByCanonicalToken[canonical]
                guard let target else { continue }
                if target.targetPageIndex == sourcePageIndex {
                    continue
                }
                let bounds = hyperlinkActivationBounds(for: hit.bounds, token: hit.token)
                guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
                let key = "\(sourcePageIndex):\(hit.token):\(bounds.origin.x.rounded()):\(bounds.origin.y.rounded()):\(bounds.width.rounded()):\(bounds.height.rounded())"
                if createdBoundsKeys.contains(key) { continue }
                createdBoundsKeys.insert(key)
                addAutoSheetLink(on: page, bounds: bounds, destination: target.destination)
                touchedPageIDs.insert(ObjectIdentifier(page))
                addedLinks += 1
            }
            updateBusyIndicatorSubdetail(
                contextualSubdetail(
                    prefix: "\(addedLinks) links created",
                    current: sourcePageIndex + 1,
                    total: document.pageCount
                )
            )
        }

        // OCR fallback for scanned pages with no selectable text.
        stageStartedAt = Date()
        updateBusyIndicatorDetail("Step 3/3: OCR fallback + linking…")
        updateBusyIndicatorProgress(current: 0, total: document.pageCount)
        updateBusyIndicatorSubdetail(contextualSubdetail(prefix: "\(addedLinks) links created", current: 0, total: document.pageCount))
        let ocrCustomWords = Array(linkTargetsByToken.keys)
        for sourcePageIndex in 0..<document.pageCount {
            guard let page = document.page(at: sourcePageIndex) else { continue }
            updateBusyIndicatorProgress(current: sourcePageIndex + 1, total: document.pageCount)
            updateBusyIndicatorDetail("Step 3/3: OCR fallback + linking… \(sourcePageIndex + 1)/\(document.pageCount)")
            let ocrHits = recognizeTextLines(in: page, customWords: ocrCustomWords)
            for hit in ocrHits {
                let tokens = extractSheetTokens(from: hit.text)
                guard !tokens.isEmpty else { continue }
                for token in tokens {
                    let canonical = canonicalizeSheetToken(token)
                    let target = linkTargetsByToken[token] ?? linkTargetsByCanonicalToken[canonical]
                    guard let target else { continue }
                    if target.targetPageIndex == sourcePageIndex {
                        continue
                    }
                    let expanded = hyperlinkActivationBounds(for: hit.rectInPage, token: token)
                    let key = "\(sourcePageIndex):\(token):\(expanded.origin.x.rounded()):\(expanded.origin.y.rounded()):\(expanded.width.rounded()):\(expanded.height.rounded())"
                    if createdBoundsKeys.contains(key) { continue }
                    createdBoundsKeys.insert(key)
                    addAutoSheetLink(on: page, bounds: expanded, destination: target.destination)
                    touchedPageIDs.insert(ObjectIdentifier(page))
                    addedLinks += 1
                }
            }
            updateBusyIndicatorSubdetail(
                contextualSubdetail(
                    prefix: "\(addedLinks) links created",
                    current: sourcePageIndex + 1,
                    total: document.pageCount
                )
            )
        }

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex),
                  touchedPageIDs.contains(ObjectIdentifier(page)) else { continue }
            markPageMarkupCacheDirty(page)
        }

        if addedLinks > 0 {
            markMarkupChangedAndScheduleAutosave()
            refreshMarkups()
            pdfView.refreshHyperlinkHighlights()
        }
        reloadBookmarks()
        updateStatusBar()

        let completionResponse = runAlert(
            title: "Batch Link Complete",
            informativeText: "Detected \(sheetTokenToPageIndex.count) sheet numbers and created \(addedLinks) hyperlink(s) across \(document.pageCount) page(s).\n\nZone read: \(zoneDetectedCount)/\(document.pageCount) pages (\(zoneFallbackRecoveredCount) recovered by fallback probes).",
            buttons: ["OK", "Show Diagnostics"]
        )
        if completionResponse == .alertSecondButtonReturn {
            showBatchLinkZoneDiagnostics(document: document, diagnostics: zonePageDiagnostics)
        }
        completedBatchLink = true

        let shouldChainAutoName = shouldChainAutoNameAfterBatchLink
        shouldChainAutoNameAfterBatchLink = false
        if shouldChainAutoName {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.pdfView.document != nil else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.view.window?.makeFirstResponder(self.pdfView)
                self.startAutoGenerateSheetNamesFlow()
            }
        }
    }

    private func showBatchLinkZoneDiagnostics(document: PDFDocument, diagnostics: [BatchLinkZonePageDiagnostic]) {
        guard !diagnostics.isEmpty else { return }

        func pageDescriptor(pageIndex: Int, pageLabel: String) -> String {
            let trimmedLabel = pageLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLabel.isEmpty {
                return "Page \(pageIndex + 1)"
            }
            return "Page \(pageIndex + 1) [\(trimmedLabel)]"
        }

        let detected = diagnostics.filter { $0.detectedToken != nil }
        let missed = diagnostics.filter { $0.detectedToken == nil }
        let recoveredByFallback = detected.filter(\.usedFallback)

        var lines: [String] = []
        lines.append("Detected tokens: \(detected.count)/\(document.pageCount)")
        lines.append("Recovered by fallback probes: \(recoveredByFallback.count)")
        lines.append("Missed pages: \(missed.count)")

        if !missed.isEmpty {
            lines.append("")
            lines.append("Missed Page Details:")
            for item in missed.prefix(30) {
                let descriptor = pageDescriptor(pageIndex: item.pageIndex, pageLabel: item.pageLabel)
                var line = "\(descriptor): \(item.failureReason ?? "No matching token.")"
                if !item.rawTextPreview.isEmpty {
                    line += " Sample: \"\(item.rawTextPreview)\""
                }
                lines.append(line)
            }
            if missed.count > 30 {
                lines.append("... plus \(missed.count - 30) more missed pages.")
            }
        }

        if !recoveredByFallback.isEmpty {
            lines.append("")
            lines.append("Recovered by Fallback:")
            for item in recoveredByFallback.prefix(20) {
                let descriptor = pageDescriptor(pageIndex: item.pageIndex, pageLabel: item.pageLabel)
                let token = item.detectedToken ?? "?"
                lines.append("\(descriptor): \(token) via \(item.strategy).")
            }
            if recoveredByFallback.count > 20 {
                lines.append("... plus \(recoveredByFallback.count - 20) more fallback recoveries.")
            }
        }

        _ = runAlert(
            title: "Batch Link Diagnostics",
            informativeText: lines.joined(separator: "\n"),
            style: missed.isEmpty ? .informational : .warning
        )
    }

    private func pageIndex(for page: PDFPage, in document: PDFDocument) -> Int? {
        let index = document.index(for: page)
        return index >= 0 ? index : nil
    }

    private func bookmarkStyleDestination(for page: PDFPage) -> PDFDestination {
        let destination = PDFDestination(
            page: page,
            at: NSPoint(x: kPDFDestinationUnspecifiedValue, y: kPDFDestinationUnspecifiedValue)
        )
        destination.zoom = kPDFDestinationUnspecifiedValue
        return destination
    }

    func isProtectedAutoSheetLink(_ annotation: PDFAnnotation) -> Bool {
        let type = (annotation.type ?? "").lowercased()
        guard type == PDFAnnotationSubtype.link.rawValue.lowercased() else { return false }
        let marker = autoSheetLinkAnnotationMarker
        let rawValues = [annotation.userName, annotation.contents]
        return rawValues.contains { raw in
            guard let raw else { return false }
            return raw.contains(marker)
        }
    }

    func isUserEditableMarkup(_ annotation: PDFAnnotation) -> Bool {
        !pdfView.isHatchOverlayAnnotation(annotation) && !isProtectedAutoSheetLink(annotation)
    }

    private func addAutoSheetLink(on page: PDFPage, bounds: NSRect, destination: PDFDestination) {
        let link = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
        let border = PDFBorder()
        border.lineWidth = 0
        link.border = border
        link.color = .clear
        link.isReadOnly = true
        if let destinationPage = destination.page,
           let document = page.document {
            let destinationPageIndex = document.index(for: destinationPage)
            if destinationPageIndex >= 0 {
                let metadata = "\(autoSheetLinkAnnotationMarker):\(destinationPageIndex)"
                link.userName = metadata
                link.contents = metadata
            } else {
                link.contents = autoSheetLinkAnnotationMarker
            }
        } else {
            link.contents = autoSheetLinkAnnotationMarker
        }
        // Prefer action-only encoding for external viewer compatibility.
        // Some viewers prioritize /Dest over /A and preserve current zoom.
        link.destination = nil
        link.action = PDFActionGoTo(destination: destination)
        page.addAnnotation(link)
    }

    private func removeAutoSheetLinks(
        in document: PDFDocument,
        progress: ((Int, Int, Int) -> Void)? = nil
    ) {
        var removedCount = 0
        let totalPages = max(1, document.pageCount)
        if document.pageCount == 0 {
            progress?(1, totalPages, removedCount)
            return
        }
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let linksToRemove = page.annotations.filter(isProtectedAutoSheetLink)
            if !linksToRemove.isEmpty {
                for link in linksToRemove {
                    page.removeAnnotation(link)
                    removedCount += 1
                }
                markPageMarkupCacheDirty(page)
            }
            progress?(pageIndex + 1, totalPages, removedCount)
        }
    }

    private func extractPrimarySheetToken(from raw: String) -> String? {
        extractSheetTokens(from: raw).first
    }

    private func sheetInfoFromPageLabel(_ label: String) -> (number: String?, title: String?) {
        let cleaned = cleanDetectedSheetText(label)
        guard !cleaned.isEmpty else { return (nil, nil) }
        let tokens = extractSheetTokens(from: cleaned)
        guard let number = preferredSheetToken(from: tokens) else { return (nil, nil) }

        var title = cleaned
        let escapedNumber = NSRegularExpression.escapedPattern(for: number)
        if let regex = try? NSRegularExpression(pattern: #"(?i)(^|\b)"# + escapedNumber + #"(\b|$)"#) {
            title = regex.stringByReplacingMatches(
                in: title,
                range: NSRange(title.startIndex..., in: title),
                withTemplate: " "
            )
        }
        title = title
            .replacingOccurrences(of: #"^[\s\-–—_:|/\\.]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s\-–—_:|/\\.]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (number, isUsableSheetTitle(title) ? title : nil)
    }

    private func detectAutoNameSheetNumber(
        on page: PDFPage,
        normalizedZone: NormalizedPageRect,
        labelCanonicalTokens: Set<String>
    ) -> String? {
        let detectedNumber = detectSheetTokensInCapturedZone(on: page, normalizedZone: normalizedZone)
        if let detectedResult = detectedNumber.result,
           let token = preferredSheetToken(from: detectedResult.tokens, labelCanonicalTokens: labelCanonicalTokens) {
            return token
        }

        let numRect = denormalize(rect: normalizedZone, for: page)
        let expandedNumRect = numRect
            .insetBy(dx: -max(numRect.width * 0.20, 10.0), dy: -max(numRect.height * 0.50, 8.0))
            .intersection(page.bounds(for: pdfView.displayBox))
        let expandedText = extractText(from: page, rectInPage: expandedNumRect, allowOCR: true, preferOCR: true)
        let expandedTokens = extractSheetTokens(from: expandedText)
        if let token = preferredSheetToken(from: expandedTokens, labelCanonicalTokens: labelCanonicalTokens) {
            return token
        }

        return detectAnchoredSheetNumber(on: page, expectedRect: numRect, labelCanonicalTokens: labelCanonicalTokens)
    }

    private func detectSheetTokenForBatchLink(
        on page: PDFPage,
        normalizedZone: NormalizedPageRect,
        labelCanonicalTokens: Set<String>
    ) -> (token: String?, strategy: String, rawTextPreview: String, failureReason: String?, usedFallback: Bool) {
        let detected = detectSheetTokensInCapturedZone(on: page, normalizedZone: normalizedZone)
        if let detectedResult = detected.result {
            let token = preferredSheetToken(
                from: Array(Set(detectedResult.tokens)),
                labelCanonicalTokens: labelCanonicalTokens
            )
            if let token {
                return (
                    token,
                    detectedResult.strategy,
                    truncatedZoneDiagnosticText(detectedResult.rawText),
                    nil,
                    detectedResult.usedFallback
                )
            }
        }

        let numRect = denormalize(rect: normalizedZone, for: page)
        let expandedNumRect = numRect
            .insetBy(dx: -max(numRect.width * 0.20, 10.0), dy: -max(numRect.height * 0.50, 8.0))
            .intersection(page.bounds(for: pdfView.displayBox))
        let expandedText = extractText(from: page, rectInPage: expandedNumRect, allowOCR: true, preferOCR: true)
        let expandedTokens = extractSheetTokens(from: expandedText)
        if let token = preferredSheetToken(from: expandedTokens, labelCanonicalTokens: labelCanonicalTokens) {
            return (
                token,
                "expanded zone + OCR",
                truncatedZoneDiagnosticText(expandedText),
                nil,
                true
            )
        }

        if let anchored = detectAnchoredSheetNumber(on: page, expectedRect: numRect, labelCanonicalTokens: labelCanonicalTokens) {
            return (
                anchored,
                "anchored SHEET NO OCR",
                "",
                nil,
                true
            )
        }

        return (
            nil,
            detected.result?.strategy ?? "none",
            detected.rawTextPreview.isEmpty ? truncatedZoneDiagnosticText(expandedText) : detected.rawTextPreview,
            detected.failureReason ?? "No valid sheet token detected from page label, captured zone, or anchored OCR.",
            true
        )
    }

    private func detectAutoNameSheetTitle(on page: PDFPage, primaryRect: NSRect) -> String {
        let primary = extractText(from: page, rectInPage: primaryRect, allowOCR: true, preferOCR: true, usesLanguageCorrection: true)
        if isUsableSheetTitle(primary) {
            return primary
        }
        return detectAnchoredSheetTitle(on: page, expectedRect: primaryRect) ?? primary
    }

    private func detectAnchoredSheetNumber(
        on page: PDFPage,
        expectedRect: NSRect,
        labelCanonicalTokens: Set<String>
    ) -> String? {
        let hits = recognizeTextLines(in: page)
        guard !hits.isEmpty else { return nil }
        let pageBounds = zoneCaptureBounds(for: page)
        let labels = hits.filter { isSheetNumberLabel($0.text) }

        var scored: [(token: String, score: CGFloat)] = []
        func appendCandidates(from hit: OCRLineHit, baseScore: CGFloat) {
            for token in extractSheetTokens(from: hit.text) {
                guard preferredSheetToken(from: [token], labelCanonicalTokens: labelCanonicalTokens) != nil else { continue }
                let tokenScore = CGFloat(scoreSheetToken(token, labelCanonicalTokens: labelCanonicalTokens))
                let sizeScore = min(hit.rectInPage.height / max(pageBounds.height, 1) * 500, 40)
                scored.append((token, baseScore + tokenScore + sizeScore))
            }
        }

        for label in labels {
            let labelCenterX = label.rectInPage.midX
            let labelY = label.rectInPage.midY
            for hit in hits where hit.rectInPage != label.rectInPage {
                let center = NSPoint(x: hit.rectInPage.midX, y: hit.rectInPage.midY)
                let verticalBelow = labelY - center.y
                let isBelowLabel = verticalBelow >= -pageBounds.height * 0.03 && verticalBelow <= pageBounds.height * 0.35
                let isRightOfLabel = center.x >= label.rectInPage.minX - pageBounds.width * 0.05 && center.x <= pageBounds.maxX
                let isNearLabelColumn = abs(center.x - labelCenterX) <= pageBounds.width * 0.30
                guard isBelowLabel && (isRightOfLabel || isNearLabelColumn) else { continue }
                let distancePenalty = (abs(center.x - labelCenterX) / max(pageBounds.width, 1) * 35) +
                    (max(0, verticalBelow) / max(pageBounds.height, 1) * 20)
                appendCandidates(from: hit, baseScore: 120 - distancePenalty)
            }
        }

        let expectedSearchRect = expectedRect
            .insetBy(dx: -max(expectedRect.width * 0.75, pageBounds.width * 0.05), dy: -max(expectedRect.height * 2.0, pageBounds.height * 0.06))
            .intersection(pageBounds)
        for hit in hits where hit.rectInPage.intersects(expectedSearchRect) {
            let distance = hypot(hit.rectInPage.midX - expectedRect.midX, hit.rectInPage.midY - expectedRect.midY)
            let normalizedDistance = distance / max(hypot(pageBounds.width, pageBounds.height), 1)
            appendCandidates(from: hit, baseScore: 80 - normalizedDistance * 100)
        }

        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.token.count < rhs.token.count
        }.first?.token
    }

    private func detectAnchoredSheetTitle(on page: PDFPage, expectedRect: NSRect) -> String? {
        let hits = recognizeTextLines(in: page)
        guard !hits.isEmpty else { return nil }
        let pageBounds = zoneCaptureBounds(for: page)
        let titleLabels = hits.filter { isSheetTitleLabel($0.text) }
        let numberLabels = hits.filter { isSheetNumberLabel($0.text) }

        var scored: [(title: String, score: CGFloat)] = []
        func assembledTitle(from candidates: [OCRLineHit]) -> String? {
            let usable = candidates
                .filter { isUsableSheetTitle($0.text) }
                .filter { preferredSheetToken(from: extractSheetTokens(from: $0.text)) == nil }
                .sorted { lhs, rhs in
                    if abs(lhs.rectInPage.midY - rhs.rectInPage.midY) > pageBounds.height * 0.01 {
                        return lhs.rectInPage.midY > rhs.rectInPage.midY
                    }
                    return lhs.rectInPage.minX < rhs.rectInPage.minX
                }
            guard !usable.isEmpty else { return nil }

            let maxHeight = usable.map(\.rectInPage.height).max() ?? 0
            let titleLike = usable.filter { $0.rectInPage.height >= maxHeight * 0.55 }
            let lines = (titleLike.isEmpty ? usable : titleLike)
                .map { cleanDetectedSheetText($0.text) }
                .filter { isUsableSheetTitle($0) }
            let title = lines.joined(separator: " ")
            return isUsableSheetTitle(title) ? title : nil
        }

        func appendTitleCandidate(_ hit: OCRLineHit, baseScore: CGFloat) {
            let cleaned = cleanDetectedSheetText(hit.text)
            guard isUsableSheetTitle(cleaned) else { return }
            let sizeScore = min(hit.rectInPage.height / max(pageBounds.height, 1) * 400, 45)
            scored.append((cleaned, baseScore + sizeScore))
        }

        for label in titleLabels {
            let labelY = label.rectInPage.midY
            let nearestNumberLabel = numberLabels
                .sorted { abs($0.rectInPage.midY - labelY) < abs($1.rectInPage.midY - labelY) }
                .first
            let titleBlockCandidates: [OCRLineHit]
            if let nearestNumberLabel {
                let lowerY = min(labelY, nearestNumberLabel.rectInPage.midY)
                let upperY = max(labelY, nearestNumberLabel.rectInPage.midY)
                let minX = min(label.rectInPage.minX, nearestNumberLabel.rectInPage.minX) - pageBounds.width * 0.08
                titleBlockCandidates = hits.filter { hit in
                    guard hit.rectInPage != label.rectInPage,
                          hit.rectInPage != nearestNumberLabel.rectInPage else { return false }
                    let centerY = hit.rectInPage.midY
                    return centerY > lowerY + pageBounds.height * 0.01 &&
                        centerY < upperY - pageBounds.height * 0.01 &&
                        hit.rectInPage.maxX >= minX
                }
            } else {
                titleBlockCandidates = hits.filter { hit in
                    guard hit.rectInPage != label.rectInPage else { return false }
                    let verticalDistance = abs(hit.rectInPage.midY - labelY)
                    return verticalDistance <= pageBounds.height * 0.30 &&
                        hit.rectInPage.maxX >= label.rectInPage.minX - pageBounds.width * 0.08
                }
            }
            if let title = assembledTitle(from: titleBlockCandidates) {
                scored.append((title, 170))
            }

            for hit in titleBlockCandidates {
                let centerY = hit.rectInPage.midY
                let distancePenalty = abs(centerY - labelY) / max(pageBounds.height, 1) * 40
                appendTitleCandidate(hit, baseScore: 110 - distancePenalty)
            }
        }

        let expectedSearchRect = expectedRect
            .insetBy(dx: -max(expectedRect.width * 0.35, pageBounds.width * 0.04), dy: -max(expectedRect.height * 1.25, pageBounds.height * 0.04))
            .intersection(pageBounds)
        let expectedHits = hits.filter { $0.rectInPage.intersects(expectedSearchRect) }
        if let title = assembledTitle(from: expectedHits) {
            scored.append((title, 120))
        }
        for hit in expectedHits {
            let distance = hypot(hit.rectInPage.midX - expectedRect.midX, hit.rectInPage.midY - expectedRect.midY)
            let normalizedDistance = distance / max(hypot(pageBounds.width, pageBounds.height), 1)
            appendTitleCandidate(hit, baseScore: 70 - normalizedDistance * 80)
        }

        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.title.count > rhs.title.count
        }.first?.title
    }

    private func hyperlinkActivationBounds(for rawBounds: NSRect, token: String) -> NSRect {
        _ = token
        // Keep link hitboxes tight to detected text to avoid vertical drift from OCR marker biasing.
        return rawBounds.insetBy(dx: -1.5, dy: -1.0).standardized
    }

    private func extractSheetTokens(from raw: String) -> [String] {
        let cleaned = cleanDetectedSheetText(raw).uppercased()
        guard !cleaned.isEmpty else { return [] }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:()[]{}|/\\"))
        var candidates = cleaned.components(separatedBy: separators).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-_/\\"))
        }.filter { !$0.isEmpty }
        // Tiny marker OCR often returns split tokens like "A3 01"; keep a compact fallback.
        let compactAlnum = cleaned.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        if compactAlnum.count >= 3,
           compactAlnum.range(of: #"[A-Z]"#, options: .regularExpression) != nil,
           compactAlnum.range(of: #"\d"#, options: .regularExpression) != nil {
            candidates.append(compactAlnum)
        }

        var matches: [String] = []
        matches.reserveCapacity(candidates.count)
        let mergedTokenRegex = try? NSRegularExpression(pattern: #"[A-Z]{1,4}\d{1,3}[._\-]\d{1,3}"#)
        for token in candidates {
            if token.range(of: #"\d"#, options: .regularExpression) != nil,
               token.range(of: #"[A-Z]"#, options: .regularExpression) != nil,
               (token.contains("-") || token.contains(".")) {
                matches.append(token)
            }
            // OCR can merge detail+sheet into one token, e.g. "1A3.01" or "A-1A3.01".
            if let regex = mergedTokenRegex {
                let nsToken = token as NSString
                let ranges = regex.matches(in: token, range: NSRange(location: 0, length: nsToken.length))
                for range in ranges where range.range.location != NSNotFound && range.range.length > 0 {
                    matches.append(nsToken.substring(with: range.range))
                }
            }
        }
        if matches.isEmpty {
            for token in candidates {
                if token.range(of: #"\d"#, options: .regularExpression) != nil ||
                   token.range(of: #"[A-Z]"#, options: .regularExpression) != nil {
                    matches.append(token)
                }
            }
        }
        var deduped: [String] = []
        var seen = Set<String>()
        for token in matches where !seen.contains(token) {
            seen.insert(token)
            deduped.append(token)
        }
        return deduped
    }

    private func canonicalizeSheetToken(_ token: String) -> String {
        let upper = token.uppercased()
        var canonical = upper.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        // OCR confusion guardrails for tiny callout bubbles:
        // O often appears instead of 0, and I/L instead of 1.
        canonical = canonical.replacingOccurrences(of: "O", with: "0")
        canonical = canonical.replacingOccurrences(of: "I", with: "1")
        canonical = canonical.replacingOccurrences(of: "L", with: "1")
        return canonical
    }

    private func scoreSheetToken(
        _ token: String,
        labelCanonicalTokens: Set<String> = [],
        knownCanonicalTokens: Set<String> = []
    ) -> Int {
        if isOrdinalFloorToken(token) || isCommonTitleWordToken(token) {
            return -100
        }
        let canonical = canonicalizeSheetToken(token)
        let hasLetter = token.range(of: #"[A-Z]"#, options: .regularExpression) != nil
        let hasDigit = token.range(of: #"\d"#, options: .regularExpression) != nil
        if hasLetter && !hasDigit && !labelCanonicalTokens.contains(canonical) && !knownCanonicalTokens.contains(canonical) {
            return -80
        }
        var value = 0
        if !canonical.isEmpty, labelCanonicalTokens.contains(canonical) {
            value += 100
        }
        if !canonical.isEmpty, knownCanonicalTokens.contains(canonical) {
            value += 30
        }
        if token.range(of: #"[A-Z]{1,4}\d{1,3}[._\-]\d{1,3}"#, options: .regularExpression) != nil {
            value += 40
        }
        if token.contains(".") || token.contains("-") {
            value += 15
        }
        if canonical.count >= 3, canonical.count <= 10 {
            value += 10
        }
        if hasDigit {
            value += 10
        }
        if hasLetter {
            value += 10
        }
        if canonical.count > 14 {
            value -= 30
        }
        // If it's just numbers or just letters, it's still potentially a sheet token,
        // just not as "canonical" as a mix like A101.
        if hasLetter && hasDigit {
            value += 20
        }
        return value
    }

    private func isOrdinalFloorToken(_ token: String) -> Bool {
        token.uppercased().range(of: #"^\d{1,2}(ST|ND|RD|TH)$"#, options: .regularExpression) != nil
    }

    private func isCommonTitleWordToken(_ token: String) -> Bool {
        let normalized = normalizedOCRLabelText(token)
        let rejected: Set<String> = [
            "PLAN", "FLOOR", "FOUNDATION", "FRAMING", "LONGITUDINAL", "REINFORCING",
            "LAYOUT", "DETAILS", "DETAIL", "GENERAL", "NOTES", "INFO", "CONCRETE",
            "WOOD", "TYP", "TITLE", "SHEET"
        ]
        return rejected.contains(normalized)
    }

    private func normalizedOCRLabelText(_ text: String) -> String {
        text.uppercased()
            .replacingOccurrences(of: "0", with: "O")
            .replacingOccurrences(of: #"[^A-Z]"#, with: "", options: .regularExpression)
    }

    private func isSheetNumberLabel(_ text: String) -> Bool {
        let normalized = normalizedOCRLabelText(text)
        return normalized.contains("SHEETNO") ||
            normalized.contains("SHEETNUMBER") ||
            normalized.contains("SHEETNUM") ||
            normalized.contains("SHEETN")
    }

    private func isSheetTitleLabel(_ text: String) -> Bool {
        let normalized = normalizedOCRLabelText(text)
        return normalized.contains("SHEETTITLE") ||
            normalized.contains("SHEETNAME")
    }

    private func isUsableSheetTitle(_ text: String) -> Bool {
        let cleaned = cleanDetectedSheetText(text)
        guard cleaned.count >= 3 else { return false }
        let normalized = normalizedOCRLabelText(cleaned)
        guard !normalized.isEmpty else { return false }
        if isSheetTitleLabel(cleaned) || isSheetNumberLabel(cleaned) { return false }
        let rejected = ["PLOTDATE", "SCALE", "PROJECT", "REVISIONS", "DRAWNBY", "CHECKEDBY"]
        if rejected.contains(where: { normalized.contains($0) }) { return false }
        if preferredSheetToken(from: extractSheetTokens(from: cleaned)) == cleaned.uppercased() { return false }
        return true
    }

    private func preferredSheetToken(
        from candidates: [String],
        labelCanonicalTokens: Set<String> = [],
        knownCanonicalTokens: Set<String> = []
    ) -> String? {
        candidates
            .filter { scoreSheetToken($0, labelCanonicalTokens: labelCanonicalTokens, knownCanonicalTokens: knownCanonicalTokens) > 0 }
            .sorted { lhs, rhs in
                let lhsScore = scoreSheetToken(lhs, labelCanonicalTokens: labelCanonicalTokens, knownCanonicalTokens: knownCanonicalTokens)
                let rhsScore = scoreSheetToken(rhs, labelCanonicalTokens: labelCanonicalTokens, knownCanonicalTokens: knownCanonicalTokens)
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }
                if lhs.count != rhs.count {
                    return lhs.count < rhs.count
                }
                return lhs < rhs
            }
            .first
    }

    private func supplementSheetTokenMapFromExistingLabelsAndBookmarks(
        document: PDFDocument,
        sheetTokenToPageIndex: inout [String: Int],
        canonicalSheetTokenToPageIndex: inout [String: Int],
        tokenConfidenceByToken: inout [String: Int],
        tokenConfidenceByCanonical: inout [String: Int]
    ) {
        func preferredSupplementToken(from label: String) -> String? {
            let cleaned = cleanDetectedSheetText(label)
            guard !cleaned.isEmpty else { return nil }
            if let pageLabelNumber = sheetInfoFromPageLabel(cleaned).number {
                return pageLabelNumber
            }
            return preferredSheetToken(from: extractSheetTokens(from: cleaned))
        }

        func recordSupplementToken(_ token: String, pageIndex: Int, confidence: Int) {
            let existingTokenConfidence = tokenConfidenceByToken[token] ?? 0
            if existingTokenConfidence <= confidence {
                sheetTokenToPageIndex[token] = pageIndex
                tokenConfidenceByToken[token] = confidence
            }

            let canonical = canonicalizeSheetToken(token)
            guard !canonical.isEmpty else { return }
            let existingCanonicalConfidence = tokenConfidenceByCanonical[canonical] ?? 0
            if existingCanonicalConfidence <= confidence {
                canonicalSheetTokenToPageIndex[canonical] = pageIndex
                tokenConfidenceByCanonical[canonical] = confidence
            }
        }

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex),
                  let token = preferredSupplementToken(from: page.label ?? "")
            else { continue }
            recordSupplementToken(token, pageIndex: pageIndex, confidence: 4)
        }

        func walkOutline(_ outline: PDFOutline?) {
            guard let outline else { return }
            if let pageIndex = destinationPageIndex(for: outline),
               pageIndex >= 0,
               pageIndex < document.pageCount,
               let token = preferredSupplementToken(from: outline.label ?? "") {
                recordSupplementToken(token, pageIndex: pageIndex, confidence: 3)
            }
            guard outline.numberOfChildren > 0 else { return }
            for childIndex in 0..<outline.numberOfChildren {
                walkOutline(outline.child(at: childIndex))
            }
        }

        walkOutline(document.outlineRoot)
    }

    private func selectableSheetTokenHits(on page: PDFPage) -> [(token: String, bounds: NSRect)] {
        guard let pageText = page.string, !pageText.isEmpty else { return [] }
        let nsText = pageText as NSString
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9][A-Za-z0-9._\-]{1,}"#) else { return [] }
        let matches = regex.matches(in: pageText, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return [] }

        var hits: [(token: String, bounds: NSRect)] = []
        hits.reserveCapacity(matches.count)
        var seen = Set<String>()
        for match in matches {
            let rawCandidate = nsText.substring(with: match.range)
            let tokens = extractSheetTokens(from: rawCandidate)
            guard !tokens.isEmpty,
                  let selection = page.selection(for: match.range) else { continue }
            let bounds = selection.bounds(for: page).insetBy(dx: -1.5, dy: -1.0)
            guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
            for token in tokens {
                let key = "\(token):\(bounds.origin.x.rounded()):\(bounds.origin.y.rounded()):\(bounds.width.rounded()):\(bounds.height.rounded())"
                if seen.contains(key) { continue }
                seen.insert(key)
                hits.append((token: token, bounds: bounds))
            }
        }
        return hits
    }

    private func recognizeTextLines(in page: PDFPage, customWords: [String] = []) -> [OCRLineHit] {
        let words = Array(Set(customWords.filter { !$0.isEmpty }))
        let primary = recognizeTextLines(
            in: page,
            scale: 3.0,
            minimumTextHeight: 0.004,
            recognitionLevel: .accurate,
            customWords: words
        )
        if !primary.isEmpty {
            return primary
        }
        return recognizeTextLines(
            in: page,
            scale: 4.0,
            minimumTextHeight: 0.003,
            recognitionLevel: .accurate,
            customWords: words
        )
    }

    private func recognizeTextLines(
        in page: PDFPage,
        scale: CGFloat,
        minimumTextHeight: Float,
        recognitionLevel: VNRequestTextRecognitionLevel,
        customWords: [String]
    ) -> [OCRLineHit] {
        let displayBox: PDFDisplayBox = .mediaBox
        let pageBounds = page.bounds(for: displayBox)
        guard pageBounds.width > 1, pageBounds.height > 1 else { return [] }
        let pageTransform = page.transform(for: displayBox)
        let orientedFullBox = pageBounds.applying(pageTransform).standardized
        guard orientedFullBox.width > 1, orientedFullBox.height > 1 else { return [] }
        let width = Int((orientedFullBox.width * scale).rounded(.up))
        let height = Int((orientedFullBox.height * scale).rounded(.up))
        guard width > 0, height > 0 else { return [] }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return []
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -orientedFullBox.minX, y: -orientedFullBox.minY)
        page.draw(with: displayBox, to: context)
        guard let image = context.makeImage() else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = false
        request.minimumTextHeight = minimumTextHeight
        if !customWords.isEmpty {
            request.customWords = customWords
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observations = request.results, !observations.isEmpty else { return [] }

        var hits: [OCRLineHit] = []
        hits.reserveCapacity(observations.count)
        let imageWidth = CGFloat(width)
        let imageHeight = CGFloat(height)
        let inversePageTransform = pageTransform.inverted()
        for observation in observations {
            let box = observation.boundingBox
            let rectPx = NSRect(
                x: box.minX * imageWidth,
                y: box.minY * imageHeight,
                width: box.width * imageWidth,
                height: box.height * imageHeight
            )
            let rectInOrientedPage = NSRect(
                x: orientedFullBox.minX + rectPx.minX / scale,
                y: orientedFullBox.minY + rectPx.minY / scale,
                width: rectPx.width / scale,
                height: rectPx.height / scale
            )
            let rectInPage = rectInOrientedPage.applying(inversePageTransform).standardized
            guard rectInPage.width > 1, rectInPage.height > 1 else { continue }
            guard let top = observation.topCandidates(1).first else { continue }
            let text = cleanDetectedSheetText(top.string)
            guard !text.isEmpty else { continue }
            hits.append(OCRLineHit(text: text, rectInPage: rectInPage))
        }
        return hits
    }

    private func applyAutoNamedSheets(_ sheets: [AutoNamedSheet], to document: PDFDocument, applyPageLabels: Bool) {
        if applyPageLabels {
            pageLabelOverrides.removeAll()
            for sheet in sheets {
                let cleanedTitle = sheet.sheetTitle.isEmpty ? "Untitled" : sheet.sheetTitle
                pageLabelOverrides[sheet.pageIndex] = "\(sheet.sheetNumber) - \(cleanedTitle)"
            }
            applyPageLabelOverridesToDocumentIfNeeded(document)
        }

        let root = PDFOutline()
        for sheet in sheets {
            guard let page = document.page(at: sheet.pageIndex) else { continue }
            let item = PDFOutline()
            let cleanedTitle = sheet.sheetTitle.isEmpty ? "Untitled" : sheet.sheetTitle
            item.label = "\(sheet.sheetNumber) - \(cleanedTitle)"
            item.destination = bookmarkStyleDestination(for: page)
            root.insertChild(item, at: root.numberOfChildren)
        }
        document.outlineRoot = root

        markMarkupChangedAndScheduleAutosave()
        reloadBookmarks()
        updateStatusBar()

        let informativeText: String
        if applyPageLabels {
            informativeText = "Applied bookmarks and page labels for \(sheets.count) pages."
        } else {
            informativeText = "Applied bookmarks for \(sheets.count) pages."
        }
        runAlert(title: "Sheet Names Updated", informativeText: informativeText)

    }

    private func promptFinalizeExportToIPadSave(document: PDFDocument) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.prompt = "Save"
        if let suggested = pendingExportToIPadSuggestedFilename, !suggested.isEmpty {
            savePanel.nameFieldStringValue = suggested
        } else {
            savePanel.nameFieldStringValue = "Drawbridge-iPhone-iPad.pdf"
        }
        guard savePanel.runModal() == .OK, let finalURL = savePanel.url else {
            pendingExportToIPadTemporaryURL = nil
            pendingExportToIPadSuggestedFilename = nil
            return
        }

        let temporaryURL = pendingExportToIPadTemporaryURL
        pendingExportToIPadTemporaryURL = nil
        pendingExportToIPadSuggestedFilename = nil

        persistDocument(
            to: finalURL,
            adoptAsPrimaryDocument: true,
            busyMessage: "Saving PDF…",
            document: document,
            showBusyOverlay: true,
            deferEmbeddedWrite: false
        ) { [weak self] success in
            guard success, let self, let temporaryURL else { return }
            self.unregisterSessionDocument(temporaryURL)
            if temporaryURL.standardizedFileURL != finalURL.standardizedFileURL,
               FileManager.default.fileExists(atPath: temporaryURL.path) {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
    }

    private func clearAllBookmarks(in document: PDFDocument) {
        document.outlineRoot = PDFOutline()
        bookmarkLabelOverrides.removeAll()
        pageLabelOverrides.removeAll()
        markMarkupChangedAndScheduleAutosave()
        reloadBookmarks()
        updateStatusBar()
    }

    private func zoneCaptureBounds(for page: PDFPage) -> NSRect {
        page.bounds(for: pdfView.displayBox).standardized
    }

    private func normalize(rectInPage: NSRect, for page: PDFPage) -> NormalizedPageRect {
        let bounds = zoneCaptureBounds(for: page)
        let bounded = rectInPage.standardized.intersection(bounds)
        guard !bounded.isEmpty else {
            return NormalizedPageRect(x: 0, y: 0, width: 0, height: 0)
        }
        let safeWidth = max(bounds.width, 1)
        let safeHeight = max(bounds.height, 1)

        // Anchor to Bottom-Right for architectural stability.
        // x is distance from RIGHT edge, y is distance from BOTTOM edge.
        return NormalizedPageRect(
            x: (bounds.maxX - bounded.maxX) / safeWidth,
            y: (bounded.minY - bounds.minY) / safeHeight,
            width: bounded.width / safeWidth,
            height: bounded.height / safeHeight
        )
    }

    private func denormalize(rect: NormalizedPageRect, for page: PDFPage) -> NSRect {
        let bounds = zoneCaptureBounds(for: page)
        let width = rect.width * bounds.width
        let height = rect.height * bounds.height

        // Re-calculate based on distance from right and bottom.
        let maxX = bounds.maxX - (rect.x * bounds.width)
        let minX = maxX - width
        let minY = bounds.minY + (rect.y * bounds.height)

        return NSRect(
            x: minX,
            y: minY,
            width: width,
            height: height
        )
    }

    private func zoneDetectionCandidates(for page: PDFPage, normalizedZone: NormalizedPageRect) -> [ZoneDetectionCandidate] {
        let pageBounds = zoneCaptureBounds(for: page)
        let baseRect = denormalize(rect: normalizedZone, for: page).standardized.intersection(pageBounds)
        guard !baseRect.isEmpty, baseRect.width > 1, baseRect.height > 1 else {
            return []
        }

        let nudgeX = max(pageBounds.width * 0.0125, 2.0)
        let nudgeY = max(pageBounds.height * 0.0100, 2.0)
        let expandX = max(baseRect.width * 0.08, pageBounds.width * 0.006)
        let expandY = max(baseRect.height * 0.15, pageBounds.height * 0.008)
        var candidates: [ZoneDetectionCandidate] = []
        var seen = Set<String>()

        func appendCandidate(rect: NSRect, strategy: String, allowOCR: Bool, usedFallback: Bool) {
            let bounded = rect.standardized.intersection(pageBounds).standardized
            guard !bounded.isEmpty, bounded.width > 1, bounded.height > 1 else { return }
            let key = "\(Int((bounded.minX * 4).rounded())):\(Int((bounded.minY * 4).rounded())):\(Int((bounded.width * 4).rounded())):\(Int((bounded.height * 4).rounded())):\(allowOCR)"
            guard !seen.contains(key) else { return }
            seen.insert(key)
            candidates.append(
                ZoneDetectionCandidate(
                    rectInPage: bounded,
                    strategy: strategy,
                    allowOCR: allowOCR,
                    usedFallback: usedFallback
                )
            )
        }

        appendCandidate(rect: baseRect, strategy: "primary zone", allowOCR: true, usedFallback: false)
        appendCandidate(rect: baseRect.offsetBy(dx: nudgeX, dy: 0), strategy: "nudged right", allowOCR: false, usedFallback: true)
        appendCandidate(rect: baseRect.offsetBy(dx: -nudgeX, dy: 0), strategy: "nudged left", allowOCR: false, usedFallback: true)
        appendCandidate(rect: baseRect.offsetBy(dx: 0, dy: nudgeY), strategy: "nudged up", allowOCR: false, usedFallback: true)
        appendCandidate(rect: baseRect.offsetBy(dx: 0, dy: -nudgeY), strategy: "nudged down", allowOCR: false, usedFallback: true)

        let expandedRect = baseRect.insetBy(dx: -expandX, dy: -expandY)
        appendCandidate(rect: expandedRect, strategy: "expanded zone (selection)", allowOCR: false, usedFallback: true)
        appendCandidate(rect: expandedRect, strategy: "expanded zone (OCR)", allowOCR: true, usedFallback: true)
        return candidates
    }

    private func detectSheetTokensInCapturedZone(
        on page: PDFPage,
        normalizedZone: NormalizedPageRect
    ) -> (result: ZoneDetectionResult?, rawTextPreview: String, failureReason: String?) {
        let candidates = zoneDetectionCandidates(for: page, normalizedZone: normalizedZone)
        guard !candidates.isEmpty else {
            return (nil, "", "Captured zone is outside the visible page bounds.")
        }

        var firstNonEmptyRawText: String?
        var firstNonEmptyStrategy: String?
        for candidate in candidates {
            let raw = extractText(
                from: page,
                rectInPage: candidate.rectInPage,
                allowOCR: candidate.allowOCR,
                preferOCR: candidate.allowOCR
            )
            guard !raw.isEmpty else { continue }
            if firstNonEmptyRawText == nil {
                firstNonEmptyRawText = raw
                firstNonEmptyStrategy = candidate.strategy
            }
            let tokens = extractSheetTokens(from: raw)
            guard !tokens.isEmpty else { continue }
            return (
                ZoneDetectionResult(
                    tokens: tokens,
                    rawText: raw,
                    strategy: candidate.strategy,
                    usedFallback: candidate.usedFallback
                ),
                "",
                nil
            )
        }

        if let firstNonEmptyRawText {
            let reasonSuffix = firstNonEmptyStrategy.map { " (\($0))." } ?? "."
            return (
                nil,
                truncatedZoneDiagnosticText(firstNonEmptyRawText),
                "Text found, but no valid sheet token was parsed\(reasonSuffix)"
            )
        }
        return (nil, "", "No text found in the captured zone.")
    }

    private func truncatedZoneDiagnosticText(_ raw: String, limit: Int = 64) -> String {
        let cleaned = cleanDetectedSheetText(raw)
        guard cleaned.count > limit else { return cleaned }
        let endIndex = cleaned.index(cleaned.startIndex, offsetBy: limit)
        return "\(cleaned[..<endIndex])..."
    }

    private func extractText(from page: PDFPage, rectInPage: NSRect, allowOCR: Bool = true, preferOCR: Bool = false, usesLanguageCorrection: Bool = false) -> String {
        let displayBox = pdfView.displayBox
        let pageBounds = page.bounds(for: displayBox)
        let bounded = rectInPage.intersection(pageBounds)
        guard !bounded.isEmpty else { return "" }

        if preferOCR,
           allowOCR,
           let image = renderCroppedImage(from: page, rectInPage: bounded) {
            let recognized = recognizeText(in: image, usesLanguageCorrection: usesLanguageCorrection)
            if !recognized.isEmpty {
                // Heuristic for titles: if we get a huge block of text, try to find a shorter "title-like" line.
                if usesLanguageCorrection && recognized.count > 120 && recognized.contains("\n") {
                    let lines = recognized.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    // Prefer the first line if it looks like a title (shorter, uppercase)
                    if let first = lines.first, first.count < 80 {
                        return first
                    }
                }
                return recognized
            }
        }

        if let selected = page.selection(for: bounded)?.string {
            let cleaned = cleanDetectedSheetText(selected)
            if !cleaned.isEmpty {
                return cleaned
            }
        }

        guard allowOCR else { return "" }

        guard let image = renderCroppedImage(from: page, rectInPage: bounded) else {
            return ""
        }
        return recognizeText(in: image, usesLanguageCorrection: usesLanguageCorrection)
    }

    private func renderCroppedImage(from page: PDFPage, rectInPage: NSRect) -> CGImage? {
        let displayBox = pdfView.displayBox
        let scale: CGFloat = 4.0

        // 1. Get the oriented box dimensions
        let transform = page.transform(for: displayBox)
        let orientedFullBox = page.bounds(for: displayBox).applying(transform).standardized

        let widthPx = Int((orientedFullBox.width * scale).rounded(.up))
        let heightPx = Int((orientedFullBox.height * scale).rounded(.up))

        // Safety cap for massive scans
        guard widthPx > 0, heightPx > 0, widthPx < 12000, heightPx < 12000 else { return nil }

        // 2. Render the ENTIRE oriented page box. This is the only way to guarantee alignment.
        guard let fullContext = CGContext(
            data: nil,
            width: widthPx,
            height: heightPx,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        fullContext.interpolationQuality = .high
        fullContext.setFillColor(NSColor.white.cgColor)
        fullContext.fill(CGRect(x: 0, y: 0, width: widthPx, height: heightPx))
        fullContext.scaleBy(x: scale, y: scale)
        fullContext.translateBy(x: -orientedFullBox.minX, y: -orientedFullBox.minY)

        // PDFPage.draw handles orientation into the target context box perfectly.
        page.draw(with: displayBox, to: fullContext)

        guard let fullImage = fullContext.makeImage() else { return nil }

        // 3. Crop at the pixel level using CIImage (top-down coordinates matched to our render)
        let orientedCrop = rectInPage.applying(transform).standardized
        let ciImage = CIImage(cgImage: fullImage)
        let cropRectPx = CGRect(
            x: (orientedCrop.minX - orientedFullBox.minX) * scale,
            y: (orientedCrop.minY - orientedFullBox.minY) * scale,
            width: orientedCrop.width * scale,
            height: orientedCrop.height * scale
        ).intersection(ciImage.extent)
        guard !cropRectPx.isEmpty else { return nil }

        let croppedCI = ciImage.cropped(to: cropRectPx)

        // 4. Enhance
        let colorControls = CIFilter(name: "CIColorControls")
        colorControls?.setValue(croppedCI, forKey: kCIInputImageKey)
        colorControls?.setValue(1.15, forKey: kCIInputContrastKey)
        colorControls?.setValue(0.0, forKey: kCIInputSaturationKey)

        let ciContext = CIContext()
        if let enhanced = colorControls?.outputImage,
           let finalCG = ciContext.createCGImage(enhanced, from: enhanced.extent) {
            return finalCG
        }

        return ciContext.createCGImage(croppedCI, from: croppedCI.extent)
    }

    private func recognizeText(in image: CGImage, usesLanguageCorrection: Bool = false) -> String {
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .left, .down]
        var bestText = ""
        var bestScore: Float = -.greatestFiniteMagnitude

        for orientation in orientations {
            guard let result = recognizeText(in: image, orientation: orientation, usesLanguageCorrection: usesLanguageCorrection) else { continue }
            if result.score > bestScore {
                bestScore = result.score
                bestText = result.text
            }
        }
        return bestText
    }

    private func recognizeText(in image: CGImage, orientation: CGImagePropertyOrientation, usesLanguageCorrection: Bool) -> (text: String, score: Float)? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = usesLanguageCorrection

        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
            guard let observations = request.results, !observations.isEmpty else { return nil }

            // --- Title Isolation Heuristic ---
            // Architectural labels (SHEET TITLE:, etc) are usually smaller than the actual title.
            // We find the max height and filter out noise.
            let maxHeight = observations.map { $0.boundingBox.height }.max() ?? 0
            let heightThreshold = maxHeight * 0.75

            var pieces: [String] = []
            pieces.reserveCapacity(observations.count)
            var confidenceSum: Float = 0
            var recognizedCount: Float = 0
            for observation in observations {
                // Skip if this looks like a smaller label rather than the main content
                if observation.boundingBox.height < heightThreshold { continue }

                guard let top = observation.topCandidates(1).first else { continue }
                let cleaned = cleanDetectedSheetText(top.string)
                guard !cleaned.isEmpty else { continue }
                pieces.append(cleaned)
                confidenceSum += top.confidence
                recognizedCount += 1
            }
            guard !pieces.isEmpty else { return nil }
            let text = cleanDetectedSheetText(pieces.joined(separator: " "))
            guard !text.isEmpty else { return nil }

            let averageConfidence = recognizedCount > 0 ? (confidenceSum / recognizedCount) : 0
            let usefulChars = text.unicodeScalars.reduce(0) { partial, scalar in
                CharacterSet.alphanumerics.contains(scalar) ? partial + 1 : partial
            }
            let textQualityBoost = min(Float(usefulChars) / 48.0, 1.25)
            return (text, averageConfidence + textQualityBoost)
        } catch {
            return nil
        }
    }

    private func scrubArchitecturalBoilerplate(_ raw: String) -> String {
        var text = raw

        // 1. Remove sequences of dots, underscores, or dashes (lines), even with spaces
        let linePatterns = ["([\\.\\s]{2,})", "([_\\s]{2,})", "([-]{3,})"]
        for pattern in linePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
            }
        }

        // 2. Remove common title block phrases (case-insensitive)
        let phrases = [
            "SHEET TITLE", "SHEET NAME", "SHEET NO", "SHEET NUMBER",
            "PROJECT NAME", "PROJECT NO", "PROJECT NUMBER",
            "DRAWN BY", "CHECKED BY"
        ]

        for phrase in phrases {
            let pattern = "(?i)\\b\(phrase)\\b[:\\s]*"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
            }
        }

        // 3. Remove standalone labels ONLY if followed by a colon or significant space
        let labels = [
            "SHEET", "TITLE", "PROJECT", "DATE", "SCALE", "REVISIONS",
            "CONSULTANT", "OWNER", "CLIENT", "COPYRIGHT", "NOTES",
            "CHILE", "HILE", "TIILE", "TILE", "OnL", "OnCE", "SREET"
        ]
        for label in labels {
            // Only remove if it has a colon or is followed by significant space/dots
            let pattern = "(?i)\\b\(label)\\b[:\\s]{2,}|(?i)\\b\(label)\\b:"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
            }
        }

        // 4. Final cleanup
        text = text.replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(of: "\t", with: " ")

        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let punctuation = CharacterSet(charactersIn: ":;.,-_ ")
        text = text.trimmingCharacters(in: punctuation)

        return text
    }

    private func cleanDetectedSheetText(_ raw: String) -> String {
        scrubArchitecturalBoilerplate(raw)
    }



    private func csvEscape(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private func updateEmptyStateVisibility() {
        if let document = pdfView.document, document.pageCount == 0 {
            // A zero-page PDF object is not actionable in the UI; treat it as no document.
            pdfView.document = nil
        }
        let hasDocument = (pdfView.document != nil)
        emptyStateView.isHidden = hasDocument
        emptyStateSampleButton.isEnabled = true
        pdfView.isHidden = !hasDocument
        bookmarksContainer.isHidden = !showNavigationPane
        navigationResizeHandle.isHidden = !showNavigationPane
        bookmarksWidthConstraint?.constant = showNavigationPane ? navigationWidth : 0
        didApplyInitialSplitLayout = false
        applySplitLayoutIfPossible(force: true)
        view.layoutSubtreeIfNeeded()
        requestChromeRefresh()
    }

    func hasUnsavedChanges() -> Bool {
        view.window?.isDocumentEdited == true
    }

    func confirmDiscardUnsavedChangesIfNeeded() -> Bool {
        // If Save is currently writing, wait before allowing close/quit so users cannot
        // close into an out-of-date on-disk PDF state.
        if isSavingDocumentOperation || persistenceCoordinator.isManualSaveInFlight {
            guard waitForInFlightSaveToSettle() else {
                runAlert(
                    title: "Save Still In Progress",
                    informativeText: "Drawbridge is still writing your PDF. Please wait a moment and try again.",
                    style: .warning
                )
                return false
            }
        }

        guard hasUnsavedChanges() else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "You have unsaved changes."
        alert.informativeText = "Save changes before continuing?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            return saveCurrentDocumentForClosePrompt()
        }
        if response == .alertSecondButtonReturn {
            return true
        }
        return false
    }

}
