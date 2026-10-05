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
    struct PDFDocumentBox: @unchecked Sendable {
        let document: PDFDocument
    }
    struct NormalizedPageRect {
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

    private let autosaveIntervalSeconds: TimeInterval = 120
    let snapshotStore = ProjectSnapshotStore()
    private let chromeBackgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
    private let panelBackgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1.0)
    private let sidebarBackgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1.0)

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

    private let showNavigationPane = true
    let pdfView = MarkupPDFView(frame: .zero)
    private let pdfCanvasContainer = StartupDropView(frame: .zero)
    private let bookmarksContainer = NSView(frame: .zero)
    private let navigationResizeHandle = NavigationResizeHandleView(frame: .zero)
    private let navigationTitleLabel = NSTextField(labelWithString: "Navigation")
    private let navigationModeControl = NSSegmentedControl(labels: ["Pages", "Bookmarks"], trackingMode: .selectOne, target: nil, action: nil)
    private let addPageButton = NSButton(title: "", target: nil, action: nil)
    private let pagesTableView = NSTableView(frame: .zero)
    private let thumbnailScrollView = NSScrollView(frame: .zero)
    private let thumbnailsEmptyLabel = NSTextField(labelWithString: "No Pages")
    private let bookmarksScrollView = NSScrollView(frame: .zero)
    let bookmarksOutlineView = NSOutlineView(frame: .zero)
    private let bookmarksEmptyLabel = NSTextField(labelWithString: "No Bookmarks")
    private let bookmarksSelectionLabel = NSTextField(labelWithString: "")
    private let pdfContentsTitleLabel = NSTextField(labelWithString: "PDF Contents")
    private weak var contentsSummaryDocument: PDFDocument?
    private var cachedContentsSummary: String?
    private let pdfContentsSummaryLabel = NSTextField(labelWithString: "No PDF loaded")
    private let splitView = NSSplitView(frame: .zero)
    private let emptyStateView = StartupDropView(frame: .zero)
    private let emptyStateTitle = NSTextField(labelWithString: "Open a drawing set to get started")
    private let emptyStateOpenButton = NSButton(title: "Open PDF", target: nil, action: nil)
    private let emptyStateRecentButton = NSButton(title: "Open Recent", target: nil, action: nil)
    private let emptyStateSampleButton = NSButton(title: "Create New", target: nil, action: nil)
    private let emptyStateBatchMobileButton = NSButton(title: "Batch Export to iPhone / iPad", target: nil, action: nil)
    let markupsTable = NSTableView(frame: .zero)
    private let markupsCountLabel = NSTextField(labelWithString: "0 items")
    let measurementScaleField = NSTextField(frame: .zero)
    let measurementUnitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let actionsPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let autoNameSheetsButton = NSButton(title: "", target: nil, action: nil)
    private let batchLinkSheetsButton = NSButton(title: "", target: nil, action: nil)
    private let flattenPDFButton = NSButton(title: "", target: nil, action: nil)
    private let previousPageButton = NSButton(title: "", target: nil, action: nil)
    private let nextPageButton = NSButton(title: "", target: nil, action: nil)
    private let navigationBackButton = NSButton(title: "", target: nil, action: nil)
    private let navigationForwardButton = NSButton(title: "", target: nil, action: nil)
    private let goToSheetButton = NSButton(title: "", target: nil, action: nil)
    private let fitPageButton = NSButton(title: "", target: nil, action: nil)
    private let reduceFileSizeButton = NSButton(title: "", target: nil, action: nil)
    private let highlightButton = NSButton(title: "Highlight Selection", target: nil, action: nil)
    private let exportButton = NSButton(title: "Save As PDF", target: nil, action: nil)
    private let gridToggleButton = NSButton(title: "", target: nil, action: nil)
    private let refreshMarkupsButton = NSButton(title: "Refresh Markups", target: nil, action: nil)
    private let deleteMarkupButton = NSButton(title: "Delete Markup", target: nil, action: nil)
    private let editMarkupButton = NSButton(title: "Edit Markup Text", target: nil, action: nil)
    let pageJumpField = ClickOnlyTextField(frame: .zero)
    let scalePresetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let toolbarControlsStack = NSStackView(frame: .zero)
    private let toolbarModeGroupsStack = NSStackView(frame: .zero)
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
    private let toolSettingsSidebarToggleButton = NSButton(title: "", target: nil, action: nil)
    private let collapsedSidebarRevealButton = NSButton(title: "", target: nil, action: nil)
    private let snapSectionContent = NSStackView(frame: .zero)
    private let snapRowsStack = NSStackView(frame: .zero)
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
    var scrollEventMonitor: Any?
    var keyEventMonitor: Any?
    private var markupFilterText = ""
    var pendingCalibrationDistanceInPoints: CGFloat?
    let rectangleToolbar = RectangleMarkupToolbar()

    var isPDFProcessingBusy: Bool { busyOperationDepth > 0 || isSavingDocumentOperation }
    private var busyOperationDepth = 0
    var markupChangeVersion = 0
    var lastAutosavedChangeVersion = 0
    var openDocumentURL: URL? { didSet { pdfView.rectangleMarkup.rememberSource(openDocumentURL) } }
    var sessionDocumentURLs: [URL] = []
    var autosaveURL: URL?
    lazy var persistenceCoordinator = DocumentPersistenceCoordinator(autosaveInterval: autosaveIntervalSeconds)
    var pendingMarkupsRefreshWorkItem: DispatchWorkItem?
    var pendingSearchWorkItem: DispatchWorkItem?
    private var pendingChromeRefreshWorkItem: DispatchWorkItem?
    let textSearch = PDFTextSearch()
    var searchResultsLimited = false
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
    var isPDFFileProcessingOperation = false
    var isSavingDocumentOperation = false
    var queuedFastEmbeddedSave = false
    var lastEmbeddedSaveCompletedVersion = 0
    private var busyInteractionLocked = false
    private var busyInputMonitor: Any?
    weak var lastDirectlySelectedAnnotation: PDFAnnotation?
    private var groupedPasteDragPageID: ObjectIdentifier?
    private var groupedPasteDragAnnotationIDs: Set<ObjectIdentifier> = []
    private var sidebarCurrentPageIndex: Int = -1
    private var bookmarkLabelOverrides: [String: String] = [:]
    var pageLabelOverrides: [Int: String] = [:]
    private var suppressedEmbeddedPageLabelIndexes: Set<Int> = []
    var hasPromptedForInitialMarkupSaveCopy = false
    var isPresentingInitialMarkupSaveCopyPrompt = false
    var isGridVisible = false
    var isHyperlinkHighlightsVisible = false
    var isPolygonVertexEditModeEnabled = false
    var isOrthoSnapEnabled = true
    private var isEndpointSnapEnabled = true
    private var isMidpointSnapEnabled = true
    private var isIntersectionSnapEnabled = true
    private var autoNameCapturePhase: AutoNameCapturePhase?
    private var autoNameReferencePageIndex: Int?
    private var pendingSheetNumberZone: NormalizedPageRect?
    private var pendingSheetTitleZone: NormalizedPageRect?
    private var autoNamePreviousToolMode: ToolMode?
    private var autoNameIgnoresExistingPageLabels = false
    private var autoLinkCaptureReferencePageIndex: Int?
    private var autoLinkPreviousToolMode: ToolMode?
    private var shouldChainAutoNameAfterBatchLink = false
    private var pendingExportToIPadTemporaryURL: URL?
    private var pendingExportToIPadSuggestedFilename: String?
    private let autoSheetLinkAnnotationMarker = "DrawbridgeAutoSheetLink"
    private var dominantDocumentPageSizeInInches: (height: CGFloat, width: CGFloat)?
    var pageScaleLocks: [Int: PageScaleLock] = [:]
    var lastScaleLockAppliedPageIndex: Int = -1
    var lastExplicitScaleSetDocumentID: ObjectIdentifier?
    var lastExplicitScaleSetPageIndex: Int = -1
    var explicitScaleSetDocumentID: ObjectIdentifier?
    var explicitScaleSetPageIndexes: Set<Int> = []
    var pendingScaleReminderSuppressionDocumentID: ObjectIdentifier?
    var pendingScaleReminderSuppressionPageIndex: Int = -1
    var pendingScaleReminderSuppressionOneShot = false
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
    private var toolbarToolButtons: [ToolMode: NSButton] = [:]
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
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applySplitLayoutIfPossible(force: false)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        watchdog?.stop()
        resetSearchState()
        stopSaveProgressTracking()
        if let monitor = scrollEventMonitor {
            NSEvent.removeMonitor(monitor)
            scrollEventMonitor = nil
        }
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
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

        toolSelector.target = self
        toolSelector.action = #selector(changeTool)
        takeoffSelector.target = self
        takeoffSelector.action = #selector(changeTakeoffTool)
        setupToolbarControlStack()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfCanvasContainer.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
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
        configureRectangleMarkup()
        pdfView.onViewportChanged = { [weak self] in
            self?.lastUserInteractionAt = Date()
            self?.requestChromeRefresh()
            self?.updateSelectionOverlay()
            self?.pdfView.refreshHyperlinkHighlights()
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
        pdfView.shouldBeginMarkupInteraction = { false }
        pdfView.layer?.addSublayer(selectedMarkupOverlayLayer)
        pdfView.layer?.addSublayer(selectedTextOverlayLayer)
        pdfView.layer?.addSublayer(selectedLineEndpointHaloLayer)
        pdfView.layer?.addSublayer(selectedLineEndpointOverlayLayer)
        pdfView.setHyperlinkHighlightsVisible(isHyperlinkHighlightsVisible)

        view.addSubview(splitView)
        view.addSubview(documentTabsBar)
        view.addSubview(statusBar)
        configureStatusBar()
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

        let pagesControlRow = NSStackView(views: [navigationModeControl, NSView()])
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
        bookmarksOutlineView.allowsMultipleSelection = true
        bookmarksOutlineView.focusRingType = .none
        bookmarksOutlineView.style = .sourceList
        // A visible row fill is essential here: the outline supports range and
        // discontiguous selection for bulk deletion, so a focus ring alone is
        // not enough feedback about what a command will affect.
        bookmarksOutlineView.selectionHighlightStyle = .regular
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
        bookmarksContextMenu.addItem(NSMenuItem.separator())
        let deleteBookmarkItem = NSMenuItem(title: "Delete Selected Bookmark(s)…", action: #selector(deleteBookmarkFromSidebar), keyEquivalent: "")
        deleteBookmarkItem.target = self
        bookmarksContextMenu.addItem(deleteBookmarkItem)
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
        bookmarksSelectionLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        bookmarksSelectionLabel.textColor = .systemBlue
        bookmarksSelectionLabel.alignment = .center
        bookmarksSelectionLabel.lineBreakMode = .byTruncatingTail
        bookmarksSelectionLabel.isHidden = true
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
            bookmarksSelectionLabel,
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
        updateBookmarkSelectionPresentation()
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
        updateBookmarkSelectionPresentation()
        addPageButton.isHidden = true
        addPageButton.isEnabled = false
    }

    @objc private func addPageFromNavigation() {
        // Compatibility entry point: annotation authoring is unavailable.
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
        updateBookmarkSelectionPresentation()
    }

    private func updateBookmarkSelectionPresentation() {
        let selectedCount = bookmarksOutlineView.selectedRowIndexes.count
        let shouldShow = navigationModeControl.selectedSegment == 1 && selectedCount > 1
        bookmarksSelectionLabel.isHidden = !shouldShow
        guard shouldShow else { return }
        bookmarksSelectionLabel.stringValue = "(selectedCount) bookmarks selected • Delete to remove"
    }

    func updatePDFContentsSummary() {
        guard let document = pdfView.document else {
            pdfContentsSummaryLabel.stringValue = "No PDF loaded"
            return
        }

        if contentsSummaryDocument === document, let cachedContentsSummary {
            pdfContentsSummaryLabel.stringValue = cachedContentsSummary
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
        let summary = lines.joined(separator: "\n")
        contentsSummaryDocument = document
        cachedContentsSummary = summary
        pdfContentsSummaryLabel.stringValue = summary
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
        guard bookmarksOutlineView.selectedRowIndexes.count == 1 else { return }
        let row = bookmarksOutlineView.selectedRow
        guard row >= 0,
              let outline = bookmarksOutlineView.item(atRow: row) as? PDFOutline,
              let destination = outline.destination else {
            return
        }
        pdfView.navigateToDestinationWithHistory(destination)
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
                suppressedEmbeddedPageLabelIndexes.remove(pageIndex)
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

    @objc func deleteBookmarkFromSidebar() {
        let clickedRow = bookmarksOutlineView.clickedRow
        if clickedRow >= 0, !bookmarksOutlineView.selectedRowIndexes.contains(clickedRow) {
            bookmarksOutlineView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        let selectedOutlines = bookmarksOutlineView.selectedRowIndexes.compactMap {
            bookmarksOutlineView.item(atRow: $0) as? PDFOutline
        }
        let outlines = selectedOutlines.filter { outline in
            var ancestor = outline.parent
            while let current = ancestor {
                if selectedOutlines.contains(where: { $0 === current }) { return false }
                ancestor = current.parent
            }
            return outline.parent != nil
        }
        guard !outlines.isEmpty else {
            beep()
            return
        }
        let alert = NSAlert()
        let descendantCount = outlines.reduce(0) { $0 + bookmarkDescendantCount($1) }
        if outlines.count == 1, let outline = outlines.first {
            let title = displayBookmarkTitle(for: outline)
            alert.messageText = descendantCount > 0 ? "Delete Bookmark Group?" : "Delete Bookmark?"
            alert.informativeText = descendantCount > 0
                ? "“\(title)” contains \(descendantCount) nested bookmark\(descendantCount == 1 ? "" : "s"). The group and its contents will be removed. PDF pages are unaffected."
                : "Remove “\(title)”? The PDF page is unaffected."
        } else {
            alert.messageText = "Delete \(outlines.count) Bookmarks?"
            alert.informativeText = "This also removes \(descendantCount) nested bookmark\(descendantCount == 1 ? "" : "s"). PDF pages are unaffected."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for outline in outlines {
            guard let parent = outline.parent else { continue }
            let index = outline.index
            outline.removeFromParent()
            registerBookmarkPresenceUndo(
                outline: outline,
                parent: parent,
                index: index,
                shouldExist: true,
                actionName: outlines.count == 1 ? "Delete Bookmark" : "Delete Bookmarks"
            )
        }
        bookmarkLabelOverrides.removeAll()
        reloadBookmarks()
        markMarkupChangedAndScheduleAutosave()
    }

    private func bookmarkDescendantCount(_ outline: PDFOutline) -> Int {
        var total = outline.numberOfChildren
        for index in 0..<outline.numberOfChildren {
            if let child = outline.child(at: index) {
                total += bookmarkDescendantCount(child)
            }
        }
        return total
    }

    private func registerBookmarkPresenceUndo(
        outline: PDFOutline,
        parent: PDFOutline,
        index: Int,
        shouldExist: Bool,
        actionName: String
    ) {
        guard let undo = view.window?.undoManager ?? undoManager else { return }
        undo.registerUndo(withTarget: self) { target in
            if shouldExist {
                parent.insertChild(outline, at: min(index, parent.numberOfChildren))
            } else {
                outline.removeFromParent()
            }
            target.bookmarkLabelOverrides.removeAll()
            target.reloadBookmarks()
            target.markMarkupChangedAndScheduleAutosave()
            target.registerBookmarkPresenceUndo(
                outline: outline,
                parent: parent,
                index: index,
                shouldExist: !shouldExist,
                actionName: actionName
            )
        }
        undo.setActionName(actionName)
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
        suppressedEmbeddedPageLabelIndexes.remove(row)
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

    private func configureStatusBar() {
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = panelBackgroundColor.cgColor

        let labels = [statusPageSizeLabel, statusPageLabel, statusZoomLabel]
        labels.forEach {
            $0.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            $0.textColor = .secondaryLabelColor
        }

        for (button, symbol, name, action, identifier) in [
            (navigationBackButton, "arrow.uturn.backward", "Back to previous view (⌥←)", #selector(commandNavigateBack(_:)), "drawbridgeNavigateBack"),
            (navigationForwardButton, "arrow.uturn.forward", "Forward to next view (⌥→)", #selector(commandNavigateForward(_:)), "drawbridgeNavigateForward"),
            (previousPageButton, "arrowtriangle.left.fill", "Previous Page", #selector(commandPreviousPage(_:)), "drawbridgePreviousPage"),
            (nextPageButton, "arrowtriangle.right.fill", "Next Page", #selector(commandNextPage(_:)), "drawbridgeNextPage")
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
            button.imagePosition = .imageOnly; button.bezelStyle = .texturedRounded; button.controlSize = .small
            button.target = self; button.action = action; button.toolTip = name
            button.setAccessibilityLabel(name); button.identifier = NSUserInterfaceItemIdentifier(identifier)
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }
        statusPageLabel.lineBreakMode = .byTruncatingMiddle
        statusPageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        func group(_ title: String, _ buttons: [NSButton]) -> NSStackView {
            let label = NSTextField(labelWithString:title)
            label.font = .systemFont(ofSize:10,weight:.medium); label.textColor = .secondaryLabelColor
            let stack = NSStackView(views:[label] + buttons)
            stack.orientation = .horizontal; stack.spacing = 5; stack.alignment = .centerY
            return stack
        }
        let history = group("History",[navigationBackButton,navigationForwardButton])
        let pages = group("Pages",[previousPageButton,nextPageButton])
        let details = NSStackView(views: [history,pages] + labels)
        details.orientation = .horizontal
        details.spacing = 14
        details.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(details)

        NSLayoutConstraint.activate([
            details.centerXAnchor.constraint(equalTo: statusBar.centerXAnchor),
            details.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            details.leadingAnchor.constraint(greaterThanOrEqualTo: statusBar.leadingAnchor, constant: 10),
            details.trailingAnchor.constraint(lessThanOrEqualTo: statusBar.trailingAnchor, constant: -10)
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
        busySubdetailLabel.maximumNumberOfLines = 3
        busySubdetailLabel.lineBreakMode = .byWordWrapping
        busySubdetailLabel.preferredMaxLayoutWidth = 390

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

    func beginBusyIndicator(_ message: String, detail: String? = nil, lockInteraction: Bool = true) {
        pdfView.rectangleMarkup.cancelGesture()
        if textSearch.isSearching { resetSearchState() }
        busyOperationDepth += 1
        refreshFlattenButtonState()
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
        refreshFlattenButtonState()
        guard busyOperationDepth == 0 else { return }
        view.window?.ignoresMouseEvents = false
        busyInteractionLocked = false
        busyProgressIndicator.stopAnimation(nil)
        busyProgressIndicator.isIndeterminate = true
        busyProgressIndicator.minValue = 0
        busyProgressIndicator.maxValue = 100
        busyProgressIndicator.doubleValue = 0
        busyOverlayView.isHidden = true
        if searchPanel?.isVisible == true { refreshSearchIfNeeded() }
        busyDetailLabel.stringValue = ""
        busySubdetailLabel.stringValue = ""
        setBusyCancelAction(nil)
    }

    private func refreshBusyIndicatorDisplay() {
        busyOverlayView.needsLayout = true
        busyStatusLabel.needsDisplay = true
        busyDetailLabel.needsDisplay = true
        busySubdetailLabel.needsDisplay = true
        busyProgressIndicator.needsDisplay = true
        busyOverlayView.layoutSubtreeIfNeeded()
        view.window?.displayIfNeeded()
        // OCR runs synchronously. Commit label/progress changes before entering
        // Vision, rather than leaving the initial message on screen until it ends.
        CATransaction.flush()
    }

    func updateBusyIndicatorStatus(_ status: String) {
        busyStatusLabel.stringValue = status
        refreshBusyIndicatorDisplay()
    }

    func updateBusyIndicatorDetail(_ detail: String) {
        busyDetailLabel.stringValue = detail
        refreshBusyIndicatorDisplay()
    }

    func updateBusyIndicatorSubdetail(_ detail: String) {
        busySubdetailLabel.stringValue = detail
        refreshBusyIndicatorDisplay()
    }

    func updateBusyIndicatorProgress(current: Int, total: Int) {
        guard total > 0 else { return }
        busyProgressIndicator.isIndeterminate = false
        busyProgressIndicator.minValue = 0
        busyProgressIndicator.maxValue = Double(total)
        busyProgressIndicator.doubleValue = Double(max(0, min(current, total)))
        refreshBusyIndicatorDisplay()
    }

    private func processBusyCancellationEvents() {
        // OCR is synchronous. Let AppKit dispatch Cancel/Escape at page boundaries;
        // merely running the run loop does not drain its queued mouse events.
        guard busyCancelHandler != nil else { return }
        for _ in 0..<16 {
            guard let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) else { break }
            NSApp.sendEvent(event)
        }
    }

    func setBusyCancelAction(_ handler: (() -> Void)?, title: String = "Cancel", enabled: Bool = true) {
        busyCancelHandler = handler
        if let monitor = busyInputMonitor { NSEvent.removeMonitor(monitor); busyInputMonitor = nil }
        view.window?.ignoresMouseEvents = busyInteractionLocked && handler == nil
        if handler != nil && busyInteractionLocked {
            // Keep Cancel clickable without exposing the document or toolbar to
            // edits while OCR/file processing owns the document.
            busyInputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel, .magnify, .rotate, .swipe, .keyDown]) { [weak self] event in
                guard let self, event.window === self.view.window, self.busyInteractionLocked else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.busyCancelHandler?() }
                    return nil
                }
                let point = self.busyCancelButton.convert(event.locationInWindow, from: nil)
                return self.busyCancelButton.bounds.contains(point) ? event : nil
            }
        }
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

        let actions = NSStackView(views: [emptyStateOpenButton, emptyStateRecentButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY

        let stack = NSStackView(views: [emptyStateTitle, actions])
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
        flattenPDFButton.toolTip = "Flatten PDF — make visible markups permanent and save this PDF"
        flattenPDFButton.setAccessibilityLabel("Flatten PDF")
        flattenPDFButton.identifier = NSUserInterfaceItemIdentifier("drawbridgeFlattenPDF")
        reduceFileSizeButton.image = ToolbarIcons.compressionClamp()
        reduceFileSizeButton.imagePosition = .imageOnly
        reduceFileSizeButton.bezelStyle = .texturedRounded
        reduceFileSizeButton.toolTip = "Reduce File Size — lossless compression, preserving image resolution"
        reduceFileSizeButton.setAccessibilityLabel("Reduce File Size")

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

        for (button, symbol, name, action) in [
            (goToSheetButton, "list.bullet.rectangle", "Go to Sheet (⌘L)", #selector(commandGoToSheet(_:))),
            (fitPageButton, "arrow.up.left.and.arrow.down.right", "Fit Entire Page (⌘9)", #selector(commandFitPage(_:)))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
            button.imagePosition = .imageOnly; button.bezelStyle = .texturedRounded
            button.target = self; button.action = action; button.toolTip = name
            button.setAccessibilityLabel(name)
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
            toolbarControlsStack.addArrangedSubview(goToSheetButton)
            toolbarControlsStack.addArrangedSubview(fitPageButton)
        }

        toolbarSearchField.placeholderString = "Search PDF text"
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

        refreshToolbarShortcutTooltips()
        refreshToolbarToolButtons()
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
        let primaryButtonActions: [(ToolMode, String, String)] = [
            (.select, "Select", shortcutDisplayString(for: .selectTool)),
            (.pen, "Pen", "Cmd+1"),
            (.highlighter, "Highlighter", "Cmd+2"),
            (.text, "Text", "Cmd+3"),
            (.note, "Note", "Cmd+4"),
            (.line, "Line", "Cmd+5"),
            (.arrow, "Arrow", "Cmd+6"),
            (.rectangle, "Rectangle", "Cmd+7"),
            (.circle, "Ellipse", "Cmd+8")
        ]
        for (mode, title, shortcut) in primaryButtonActions {
            toolbarToolButtons[mode]?.toolTip = "\(title) (\(shortcut))"
        }

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
        let targetMode = ToolMode.allToolbarModes
            .first(where: { "toolbar.\($0.toolbarIdentifier)" == raw })
        guard let targetMode else { return }
        setTool(targetMode)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.drawbridgePrimaryControls, .drawbridgeMarkupControls, .flexibleSpace, .space]
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outlineView = notification.object as? NSOutlineView,
              outlineView === bookmarksOutlineView else {
            return
        }
        updateBookmarkSelectionPresentation()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let sidebar = sidebarContainerView, !isSidebarCollapsed, sidebar.frame.width > 120 else { return }
        lastSidebarExpandedWidth = min(max(sidebar.frame.width, 220), 280)
        UserDefaults.standard.set(Double(lastSidebarExpandedWidth), forKey: "DrawbridgeSidebarWidth")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.drawbridgePrimaryControls, .flexibleSpace, .drawbridgeMarkupControls, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        if itemIdentifier == .drawbridgeMarkupControls {
            item.label = "Markup"; item.view = rectangleToolbar; return item
        }
        if itemIdentifier == .drawbridgePrimaryControls {
            item.label = "Drawing Set Tools and Navigation"
            item.view = toolbarControlsStack
            return item
        }
        return nil
    }

    @objc private func changeTool() {
        let requestedMode = ToolMode.fromPrimaryToolbarSegment(toolSelector.selectedSegment) ?? .select
        activateTool(requestedMode)
    }

    @objc private func changeTakeoffTool() {
        return
    }

    private func activateTool(_ requestedMode: ToolMode) {
        // Only text selection is supported; stale shortcuts cannot enable editing.
        cancelPendingMarkupInteractions()
        pdfView.rectangleMarkup.escape()
        pdfView.toolMode = .select
        refreshToolSegmentIcons()
        refreshTakeoffSegmentIcons()
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
        // Compatibility entry point: annotation authoring is unavailable.
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
        pdfView.setMarkupDocument(document)
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
        dominantDocumentPageSizeInInches = dominantPageSizeInInches(for: document)
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
        // Compatibility entry point: annotation authoring is unavailable.
    }

    @objc func underlineSelection() {
        // Compatibility entry point: annotation authoring is unavailable.
    }

    @objc func strikethroughSelection() {
        // Compatibility entry point: annotation authoring is unavailable.
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
                showBusyOverlay: pdfView.rectangleMarkup.hasUnsavedChanges
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

    func pasteCopiedMarkupsFromPasteboard() {
        // Compatibility entry point: annotation authoring is unavailable.
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
        contentsSummaryDocument = nil
        cachedContentsSummary = nil
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
        cachedContentsSummary = nil
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
        dominantDocumentPageSizeInInches = dominantPageSizeInInches(for: document)
        pdfView.setMarkupDocument(document)
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
        suppressedEmbeddedPageLabelIndexes.removeAll()
        hasPromptedForInitialMarkupSaveCopy = false
        isPresentingInitialMarkupSaveCopyPrompt = false
        loadSidecarSnapshotIfAvailable(for: url, document: document)
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
                "cached_markups": "\(totalCachedAnnotationCount())"
            ]
        )
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
        pdfView.setMarkupDocument(nil)
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
        suppressedEmbeddedPageLabelIndexes.removeAll()
        openDocumentURL = nil
        dominantDocumentPageSizeInInches = nil
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

    private func clearGroupedPasteDragSelection() {
        groupedPasteDragPageID = nil
        groupedPasteDragAnnotationIDs.removeAll(keepingCapacity: false)
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

    private func refreshFlattenButtonState() {
        refreshRectangleToolbar()
        goToSheetButton.isEnabled = pdfView.document != nil && !isPDFProcessingBusy
        fitPageButton.isEnabled = pdfView.document != nil && !isPDFProcessingBusy
        reduceFileSizeButton.isEnabled = pdfView.document != nil && openDocumentURL != nil && !isPDFProcessingBusy
        let recoverable = pdfView.document.map(PDFAnnotationFlattener.canUnflatten) ?? false
        flattenPDFButton.image = NSImage(systemSymbolName: recoverable ? "square.stack.3d.up" : "square.stack.3d.down.forward", accessibilityDescription: recoverable ? "Unflatten PDF" : "Flatten PDF")
        flattenPDFButton.toolTip = recoverable ? "Unflatten PDF — restore editable annotations and save this PDF" : "Flatten PDF — flatten annotations and save this PDF"
        flattenPDFButton.setAccessibilityLabel(recoverable ? "Unflatten PDF" : "Flatten PDF")
        flattenPDFButton.isEnabled = pdfView.document != nil && openDocumentURL != nil && !isPDFProcessingBusy
    }

    func updateStatusBar() {
        refreshFlattenButtonState()
        navigationBackButton.isEnabled = !isPDFProcessingBusy && pdfView.canNavigateBackInHistory
        navigationForwardButton.isEnabled = !isPDFProcessingBusy && pdfView.canNavigateForwardInHistory
        let pageIndex = pdfView.currentPage.flatMap { page in pdfView.document.map { $0.index(for:page) } }
        previousPageButton.isEnabled = !isPDFProcessingBusy && (pageIndex ?? 0) > 0
        nextPageButton.isEnabled = !isPDFProcessingBusy && pageIndex != nil && pageIndex! < (pdfView.document?.pageCount ?? 0)-1
        statusToolLabel.stringValue = "Tool: \(pdfView.rectangleMarkup.tool)"
        applyScaleLockForCurrentPageIfNeeded()

        if let document = pdfView.document,
           let page = pdfView.currentPage {
            let index = document.index(for: page)
            let label = displayPageLabel(forPageIndex: index)
            statusPageSizeLabel.stringValue = "Size: \(formattedPageSize(for: page))"
            statusPageLabel.stringValue = "Page \(index + 1) of \(document.pageCount): \(label)"
            statusPageLabel.toolTip = label
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
            autoNameSheetsButton.isEnabled = !isPDFProcessingBusy
            batchLinkSheetsButton.isEnabled = !isPDFProcessingBusy
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

    func displayPageLabel(forPageIndex pageIndex: Int) -> String {
        if let override = pageLabelOverrides[pageIndex],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override
        }
        if suppressedEmbeddedPageLabelIndexes.contains(pageIndex) {
            return "\(pageIndex + 1)"
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
        if let dominant = dominantDocumentPageSizeInInches {
            return "\(formatInches(dominant.height)) H x \(formatInches(dominant.width)) W"
        }
        let bounds = page.bounds(for: .mediaBox)
        let rawWidthInches = max(0, bounds.width) / 72.0
        let rawHeightInches = max(0, bounds.height) / 72.0
        let widthInches = max(rawWidthInches, rawHeightInches)
        let heightInches = min(rawWidthInches, rawHeightInches)
        return "\(formatInches(heightInches)) H x \(formatInches(widthInches)) W"
    }

    private func dominantPageSizeInInches(for document: PDFDocument) -> (height: CGFloat, width: CGFloat)? {
        var counts: [String: (count: Int, height: CGFloat, width: CGFloat)] = [:]
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let bounds = page.bounds(for: .mediaBox).standardized
            let rawWidth = max(0, bounds.width) / 72.0
            let rawHeight = max(0, bounds.height) / 72.0
            guard rawWidth > 0, rawHeight > 0 else { continue }
            let height = min(rawWidth, rawHeight)
            let width = max(rawWidth, rawHeight)
            let roundedHeight = (height * 10).rounded() / 10
            let roundedWidth = (width * 10).rounded() / 10
            let key = "\(roundedHeight)x\(roundedWidth)"
            let existing = counts[key]
            counts[key] = (
                count: (existing?.count ?? 0) + 1,
                height: roundedHeight,
                width: roundedWidth
            )
        }
        guard let dominant = counts.values.max(by: { $0.count < $1.count }),
              dominant.count > document.pageCount / 2 else {
            return nil
        }
        return (dominant.height, dominant.width)
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

    func startAutoGenerateSheetNamesFlow() {
        guard let document = pdfView.document,
              let currentPage = pdfView.currentPage else {
            beep()
            return
        }
        autoNameIgnoresExistingPageLabels = true
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
        autoNameIgnoresExistingPageLabels = false
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
        beginBusyIndicator("Generating Bookmarks…", detail: "Preparing to read \(document.pageCount) pages")
        let cancellation = PDFProcessingCancellation()
        setBusyCancelAction({ [weak self] in
            cancellation.cancel()
            self?.updateBusyIndicatorDetail("Stopping after the current page…")
        })
        let readingStartedAt = Date()
        var identifiedNumbers = 0
        var completedPages = 0
        var lastIdentifiedSheet = ""
        func showReadingProgress(pageIndex: Int, activity: String) {
            updateBusyIndicatorDetail("Page \(pageIndex + 1) of \(document.pageCount) • \(activity)")
            let elapsed = shortDuration(Date().timeIntervalSince(readingStartedAt))
            let latest = lastIdentifiedSheet.isEmpty ? "" : "\nLatest sheet: \(lastIdentifiedSheet)"
            updateBusyIndicatorSubdetail("\(completedPages) pages read • \(identifiedNumbers) sheet numbers found • \(elapsed) elapsed" + latest)
        }
        updateBusyIndicatorProgress(current: 0, total: document.pageCount)
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
            autoNameIgnoresExistingPageLabels = false
        }

        guard let referenceIndex = autoNameReferencePageIndex,
              let referencePage = document.page(at: referenceIndex) else { return }
        let box = pdfView.displayBox
        let geometry = PDFBookmarkExtractor.Geometry(page: referencePage, box: box)
        let numberRegion = geometry.normalized(denormalize(rect: numberZone, for: referencePage))
        let titleRegion = geometry.normalized(denormalize(rect: titleZone, for: referencePage))
        var numbers: [PDFBookmarkExtractor.Result] = []
        var titles: [PDFBookmarkExtractor.Result] = []
        var labelHints: [String?] = []
        var titleLabelHints: [String?] = []
        for pageIndex in 0..<document.pageCount {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
            processBusyCancellationEvents()
            if cancellation.cancelled { return }
            autoreleasepool {
                guard let page = document.page(at: pageIndex) else {
                    numbers.append(.init(text: "", source: "missing page"))
                    titles.append(.init(text: "", source: "missing page"))
                    labelHints.append(nil)
                    titleLabelHints.append(nil)
                    return
                }
                showReadingProgress(pageIndex: pageIndex, activity: "Reading sheet number")
                let target = PDFBookmarkExtractor.Geometry(page: page, box: box)
                let locatedNumber = PDFBookmarkExtractor.extractAdaptiveNumber(
                    page: page, normalizedRect: numberRegion, box: box, preferOCR: true,
                    progress: { showReadingProgress(pageIndex: pageIndex, activity: $0) })
                numbers.append(locatedNumber.result)
                if !locatedNumber.result.text.isEmpty {
                    identifiedNumbers += 1
                    lastIdentifiedSheet = locatedNumber.result.text
                }
                let adjustedTitleRegion = titleRegion.offsetBy(
                    dx: locatedNumber.normalizedXOffset, dy: locatedNumber.normalizedYOffset)
                titles.append(PDFBookmarkExtractor.extract(
                    page: page, rect: target.pageRect(adjustedTitleRegion), box: box, field: .title, preferOCR: true,
                    progress: { showReadingProgress(pageIndex: pageIndex, activity: $0) }))
                let labelInfo = autoNameIgnoresExistingPageLabels ? (number: nil as String?, title: nil as String?) : sheetInfoFromPageLabel(page.label ?? "")
                labelHints.append(labelInfo.number)
                titleLabelHints.append(labelInfo.title)
            }
            completedPages = pageIndex + 1
            showReadingProgress(pageIndex: pageIndex, activity: "Page read")
            updateBusyIndicatorProgress(current: completedPages, total: document.pageCount)
        }
        processBusyCancellationEvents()
        if cancellation.cancelled { return }
        setBusyCancelAction(nil)
        updateBusyIndicatorDetail("Checking the detected sheet numbers and titles…")
        let reconciledNumbers = SheetReferencePolicy.reconcileOCRNumbers(numbers.map(\.text))
        numbers = numbers.enumerated().map { index, result in
            guard reconciledNumbers[index] != result.text else { return result }
            return PDFBookmarkExtractor.Result(text: reconciledNumbers[index], source: "OCR (numeric format verified)",
                                               alternatives: [result.text] + result.alternatives)
        }
        numbers = PDFBookmarkExtractor.resolveNumbers(numbers, labelHints: labelHints)
        titles = PDFBookmarkExtractor.resolveTitles(titles, labelHints: titleLabelHints)
        var generated: [AutoNamedSheet] = []
        var reviewPages: [Int] = []
        var extractionNotes: [String] = []
        var detectedSheetNumberCount = 0
        for pageIndex in 0..<document.pageCount {
            let number = numbers[pageIndex], title = titles[pageIndex]
            if !number.text.isEmpty { detectedSheetNumberCount += 1 }
            let labelNumber = autoNameIgnoresExistingPageLabels ? nil : sheetInfoFromPageLabel(document.page(at: pageIndex)?.label ?? "").number
            let labelConflict = labelNumber != nil && labelNumber != number.text
            let needsReview = number.text.isEmpty || title.text.isEmpty || !number.alternatives.isEmpty || !title.alternatives.isEmpty || labelConflict
            if needsReview { reviewPages.append(pageIndex + 1) }
            let alternatives = (number.alternatives.isEmpty ? "" : "; other number reading: " + number.alternatives.joined(separator: ", "))
                + (title.alternatives.isEmpty ? "" : "; other title reading: " + title.alternatives.joined(separator: " / "))
            extractionNotes.append("\(number.source); \(title.source)" + alternatives + (labelConflict ? "; differs from page label" : ""))
            generated.append(AutoNamedSheet(pageIndex: pageIndex,
                sheetNumber: number.text.isEmpty ? "Page \(pageIndex + 1)" : number.text,
                sheetTitle: title.text))
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

        updateBusyIndicatorStatus("Bookmarks Ready for Review")
        updateBusyIndicatorDetail("Read \(document.pageCount) pages • \(detectedSheetNumberCount) sheet numbers found")
        updateBusyIndicatorSubdetail("Review the detected names before applying them.")
        let confirmation = NSAlert()
        confirmation.messageText = "Apply Auto-Generated Sheet Names?"
        let duplicates = Dictionary(grouping: generated, by: \.sheetNumber)
            .filter { $0.value.count > 1 }.keys.sorted()
        let reviewNote = reviewPages.isEmpty ? "" : "\nReview missing fields, alternative readings, or label conflicts on pages: " + reviewPages.map(String.init).joined(separator: ", ")
        let duplicateNote = duplicates.isEmpty ? "" : "\nRepeated sheet numbers (all pages retained): " + duplicates.joined(separator: ", ")
        confirmation.informativeText = "Double-click a sheet number or title to correct it. Applying replaces the existing bookmark tree in document page order."
            + reviewNote + duplicateNote
        let preview = BookmarkReviewView(rows: generated.enumerated().map { index, sheet in
            .init(number: sheet.sheetNumber, title: sheet.sheetTitle, note: extractionNotes[index])
        })
        confirmation.accessoryView = preview
        confirmation.alertStyle = .informational
        confirmation.addButton(withTitle: "Continue")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        preview.finishEditing()
        generated = generated.enumerated().map { index, sheet in
            let row = preview.rows[index]
            return AutoNamedSheet(pageIndex: sheet.pageIndex,
                sheetNumber: row.number.isEmpty ? "Page \(sheet.pageIndex + 1)" : row.number,
                sheetTitle: row.title)
        }

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
        updateBusyIndicatorStatus("Applying Bookmarks…")
        updateBusyIndicatorDetail("Creating bookmarks for \(generated.count) pages")
        updateBusyIndicatorSubdetail(applyPageLabels ? "Updating bookmarks and page labels, then saving your PDF." : "Updating bookmarks, then saving your PDF.")
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
        let cancellation = PDFProcessingCancellation()
        let originalAnnotations = (0..<document.pageCount).map { document.page(at: $0)?.annotations ?? [] }
        guard let referenceIndex = autoLinkCaptureReferencePageIndex,
              referenceIndex >= 0,
              referenceIndex < document.pageCount else {
            cancelAutoLinkCapture()
            return
        }

        beginBusyIndicator("Batch Linking Sheet Numbers…", detail: "Reading sheet numbers…")
        setBusyCancelAction({ [weak self] in
            cancellation.cancel()
            self?.updateBusyIndicatorDetail("Stopping after the current page and restoring existing links…")
        })
        defer {
            if cancellation.cancelled {
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index) else { continue }
                    for annotation in page.annotations { page.removeAnnotation(annotation) }
                    for annotation in originalAnnotations[index] { page.addAnnotation(annotation) }
                    markPageMarkupCacheDirty(page)
                }
                refreshMarkups()
                pdfView.refreshHyperlinkHighlights()
            }
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

        var ocrTargets = OCRSheetTargetIndex()
        var zonePageDiagnostics: [BatchLinkZonePageDiagnostic] = []
        let batchStartedAt = Date()
        var stageStartedAt = Date()

        func contextualSubdetail(prefix: String, current: Int, total: Int) -> String {
            let safeTotal = max(1, total)
            let done = max(0, min(current, safeTotal))
            let percent = Int((Double(done) / Double(safeTotal) * 100).rounded())
            let elapsed = shortDuration(Date().timeIntervalSince(batchStartedAt))
            guard done > 0 else {
                return "\(prefix)\n\(done)/\(safeTotal) completed • \(percent)% • \(elapsed) elapsed"
            }
            let stageElapsed = Date().timeIntervalSince(stageStartedAt)
            let remaining = stageElapsed * Double(safeTotal - done) / Double(done)
            return "\(prefix)\n\(done)/\(safeTotal) completed • \(percent)% • \(elapsed) elapsed\nAbout \(shortDuration(remaining)) left in this stage"
        }

        updateBusyIndicatorStatus("Batch Linking Sheet Numbers…")
        updateBusyIndicatorDetail("Step 1/3: Reading sheet numbers…")
        updateBusyIndicatorSubdetail(contextualSubdetail(prefix: "0 found", current: 0, total: document.pageCount))
        updateBusyIndicatorProgress(current: 0, total: document.pageCount)
        for pageIndex in 0..<document.pageCount {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
            processBusyCancellationEvents()
            if cancellation.cancelled { return }
            guard let page = document.page(at: pageIndex) else { continue }
            updateBusyIndicatorProgress(current: pageIndex, total: document.pageCount)
            updateBusyIndicatorDetail("Stage 1 of 3 • Reading page \(pageIndex + 1) of \(document.pageCount)")
            let detected = detectSheetTokenForBatchLink(on: page, normalizedZone: normalizedZone)
            updateBusyIndicatorProgress(current: pageIndex + 1, total: document.pageCount)
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
                        prefix: "\(ocrTargets.targets.count) sheet numbers found • \(zonePageDiagnostics.filter { $0.detectedToken == nil }.count) missed",
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

            ocrTargets.record(token, pageIndex: pageIndex)
            updateBusyIndicatorSubdetail(
                contextualSubdetail(
                    prefix: "\(ocrTargets.targets.count) sheet numbers found • \(zonePageDiagnostics.filter { $0.detectedToken == nil }.count) missed",
                    current: pageIndex + 1,
                    total: document.pageCount
                )
            )
        }

        let reconciledTokens = SheetReferencePolicy.reconcileOCRNumbers(zonePageDiagnostics.map { $0.detectedToken ?? "" })
        ocrTargets = OCRSheetTargetIndex()
        for (index, diagnostic) in zonePageDiagnostics.enumerated() {
            let token = reconciledTokens[index]
            guard !token.isEmpty else { continue }
            if token != diagnostic.detectedToken {
                zonePageDiagnostics[index] = BatchLinkZonePageDiagnostic(
                    pageIndex: diagnostic.pageIndex, pageLabel: diagnostic.pageLabel,
                    detectedToken: token, strategy: "OCR numeric format verified",
                    rawTextPreview: diagnostic.rawTextPreview, failureReason: nil, usedFallback: true)
            }
            ocrTargets.record(token, pageIndex: diagnostic.pageIndex)
        }
        processBusyCancellationEvents()
        if cancellation.cancelled { return }
        let ambiguousNumbers = ocrTargets.ambiguous.sorted()
        let ambiguousSummary = ambiguousNumbers.isEmpty ? "" : "\nDuplicate sheet numbers were left unlinked: " + ambiguousNumbers.joined(separator: ", ") + "."
        let sheetTokenToPageIndex = ocrTargets.targets

        let zoneDetectedCount = zonePageDiagnostics.reduce(0) { partial, diagnostic in
            partial + (diagnostic.detectedToken == nil ? 0 : 1)
        }
        let zoneFallbackRecoveredCount = zonePageDiagnostics.reduce(0) { partial, diagnostic in
            partial + ((diagnostic.detectedToken != nil && diagnostic.usedFallback) ? 1 : 0)
        }
        let missedZonePages = zonePageDiagnostics.filter { $0.detectedToken == nil }
            .map { String($0.pageIndex + 1) }
        let missedZoneSummary = missedZonePages.isEmpty ? "" : "\nSheet number not detected on page(s): \(missedZonePages.joined(separator: ", "))."

        guard !sheetTokenToPageIndex.isEmpty else {
            let response = runAlert(
                title: "No Sheet Numbers Detected",
                informativeText: "Could not detect sheet numbers from the captured zone.\n\nZone read: \(zoneDetectedCount)/\(document.pageCount) pages (\(zoneFallbackRecoveredCount) recovered by fallback probes).\(missedZoneSummary)\(ambiguousSummary)",
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

        var removedLinks = 0
        if shouldClearExisting {
            stageStartedAt = Date()
            updateBusyIndicatorStatus("Batch Linking Sheet Numbers…")
            updateBusyIndicatorDetail("Step 0/3: Removing existing batch links…")
            updateBusyIndicatorSubdetail(contextualSubdetail(prefix: "0 links removed", current: 0, total: document.pageCount))
            updateBusyIndicatorProgress(current: 0, total: max(1, document.pageCount))
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
        for (sheetToken, targetPageIndex) in sheetTokenToPageIndex.sorted(by: { $0.key < $1.key }) {
            guard let targetPage = document.page(at: targetPageIndex) else { continue }
            linkTargetsByToken[sheetToken] = (bookmarkStyleDestination(for: targetPage), targetPageIndex)
        }

        updateBusyIndicatorDetail("Preparing sheet reference text…")
        let recoveredTextDocument: PDFDocument? = {
            guard document.page(at: referenceIndex)?.string?.isEmpty != false,
                  let sourceURL = openDocumentURL ?? document.documentURL,
                  let recovered = PDFSelectableTextRecovery.document(for: sourceURL),
                  recovered.pageCount == document.pageCount else { return nil }
            for index in 0..<document.pageCount {
                guard let original = document.page(at: index), let copy = recovered.page(at: index),
                      original.bounds(for: .mediaBox) == copy.bounds(for: .mediaBox),
                      original.bounds(for: .cropBox) == copy.bounds(for: .cropBox),
                      original.rotation == copy.rotation else { return nil }
            }
            return recovered
        }()

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
                    guard selection.numberOfTextRanges(on: page) == 1,
                          let pageText = page.string,
                          SheetReferencePolicy.isWholeToken(selection.range(at: 0, on: page), in: pageText as NSString) else { continue }
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
        var scannedPageIndexes = Set<Int>()
        scannedPageIndexes.reserveCapacity(document.pageCount)
        for sourcePageIndex in 0..<document.pageCount {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
            processBusyCancellationEvents()
            if cancellation.cancelled { return }
            guard let page = document.page(at: sourcePageIndex) else { continue }
            updateBusyIndicatorProgress(current: sourcePageIndex + 1, total: document.pageCount)
            updateBusyIndicatorDetail("Step 2/3: Scanning selectable text… \(sourcePageIndex + 1)/\(document.pageCount)")
            let textPage = recoveredTextDocument?.page(at: sourcePageIndex) ?? page
            if textPage.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                scannedPageIndexes.insert(sourcePageIndex)
            }
            let textHits = selectableSheetTokenHits(on: textPage, knownExactTokens: Set(linkTargetsByToken.keys))
            let hits = recoveredTextDocument != nil
                ? VisualSheetReferenceLocator.locate(on: page, hints: textHits)
                : textHits
            for hit in hits {
                let target = linkTargetsByToken[hit.token.uppercased()]
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

        // OCR is expensive. It is a fallback for scanned pages that have no
        // selectable text, so avoid rasterizing every vector drawing sheet.
        stageStartedAt = Date()
        updateBusyIndicatorDetail("Step 3/3: OCR fallback + linking…")
        updateBusyIndicatorProgress(current: 0, total: document.pageCount)
        updateBusyIndicatorSubdetail(contextualSubdetail(prefix: "\(addedLinks) links created", current: 0, total: document.pageCount))
        let ocrCustomWords = Array(linkTargetsByToken.keys)
        for sourcePageIndex in 0..<document.pageCount {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
            processBusyCancellationEvents()
            if cancellation.cancelled { return }
            guard let page = document.page(at: sourcePageIndex) else { continue }
            updateBusyIndicatorProgress(current: sourcePageIndex + 1, total: document.pageCount)
            updateBusyIndicatorDetail("Step 3/3: OCR fallback + linking… \(sourcePageIndex + 1)/\(document.pageCount)")
            guard scannedPageIndexes.contains(sourcePageIndex) else {
                continue
            }
            let ocrHits = recognizeTextLines(in: page, customWords: ocrCustomWords)
            for hit in ocrHits {
                let tokens = SheetReferencePolicy.exactReferences(in: hit.text, knownTokens: Set(linkTargetsByToken.keys))
                guard !tokens.isEmpty else { continue }
                for token in tokens {
                    let target = linkTargetsByToken[token.uppercased()]
                    guard let target else { continue }
                    if target.targetPageIndex == sourcePageIndex {
                        continue
                    }
                    guard SheetReferencePolicy.isSheetIdentifier(token) else { continue }
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
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
            processBusyCancellationEvents()
            if cancellation.cancelled { return }
            guard let page = document.page(at: pageIndex),
                  touchedPageIDs.contains(ObjectIdentifier(page)) else { continue }
            markPageMarkupCacheDirty(page)
        }

        processBusyCancellationEvents()
        if cancellation.cancelled { return }
        setBusyCancelAction(nil)
        if addedLinks > 0 || removedLinks > 0 {
            markMarkupChanged()
            refreshMarkups()
            pdfView.refreshHyperlinkHighlights()
        }
        reloadBookmarks()
        updateStatusBar()
        let presentCompletion = { [weak self] in
            guard let self else { return }
            let completionResponse = self.runAlert(
                title: "Batch Link Complete",
                informativeText: "Detected \(sheetTokenToPageIndex.count) sheet numbers and created \(addedLinks) hyperlink(s) across \(document.pageCount) page(s).\n\nZone read: \(zoneDetectedCount)/\(document.pageCount) pages (\(zoneFallbackRecoveredCount) recovered by fallback probes).\(missedZoneSummary)\(ambiguousSummary)",
                buttons: ["OK", "Show Diagnostics"]
            )
            if completionResponse == .alertSecondButtonReturn {
                self.showBatchLinkZoneDiagnostics(document: document, diagnostics: zonePageDiagnostics)
            }
        }
        if addedLinks > 0 || removedLinks > 0 {
            DispatchQueue.main.async { [weak self] in
                self?.saveNavigationCommandChanges(in: document) { success in
                    guard success else { return }
                    presentCompletion()
                }
            }
        } else {
            presentCompletion()
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

        if !detected.isEmpty {
            lines.append("")
            lines.append("Detected Page Details:")
            for item in detected {
                lines.append("\(pageDescriptor(pageIndex: item.pageIndex, pageLabel: item.pageLabel)): \(item.detectedToken ?? "?")")
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
        let type = (annotation.type ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard type == "link" else { return false }
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

    func sheetInfoFromPageLabel(_ label: String) -> (number: String?, title: String?) {
        let cleaned = cleanDetectedSheetText(label)
        guard !cleaned.isEmpty else { return (nil, nil) }
        let tokens = extractSheetTokens(from: cleaned)
        guard let number = preferredSheetToken(from: tokens.filter(SheetReferencePolicy.isSheetIdentifier)) else { return (nil, nil) }

        var title = cleaned
        let escapedNumber = NSRegularExpression.escapedPattern(for: number)
        if let regex = try? NSRegularExpression(pattern: #"(?i)(^|\b)"# + escapedNumber + #"(\b|$)"#) {
            title = regex.stringByReplacingMatches(
                in: title,
                range: NSRange(title.startIndex..., in: title),
                withTemplate: " "
            )
        }
        title = PDFBookmarkExtractor.removingPageLabelOrdinalPrefix(title)
        title = title
            .replacingOccurrences(of: #"^[\s\-–—_:|/\\.]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s\-–—_:|/\\.]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (number, isUsableSheetTitle(title) ? title : nil)
    }

    private func detectSheetTokenForBatchLink(
        on page: PDFPage,
        normalizedZone: NormalizedPageRect
    ) -> (token: String?, strategy: String, rawTextPreview: String, failureReason: String?, usedFallback: Bool) {
        // Read only rendered pixels in the user-selected sheet-number region.
        // Never fall back to PDF text, page ordinals, labels, or bookmark titles.
        let rect = denormalize(rect: normalizedZone, for: page)
        guard let image = renderCroppedImage(from: page, rectInPage: rect) else {
            return (nil, "captured zone OCR", "", "Could not render the captured region.", false)
        }
        let raw = recognizeText(in: image)
        if let token = SheetReferencePolicy.uniqueOCRSheetIdentifier(in: raw) {
            return (token, "captured zone OCR", truncatedZoneDiagnosticText(raw), nil, false)
        }
        // The generic reader ranks orientations by prose confidence/length.
        // A high-scoring upside-down reading can hide a valid sheet number.
        // Retry the same captured pixels; no labels, bookmarks or substitutions.
        let readings = [CGImagePropertyOrientation.up, .right, .left, .down].compactMap {
            recognizeText(in: image, orientation: $0, usesLanguageCorrection: false)?.text
        }
        let token = SheetReferencePolicy.uniqueOCRSheetIdentifier(inOrientationReadings: readings)
        return (token, "captured zone OCR orientation recovery", truncatedZoneDiagnosticText(readings.joined(separator: " | ")),
                token == nil ? "OCR did not read one unambiguous full sheet number in the captured region." : nil, token != nil)
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

    func canonicalizeSheetToken(_ token: String) -> String {
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

    func selectableSheetTokenHits(on page: PDFPage, knownCanonicalTokens: Set<String>? = nil, knownExactTokens: Set<String>? = nil) -> [(token: String, bounds: NSRect)] {
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
            // Avoid cleaning and selecting every word in large note/specification sheets.
            guard rawCandidate.rangeOfCharacter(from: .decimalDigits) != nil,
                  rawCandidate.rangeOfCharacter(from: .letters) != nil else { continue }
            let literal = rawCandidate.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let candidates = knownExactTokens != nil
                ? (SheetReferencePolicy.isSheetIdentifier(literal) ? [literal] : [])
                : (SheetReferencePolicy.isSheetIdentifier(rawCandidate) ? [rawCandidate.uppercased()] : extractSheetTokens(from: rawCandidate))
            let tokens = candidates.filter {
                SheetReferencePolicy.isSheetIdentifier($0)
                    && (knownCanonicalTokens?.contains(canonicalizeSheetToken($0)) ?? true)
                    && (knownExactTokens?.contains($0.uppercased()) ?? true)
            }
            guard !tokens.isEmpty,
                  let selection = page.selection(for: match.range) else { continue }
            let bounds = selection.bounds(for: page)
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
        let detailed = recognizeTextLines(
            in: page,
            scale: 4.0,
            minimumTextHeight: 0.003,
            recognitionLevel: .accurate,
            customWords: words
        )
        let tiled = recognizeTextLinesInTiles(
            in: page,
            scale: 5.0,
            columns: 4,
            rows: 4,
            overlap: 48,
            customWords: words
        )
        return mergedOCRLineHits(primary + detailed + tiled)
    }

    private func mergedOCRLineHits(_ hits: [OCRLineHit]) -> [OCRLineHit] {
        var merged: [OCRLineHit] = []
        merged.reserveCapacity(hits.count)
        var seen = Set<String>()
        for hit in hits {
            let rect = hit.rectInPage.standardized
            let key = "\(hit.text.uppercased()):\(Int((rect.minX * 2).rounded())):\(Int((rect.minY * 2).rounded())):\(Int((rect.width * 2).rounded())):\(Int((rect.height * 2).rounded()))"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(hit)
        }
        return merged
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
            var seenCandidates = Set<String>()
            for candidate in observation.topCandidates(3) {
                let text = cleanDetectedSheetText(candidate.string)
                guard !text.isEmpty, !seenCandidates.contains(text) else { continue }
                seenCandidates.insert(text)
                hits.append(OCRLineHit(text: text, rectInPage: rectInPage))
            }
        }
        return hits
    }

    private func recognizeTextLinesInTiles(
        in page: PDFPage,
        scale: CGFloat,
        columns: Int,
        rows: Int,
        overlap: CGFloat,
        customWords: [String]
    ) -> [OCRLineHit] {
        guard columns > 0, rows > 0 else { return [] }
        let displayBox: PDFDisplayBox = .mediaBox
        let pageBounds = page.bounds(for: displayBox)
        guard pageBounds.width > 1, pageBounds.height > 1 else { return [] }
        let pageTransform = page.transform(for: displayBox)
        let orientedFullBox = pageBounds.applying(pageTransform).standardized
        guard orientedFullBox.width > 1, orientedFullBox.height > 1 else { return [] }

        let tileWidth = orientedFullBox.width / CGFloat(columns)
        let tileHeight = orientedFullBox.height / CGFloat(rows)
        var hits: [OCRLineHit] = []
        for row in 0..<rows {
            autoreleasepool {
                for column in 0..<columns {
                    let tile = NSRect(
                        x: orientedFullBox.minX + CGFloat(column) * tileWidth - overlap,
                        y: orientedFullBox.minY + CGFloat(row) * tileHeight - overlap,
                        width: tileWidth + overlap * 2,
                        height: tileHeight + overlap * 2
                    ).intersection(orientedFullBox).standardized
                    guard !tile.isEmpty, tile.width > 1, tile.height > 1 else { continue }
                    hits.append(contentsOf: recognizeTextLines(
                        in: page,
                        orientedTile: tile,
                        orientedFullBox: orientedFullBox,
                        pageTransform: pageTransform,
                        scale: scale,
                        customWords: customWords
                    ))
                }
            }
        }
        return hits
    }

    private func recognizeTextLines(
        in page: PDFPage,
        orientedTile: NSRect,
        orientedFullBox: NSRect,
        pageTransform: CGAffineTransform,
        scale: CGFloat,
        customWords: [String]
    ) -> [OCRLineHit] {
        let width = Int((orientedTile.width * scale).rounded(.up))
        let height = Int((orientedTile.height * scale).rounded(.up))
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
        context.translateBy(x: -orientedTile.minX, y: -orientedTile.minY)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0
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
                x: orientedTile.minX + rectPx.minX / scale,
                y: orientedTile.minY + rectPx.minY / scale,
                width: rectPx.width / scale,
                height: rectPx.height / scale
            ).intersection(orientedFullBox)
            let rectInPage = rectInOrientedPage.applying(inversePageTransform).standardized
            guard rectInPage.width > 1, rectInPage.height > 1 else { continue }
            var seenCandidates = Set<String>()
            for candidate in observation.topCandidates(5) {
                let text = cleanDetectedSheetText(candidate.string)
                guard !text.isEmpty, !seenCandidates.contains(text) else { continue }
                seenCandidates.insert(text)
                hits.append(OCRLineHit(text: text, rectInPage: rectInPage))
            }
        }
        return hits
    }

    private func applyAutoNamedSheets(_ sheets: [AutoNamedSheet], to document: PDFDocument, applyPageLabels: Bool) {
        if applyPageLabels {
            pageLabelOverrides.removeAll()
            for sheet in sheets {
                let cleanedTitle = sheet.sheetTitle.isEmpty ? "Untitled" : sheet.sheetTitle
                pageLabelOverrides[sheet.pageIndex] = "\(sheet.sheetNumber) - \(cleanedTitle)"
                suppressedEmbeddedPageLabelIndexes.remove(sheet.pageIndex)
            }
            applyPageLabelOverridesToDocumentIfNeeded(document)
        }

        let root = PDFBookmarkExtractor.outline(document: document,
            sheets: sheets.map { (pageIndex: $0.pageIndex, number: $0.sheetNumber, title: $0.sheetTitle) },
            destination: { bookmarkStyleDestination(for: $0) })
        bookmarkLabelOverrides.removeAll()
        document.outlineRoot = root

        markMarkupChanged()
        reloadBookmarks()
        updateStatusBar()

        let informativeText: String
        if applyPageLabels {
            informativeText = "Applied bookmarks and page labels for \(sheets.count) pages."
        } else {
            informativeText = "Applied bookmarks for \(sheets.count) pages."
        }
        saveNavigationCommandChanges(in: document) { [weak self] success in
            guard success else { return }
            self?.runAlert(title: "Sheet Names Updated", informativeText: informativeText)
        }

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

    func normalize(rectInPage: NSRect, for page: PDFPage) -> NormalizedPageRect {
        // Share captured regions in displayed coordinates, not raw PDF coordinates.
        // Identical landscape sheets may be stored as portrait pages with /Rotate.
        let geometry = PDFBookmarkExtractor.Geometry(page: page, box: pdfView.displayBox)
        let visible = geometry.normalized(rectInPage.standardized)
        guard !visible.isEmpty else {
            return NormalizedPageRect(x: 0, y: 0, width: 0, height: 0)
        }
        return NormalizedPageRect(x: 1 - visible.maxX, y: visible.minY,
                                  width: visible.width, height: visible.height)
    }

    func denormalize(rect: NormalizedPageRect, for page: PDFPage) -> NSRect {
        let geometry = PDFBookmarkExtractor.Geometry(page: page, box: pdfView.displayBox)
        let visible = CGRect(x: 1 - rect.x - rect.width, y: rect.y,
                             width: rect.width, height: rect.height)
        return geometry.pageRect(visible).standardized
    }

    private func truncatedZoneDiagnosticText(_ raw: String, limit: Int = 64) -> String {
        let cleaned = cleanDetectedSheetText(raw)
        guard cleaned.count > limit else { return cleaned }
        let endIndex = cleaned.index(cleaned.startIndex, offsetBy: limit)
        return "\(cleaned[..<endIndex])..."
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
            pdfView.setMarkupDocument(nil)
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
        guard !isPDFFileProcessingOperation else { return false }
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
