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
    private let snapshotLayerOptions = [
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
    private let horizontalRuler = PDFRulerView(orientation: .horizontal)
    private let verticalRuler = PDFRulerView(orientation: .vertical)
    private let rulerCornerView = NSView(frame: .zero)
    private let splitView = NSSplitView(frame: .zero)
    private let emptyStateView = StartupDropView(frame: .zero)
    private let emptyStateTitle = NSTextField(labelWithString: "Open or create a PDF to start marking up")
    private let emptyStateOpenButton = NSButton(title: "Open PDF", target: nil, action: nil)
    private let emptyStateRecentButton = NSButton(title: "Open Recent", target: nil, action: nil)
    private let emptyStateSampleButton = NSButton(title: "Create New", target: nil, action: nil)
    let markupsTable = NSTableView(frame: .zero)
    private let markupsCountLabel = NSTextField(labelWithString: "0 items")
    private let markupFilterField = NSSearchField(frame: .zero)
    let measurementScaleField = NSTextField(frame: .zero)
    let measurementUnitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let applyScaleButton = NSButton(title: "Apply Scale", target: nil, action: nil)
    private let actionsPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let autoNameSheetsButton = NSButton(title: "", target: nil, action: nil)
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
    let toolbarSearchField = NSSearchField(frame: .zero)
    let toolbarSearchPrevButton = NSButton(title: "", target: nil, action: nil)
    let toolbarSearchNextButton = NSButton(title: "", target: nil, action: nil)
    let toolbarSearchCountLabel = NSTextField(labelWithString: "")
    var searchPanel: NSPanel?
    private let documentTabsBar = NSView(frame: .zero)
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
    private let busyProgressIndicator = NSProgressIndicator(frame: .zero)
    private let statusToolLabel = NSTextField(labelWithString: "Tool: Pen")
    private let statusToolsHintLabel = NSTextField(labelWithString: "Tools: V D A L P H C R T Q M K | Shift+A Area | Esc Esc: Select")
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
    private let layersSectionButton = NSButton(title: "", target: nil, action: nil)
    private let layersSectionContent = NSStackView(frame: .zero)
    private let layersRowsStack = NSStackView(frame: .zero)
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
    let toolSettingsLineWidthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let toolSettingsOpacitySlider = NSSlider(value: 0.8, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    let toolSettingsOpacityValueLabel = NSTextField(labelWithString: "80%")
    let snapshotColorizeButton = NSButton(title: "Colorize Black -> Red", target: nil, action: nil)
    let toolSettingsFillRow = NSStackView(frame: .zero)
    let toolSettingsOutlineRow = NSStackView(frame: .zero)
    let toolSettingsFontRow = NSStackView(frame: .zero)
    let toolSettingsArrowRow = NSStackView(frame: .zero)
    let toolSettingsArrowSizeRow = NSStackView(frame: .zero)
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
    var markupItems: [MarkupItem] = []
    private var markupsTimer: Timer?
    var scrollEventMonitor: Any?
    var keyEventMonitor: Any?
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
    private var busyInteractionLocked = false
    private var captureToastHideWorkItem: DispatchWorkItem?
    private var grabClipboardPDFData: Data?
    private var grabClipboardPageRect: NSRect?
    private var grabClipboardTintBlendStyle: PDFSnapshotAnnotation.TintBlendStyle = .screen
    weak var lastDirectlySelectedAnnotation: PDFAnnotation?
    private var groupedPasteDragPageID: ObjectIdentifier?
    private var groupedPasteDragAnnotationIDs: Set<ObjectIdentifier> = []
    private var sidebarCurrentPageIndex: Int = -1
    private var bookmarkLabelOverrides: [String: String] = [:]
    private var pageLabelOverrides: [Int: String] = [:]
    var hasPromptedForInitialMarkupSaveCopy = false
    var isPresentingInitialMarkupSaveCopyPrompt = false
    private var isGridVisible = false
    private var autoNameCapturePhase: AutoNameCapturePhase?
    private var autoNameReferencePageIndex: Int?
    private var pendingSheetNumberZone: NormalizedPageRect?
    private var pendingSheetTitleZone: NormalizedPageRect?
    private var autoNamePreviousToolMode: ToolMode?
    var toolSettingsByTool: [ToolMode: ToolSettingsState] = [:]
    private var layerVisibilityByName: [String: Bool] = [:]
    private var layerToggleSwitches: [String: NSSwitch] = [:]
    var onDocumentOpened: ((URL) -> Void)?
    private var sidebarContainerView: NSView?
    private var lastSidebarExpandedWidth: CGFloat = 240
    private var isSidebarCollapsed = false
    private let markupsSectionButton = NSButton(title: "", target: nil, action: nil)
    private let summarySectionButton = NSButton(title: "", target: nil, action: nil)
    private let markupsSectionContent = NSStackView(frame: .zero)
    private let summarySectionContent = NSStackView(frame: .zero)
    private let toolSelector: NSSegmentedControl = {
        let control = NSSegmentedControl(labels: ["Select", "Grab", "Draw", "Arrow", "Line", "Polyline", "Highlighter", "Cloud", "Rect", "Text", "Callout"], trackingMode: .selectOne, target: nil, action: nil)
        control.selectedSegment = 0
        return control
    }()
    private let takeoffSelector: NSSegmentedControl = {
        let control = NSSegmentedControl(labels: ["Area", "Measure"], trackingMode: .selectOne, target: nil, action: nil)
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
        ("1\" = 1'-0\"", 1.0, 1.0),
        ("1/2\" = 1'-0\"", 0.5, 1.0),
        ("3/8\" = 1'-0\"", 0.375, 1.0),
        ("1/4\" = 1'-0\"", 0.25, 1.0),
        ("3/16\" = 1'-0\"", 0.1875, 1.0),
        ("1/8\" = 1'-0\"", 0.125, 1.0),
        ("1/16\" = 1'-0\"", 0.0625, 1.0),
        ("Custom…", -1.0, -1.0)
    ]
    private weak var newDocumentPanel: NSPanel?
    private weak var newDocumentSizePopup: NSPopUpButton?
    private weak var newDocumentOrientationPopup: NSPopUpButton?
    private var newDocumentPanelCloseObserver: NSObjectProtocol?
    private var didInstallToolbarWidthConstraints = false
    private var toolSelectorWidthConstraint: NSLayoutConstraint?
    private var takeoffSelectorWidthConstraint: NSLayoutConstraint?
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
        setupUI()
        configureWatchdogFromDefaults()
        startMarkupsRefreshTimer()
        updateEmptyStateVisibility()
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
    }

    private func setupUI() {
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true

        openButton.title = "Open"
        openButton.target = self
        openButton.action = #selector(openPDF)
        autoNameSheetsButton.target = self
        autoNameSheetsButton.action = #selector(commandAutoGenerateSheetNames(_:))
        emptyStateOpenButton.title = "Open Existing PDF"
        emptyStateOpenButton.target = self
        emptyStateOpenButton.action = #selector(openPDF)
        emptyStateRecentButton.target = self
        emptyStateRecentButton.action = #selector(showOpenRecentMenuFromEmptyState(_:))
        emptyStateSampleButton.target = self
        emptyStateSampleButton.action = #selector(createNewPDFAction)
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
        let sidebar = buildMarkupsSidebar()
        splitView.addArrangedSubview(sidebar)
        sidebarContainerView = sidebar
        let savedWidth = UserDefaults.standard.double(forKey: "DrawbridgeSidebarWidth")
        if savedWidth > 0 {
            lastSidebarExpandedWidth = min(max(CGFloat(savedWidth), 220), 280)
        } else {
            lastSidebarExpandedWidth = 240
        }
        isSidebarCollapsed = UserDefaults.standard.bool(forKey: "DrawbridgeSidebarCollapsed")
        sidebar.isHidden = isSidebarCollapsed
        sidebarPreferredWidthConstraint?.constant = min(max(lastSidebarExpandedWidth, 220), 280)
        collapsedSidebarRevealButton.isHidden = !isSidebarCollapsed
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
        pdfView.onAnnotationClicked = { [weak self] page, annotation in
            self?.selectMarkupFromPageClick(page: page, annotation: annotation)
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
            self?.grabClipboardPDFData = pdfData
            self?.grabClipboardPageRect = pageRect
            self?.grabClipboardTintBlendStyle = self?.preferredSnapshotTintBlendStyle(for: pdfData) ?? .screen
            let board = NSPasteboard.general
            board.clearContents()
            board.setData(pdfData, forType: .pdf)
            self?.showCaptureToast("Captured - Cmd+Shift+V to paste in place")
        }
        pdfView.onRegionCaptured = { [weak self] page, rectInPage in
            self?.handleAutoNameRegionCaptured(on: page, rectInPage: rectInPage)
        }
        pdfView.shouldBeginMarkupInteraction = { [weak self] in
            self?.ensureWorkingCopyBeforeFirstMarkup() ?? true
        }
        pdfView.layer?.addSublayer(selectedMarkupOverlayLayer)
        pdfView.layer?.addSublayer(selectedTextOverlayLayer)

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
            busyOverlayView.widthAnchor.constraint(equalToConstant: 300),
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
        pagesTableView.backgroundColor = sidebarBackgroundColor
        pagesTableView.gridStyleMask = []
        pagesTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        pagesTableView.delegate = self
        pagesTableView.dataSource = self
        pagesTableView.target = self
        pagesTableView.action = #selector(selectPageFromSidebar)

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

        let stack = NSStackView(views: [
            navigationTitleLabel,
            pagesControlRow,
            thumbnailScrollView,
            thumbnailsEmptyLabel,
            bookmarksScrollView,
            bookmarksEmptyLabel
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
        guard let document = pdfView.document else {
            NSSound.beep()
            return
        }
        guard let targetSize = preferredPageSizeForInsertion(in: document) else {
            return
        }
        let page = makeBlankPDFPage(size: targetSize)
        document.insert(page, at: max(0, document.pageCount))
        commitMarkupMutation(selecting: nil, forceImmediateRefresh: true)
        reloadBookmarks()
        pdfView.go(to: page)
        requestChromeRefresh(immediate: true)
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

    @objc private func selectPageFromSidebar() {
        let row = pagesTableView.selectedRow
        guard row >= 0, let document = pdfView.document, row < document.pageCount, let page = document.page(at: row) else {
            return
        }
        pdfView.go(to: page)
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
        pdfView.go(to: destination)
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
                pagesTableView.reloadData()
                updateStatusBar()
            }
        }

        bookmarksOutlineView.reloadData()
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

    private func configureMarkupsSidebar() {
        let pageColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        pageColumn.title = "Page"
        pageColumn.width = 56
        markupsTable.addTableColumn(pageColumn)

        let typeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        typeColumn.title = "Type"
        typeColumn.width = 100
        markupsTable.addTableColumn(typeColumn)

        let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        textColumn.title = "Text"
        textColumn.width = 280
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
        toolSettingsLineWidthPopup.target = self
        toolSettingsLineWidthPopup.action = #selector(toolSettingsChanged)
        snapshotColorizeButton.target = self
        snapshotColorizeButton.action = #selector(colorizeSnapshotsBlackToRed)
        snapshotColorizeButton.bezelStyle = .texturedRounded
        snapshotColorizeButton.isHidden = true

        measurementCountLabel.textColor = .secondaryLabelColor
        measurementTotalLabel.textColor = .secondaryLabelColor
        configureLayersSectionUI()
        configureSectionButtons()
        updateToolSettingsUIForCurrentTool()
        applyToolSettingsToPDFView()
    }

    private func configureSectionButtons() {
        markupsSectionButton.target = self
        markupsSectionButton.action = #selector(toggleMarkupsSection)
        summarySectionButton.target = self
        summarySectionButton.action = #selector(toggleSummarySection)
        layersSectionButton.target = self
        layersSectionButton.action = #selector(toggleLayersSection)

        toolSettingsSectionButton.isBordered = false
        toolSettingsSectionButton.isEnabled = false
        toolSettingsSectionButton.alignment = .left
        toolSettingsSectionButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        toolSettingsSectionButton.contentTintColor = .secondaryLabelColor

        [markupsSectionButton, summarySectionButton, layersSectionButton].forEach {
            $0.setButtonType(.momentaryPushIn)
            $0.bezelStyle = .recessed
            $0.alignment = .left
            $0.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        }
        updateSectionHeaders()
    }

    @objc private func toggleToolSettingsSection() {
        toolSettingsSectionContent.isHidden.toggle()
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

    private func updateSectionHeaders() {
        toolSettingsSectionButton.title = "Tool Settings"
        markupsSectionButton.title = "\(markupsSectionContent.isHidden ? "▸" : "▾") Markups"
        summarySectionButton.title = "\(summarySectionContent.isHidden ? "▸" : "▾") Takeoff Summary"
        layersSectionButton.title = "\(layersSectionContent.isHidden ? "▸" : "▾") Layers"
    }

    private func ensureLayerVisibilityDefaults() {
        for layer in snapshotLayerOptions where layerVisibilityByName[layer] == nil {
            layerVisibilityByName[layer] = true
        }
    }

    private func tintColor(forSnapshotLayer layer: String) -> NSColor {
        switch layer {
        case "ARCHITECTURAL":
            return NSColor(calibratedWhite: 0.72, alpha: 1.0) // light gray
        case "STRUCTURAL":
            return .systemRed
        case "MECHANICAL":
            return .systemGreen
        case "ELECTRICAL":
            return .systemOrange
        case "PLUMBING":
            return .systemBlue
        case "CIVL":
            return .systemTeal
        case "LANDSCAPE":
            return NSColor.systemGreen.blended(withFraction: 0.35, of: .systemBrown) ?? .systemGreen
        default:
            return .systemRed
        }
    }

    private func promptSnapshotLayerSelection(defaultLayer: String = "ARCHITECTURAL") -> String? {
        ensureLayerVisibilityDefaults()
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 28), pullsDown: false)
        popup.addItems(withTitles: snapshotLayerOptions)
        if let idx = snapshotLayerOptions.firstIndex(of: defaultLayer) {
            popup.selectItem(at: idx)
        } else {
            popup.selectItem(at: 0)
        }

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        popup.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            popup.centerYAnchor.constraint(equalTo: accessory.centerYAnchor)
        ])

        let alert = NSAlert()
        alert.messageText = "What layer?"
        alert.informativeText = "Choose the layer for this pasted grab."
        alert.alertStyle = .informational
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return popup.titleOfSelectedItem
    }

    private func configureLayersSectionUI() {
        ensureLayerVisibilityDefaults()
        layersSectionContent.orientation = .vertical
        layersSectionContent.spacing = 6
        layersRowsStack.orientation = .vertical
        layersRowsStack.spacing = 4

        for view in layersRowsStack.arrangedSubviews {
            layersRowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        layerToggleSwitches.removeAll()

        for layer in snapshotLayerOptions {
            let label = NSTextField(labelWithString: layer)
            label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            label.lineBreakMode = .byTruncatingTail

            let toggle = NSSwitch(frame: .zero)
            toggle.state = (layerVisibilityByName[layer] ?? true) ? .on : .off
            toggle.target = self
            toggle.action = #selector(layerToggleChanged(_:))
            toggle.identifier = NSUserInterfaceItemIdentifier(layer)
            layerToggleSwitches[layer] = toggle

            let row = NSStackView(views: [label, NSView(), toggle])
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .centerY
            layersRowsStack.addArrangedSubview(row)
        }

        layersSectionContent.addArrangedSubview(layersRowsStack)
    }

    @objc private func layerToggleChanged(_ sender: NSSwitch) {
        guard let layer = sender.identifier?.rawValue, !layer.isEmpty else { return }
        layerVisibilityByName[layer] = (sender.state == .on)
        applySnapshotLayerVisibility()
    }

    private func applySnapshotLayerVisibility() {
        guard let document = pdfView.document else { return }
        ensureLayerVisibilityDefaults()
        var hidSelectedSnapshot = false
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                guard let snapshot = annotation as? PDFSnapshotAnnotation else { continue }
                let layer = snapshot.snapshotLayerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let isVisible = layer.isEmpty ? true : (layerVisibilityByName[layer] ?? true)
                snapshot.shouldDisplay = isVisible
                snapshot.shouldPrint = isVisible
                if !isVisible, lastDirectlySelectedAnnotation === snapshot {
                    hidSelectedSnapshot = true
                }
            }
        }
        if hidSelectedSnapshot {
            clearMarkupSelection()
        } else {
            updateSelectionOverlay()
            updateToolSettingsUIForCurrentTool()
            updateStatusBar()
        }
        pdfView.needsDisplay = true
    }

    private func configureActionsPopup(highlightButton: NSButton, exportButton: NSButton, refreshMarkupsButton: NSButton, deleteMarkupButton: NSButton, editMarkupButton: NSButton) {
        actionsPopup.removeAllItems()
        actionsPopup.addItem(withTitle: "")

        let menu = NSMenu(title: "Actions")
        menu.addItem(withTitle: highlightButton.title, action: highlightButton.action, keyEquivalent: "h")
        menu.item(at: menu.numberOfItems - 1)?.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: exportButton.title, action: exportButton.action, keyEquivalent: "S")
        menu.item(at: menu.numberOfItems - 1)?.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Export Markups CSV", action: #selector(exportMarkupsCSV), keyEquivalent: "")
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
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: statusBar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: statusBar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: statusBar.trailingAnchor)
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

        busyProgressIndicator.style = .bar
        busyProgressIndicator.isIndeterminate = true
        busyProgressIndicator.controlSize = .small
        busyProgressIndicator.translatesAutoresizingMaskIntoConstraints = false
        busyProgressIndicator.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let stack = NSStackView(views: [busyStatusLabel, busyDetailLabel, busyProgressIndicator])
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
        busyOverlayView.isHidden = true
        busyDetailLabel.stringValue = ""
    }

    func updateBusyIndicatorDetail(_ detail: String) {
        busyDetailLabel.stringValue = detail
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

    func promptSnapshotLayerAssignmentIfNeeded() {
        let snapshots = currentSelectedMarkupItems().compactMap { $0.annotation as? PDFSnapshotAnnotation }
        guard snapshots.count == 1, let selectedSnapshot = snapshots.first else { return }
        let currentLayer = selectedSnapshot.snapshotLayerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard currentLayer.isEmpty else { return }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 28), pullsDown: false)
        popup.addItems(withTitles: snapshotLayerOptions)
        popup.selectItem(at: 0)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        popup.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            popup.centerYAnchor.constraint(equalTo: accessory.centerYAnchor)
        ])

        let alert = NSAlert()
        alert.messageText = "Assign Snapshot Layer"
        alert.informativeText = "Choose the layer for this pasted grab markup."
        alert.alertStyle = .informational
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Assign Layer")
        alert.addButton(withTitle: "Skip")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let layer = popup.titleOfSelectedItem, !layer.isEmpty else { return }

        let previous = snapshot(for: selectedSnapshot)
        selectedSnapshot.snapshotLayerName = layer
        registerAnnotationStateUndo(annotation: selectedSnapshot, previous: previous, actionName: "Assign Snapshot Layer")
        markPageMarkupCacheDirty(selectedSnapshot.page)
        markMarkupChanged()
        applySnapshotLayerVisibility()
        performRefreshMarkups(selecting: selectedSnapshot)
        scheduleAutosave()
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

        let actions = NSStackView(views: [emptyStateOpenButton, emptyStateRecentButton, emptyStateSampleButton])
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
            NSSound.beep()
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

        actionsPopup.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Actions")
        actionsPopup.imagePosition = .imageOnly
        actionsPopup.bezelStyle = .texturedRounded
        actionsPopup.toolTip = "Actions"

        gridToggleButton.setButtonType(.toggle)
        gridToggleButton.image = NSImage(systemSymbolName: "grid", accessibilityDescription: "Toggle Grid")
        gridToggleButton.imagePosition = .imageOnly
        gridToggleButton.bezelStyle = .texturedRounded
        gridToggleButton.toolTip = "Show/Hide Grid"
        gridToggleButton.target = self
        gridToggleButton.action = #selector(toggleGridOverlay)
        gridToggleButton.state = isGridVisible ? .on : .off

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
        toolbarControlsStack.spacing = 12
        toolbarControlsStack.alignment = .centerY
        toolbarControlsStack.setHuggingPriority(.required, for: .horizontal)
        toolbarControlsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        toolSelector.translatesAutoresizingMaskIntoConstraints = false
        let selectorWidth = CGFloat(toolSelector.segmentCount) * 42.0
        if let existing = toolSelectorWidthConstraint {
            existing.constant = selectorWidth
        } else {
            let widthConstraint = toolSelector.widthAnchor.constraint(equalToConstant: selectorWidth)
            widthConstraint.priority = .required
            widthConstraint.isActive = true
            toolSelectorWidthConstraint = widthConstraint
        }
        if toolbarControlsStack.arrangedSubviews.isEmpty {
            toolbarControlsStack.addArrangedSubview(openButton)
            toolbarControlsStack.addArrangedSubview(autoNameSheetsButton)
            toolbarControlsStack.addArrangedSubview(toolSelector)
        }

        toolbarSearchField.placeholderString = "Search document + markups"
        toolbarSearchField.sendsWholeSearchString = false
        toolbarSearchField.maximumRecents = 0
        toolbarSearchField.recentsAutosaveName = nil
        toolbarSearchField.target = self
        toolbarSearchField.action = #selector(searchFieldChanged)
        toolbarSearchField.translatesAutoresizingMaskIntoConstraints = false
        toolbarSearchField.widthAnchor.constraint(equalToConstant: 330).isActive = true
        toolbarSearchPrevButton.title = "◀"
        toolbarSearchPrevButton.bezelStyle = .texturedRounded
        toolbarSearchPrevButton.target = self
        toolbarSearchPrevButton.action = #selector(selectPreviousSearchHit)
        toolbarSearchPrevButton.toolTip = "Previous Result"
        toolbarSearchPrevButton.setButtonType(.momentaryPushIn)
        toolbarSearchPrevButton.controlSize = .small
        toolbarSearchNextButton.title = "▶"
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
        secondaryToolbarControlsStack.spacing = 10
        secondaryToolbarControlsStack.alignment = .centerY
        secondaryToolbarControlsStack.setHuggingPriority(.required, for: .horizontal)
        secondaryToolbarControlsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        takeoffSelector.translatesAutoresizingMaskIntoConstraints = false
        let takeoffWidth = CGFloat(takeoffSelector.segmentCount) * 44.0
        if let existing = takeoffSelectorWidthConstraint {
            existing.constant = takeoffWidth
        } else {
            let widthConstraint = takeoffSelector.widthAnchor.constraint(equalToConstant: takeoffWidth)
            widthConstraint.priority = .required
            widthConstraint.isActive = true
            takeoffSelectorWidthConstraint = widthConstraint
        }
        if secondaryToolbarControlsStack.arrangedSubviews.isEmpty {
            secondaryToolbarControlsStack.addArrangedSubview(takeoffSelector)
            secondaryToolbarControlsStack.addArrangedSubview(scalePresetPopup)
            secondaryToolbarControlsStack.addArrangedSubview(gridToggleButton)
            secondaryToolbarControlsStack.addArrangedSubview(actionsPopup)
        }
    }

    @objc private func toggleGridOverlay() {
        isGridVisible = (gridToggleButton.state == .on)
        pdfView.setGridVisible(isGridVisible)
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

        documentTabsStack.orientation = .horizontal
        documentTabsStack.alignment = .centerY
        documentTabsStack.spacing = 6
        documentTabsStack.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)
        documentTabsStack.translatesAutoresizingMaskIntoConstraints = false
        documentTabsBar.addSubview(documentTabsStack)

        NSLayoutConstraint.activate([
            documentTabsStack.topAnchor.constraint(equalTo: documentTabsBar.topAnchor),
            documentTabsStack.leadingAnchor.constraint(equalTo: documentTabsBar.leadingAnchor),
            documentTabsStack.trailingAnchor.constraint(lessThanOrEqualTo: documentTabsBar.trailingAnchor),
            documentTabsStack.bottomAnchor.constraint(equalTo: documentTabsBar.bottomAnchor)
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
        scalePresetPopup.widthAnchor.constraint(equalToConstant: 112).isActive = true
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
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        func symbol(_ names: [String], _ description: String) -> NSImage? {
            for name in names {
                if let image = NSImage(systemSymbolName: name, accessibilityDescription: description) {
                    return image.withSymbolConfiguration(symbolConfig)
                }
            }
            return nil
        }
        let symbols = [
            symbol(["cursorarrow"], "Select"),
            symbol(["camera.viewfinder", "camera"], "Grab"),
            symbol(["pencil.tip", "pencil"], "Pen"),
            symbol(["arrow.up.right"], "Arrow"),
            symbol(["line.diagonal"], "Line"),
            symbol(["point.3.filled.connected.trianglepath.dotted"], "Polyline"),
            symbol(["highlighter", "pencil.and.scribble", "scribble"], "Highlighter"),
            symbol(["cloud"], "Cloud"),
            symbol(["square"], "Rectangle"),
            symbol(["textformat"], "Text"),
            symbol(["text.bubble", "text.bubble.fill"], "Callout")
        ]

        toolSelector.trackingMode = .selectOne
        toolSelector.setLabel("V", forSegment: 0)
        toolSelector.setLabel("G", forSegment: 1)
        toolSelector.setLabel("D", forSegment: 2)
        toolSelector.setLabel("A", forSegment: 3)
        toolSelector.setLabel("L", forSegment: 4)
        toolSelector.setLabel("P", forSegment: 5)
        toolSelector.setLabel("H", forSegment: 6)
        toolSelector.setLabel("C", forSegment: 7)
        toolSelector.setLabel("R", forSegment: 8)
        toolSelector.setLabel("T", forSegment: 9)
        toolSelector.setLabel("Q", forSegment: 10)
        for idx in 0..<11 {
            if let icon = symbols[idx] {
                toolSelector.setImage(icon, forSegment: idx)
            }
            toolSelector.setWidth(42, forSegment: idx)
        }
        toolSelector.selectedSegmentBezelColor = NSColor.systemBlue.withAlphaComponent(0.35)
        toolSelector.wantsLayer = true

        toolSelector.setToolTip("Select (V)", forSegment: 0)
        toolSelector.setToolTip("Grab (G)", forSegment: 1)
        toolSelector.setToolTip("Draw (D)", forSegment: 2)
        toolSelector.setToolTip("Arrow (A)", forSegment: 3)
        toolSelector.setToolTip("Line (L)", forSegment: 4)
        toolSelector.setToolTip("Polyline (P)", forSegment: 5)
        toolSelector.setToolTip("Highlighter (H)", forSegment: 6)
        toolSelector.setToolTip("Cloud (C)", forSegment: 7)
        toolSelector.setToolTip("Rectangle (R)", forSegment: 8)
        toolSelector.setToolTip("Text (T)", forSegment: 9)
        toolSelector.setToolTip("Callout (Q)", forSegment: 10)
    }

    private func configureTakeoffSelectorAppearance() {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let areaIcon = NSImage(systemSymbolName: "polygon", accessibilityDescription: "Area")?.withSymbolConfiguration(symbolConfig)
        let measureIcon = NSImage(systemSymbolName: "ruler", accessibilityDescription: "Measure")?.withSymbolConfiguration(symbolConfig)
        takeoffSelector.trackingMode = .selectOne
        takeoffSelector.setLabel("A", forSegment: 0)
        takeoffSelector.setLabel("M", forSegment: 1)
        if let areaIcon {
            takeoffSelector.setImage(areaIcon, forSegment: 0)
        }
        if let measureIcon {
            takeoffSelector.setImage(measureIcon, forSegment: 1)
        }
        takeoffSelector.setWidth(44, forSegment: 0)
        takeoffSelector.setWidth(44, forSegment: 1)
        takeoffSelector.selectedSegmentBezelColor = NSColor.systemBlue.withAlphaComponent(0.35)
        takeoffSelector.wantsLayer = true
        takeoffSelector.setToolTip("Area (Shift+A)", forSegment: 0)
        takeoffSelector.setToolTip("Measure (M)", forSegment: 1)
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
            sidebarSpacer,
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
        let requestedMode: ToolMode
        switch toolSelector.selectedSegment {
        case 0: requestedMode = .select
        case 1: requestedMode = .grab
        case 2: requestedMode = .pen
        case 3: requestedMode = .arrow
        case 4: requestedMode = .line
        case 5: requestedMode = .polyline
        case 6: requestedMode = .highlighter
        case 7: requestedMode = .cloud
        case 8: requestedMode = .rectangle
        case 9: requestedMode = .text
        case 10: requestedMode = .callout
        default: requestedMode = .pen
        }
        activateTool(requestedMode)
    }

    @objc private func changeTakeoffTool() {
        let requestedMode: ToolMode
        switch takeoffSelector.selectedSegment {
        case 0: requestedMode = .area
        case 1: requestedMode = .measure
        default: return
        }
        activateTool(requestedMode)
    }

    private func activateTool(_ requestedMode: ToolMode) {
        persistToolSettingsFromControls(for: pdfView.toolMode)
        if requestedMode == .area && !isDrawingScaleConfigured() {
            showAreaScaleRequiredWarning()
            toolSelector.selectedSegment = segmentIndex(for: pdfView.toolMode)
            takeoffSelector.selectedSegment = takeoffSegmentIndex(for: pdfView.toolMode)
            return
        }

        if requestedMode != .measure {
            pdfView.cancelPendingMeasurement()
        }
        if requestedMode != .callout {
            pdfView.cancelPendingCallout()
        }
        if requestedMode != .polyline {
            pdfView.cancelPendingPolyline()
        }
        if requestedMode != .arrow {
            pdfView.cancelPendingArrow()
        }
        if requestedMode != .area {
            pdfView.cancelPendingArea()
        }

        pdfView.toolMode = requestedMode
        applyStoredToolSettings(to: requestedMode)
        if toolSelector.selectedSegment >= 0 || takeoffSelector.selectedSegment >= 0 {
            animateToolSelectionFeedback()
        }
        updateToolSettingsUIForCurrentTool()
        applyToolSettingsToPDFView()
        updateStatusBar()
    }

    @objc func selectPenTool(_ sender: Any?) {
        setTool(.pen)
    }

    @objc func selectGrabTool(_ sender: Any?) {
        setTool(.grab)
    }

    @objc func selectLineTool(_ sender: Any?) {
        setTool(.line)
    }

    @objc func selectArrowTool(_ sender: Any?) {
        setTool(.arrow)
    }

    @objc func selectPolylineTool(_ sender: Any?) {
        setTool(.polyline)
    }

    @objc func selectSelectionTool(_ sender: Any?) {
        setTool(.select)
    }

    @objc func selectCloudTool(_ sender: Any?) {
        setTool(.cloud)
    }

    @objc func selectHighlighterTool(_ sender: Any?) {
        setTool(.highlighter)
    }

    @objc func selectRectangleTool(_ sender: Any?) {
        setTool(.rectangle)
    }

    @objc func selectTextTool(_ sender: Any?) {
        setTool(.text)
    }

    @objc func selectCalloutTool(_ sender: Any?) {
        setTool(.callout)
    }

    @objc func selectMeasureTool(_ sender: Any?) {
        setTool(.measure)
    }

    @objc func selectAreaTool(_ sender: Any?) {
        setTool(.area)
    }

    @objc func selectCalibrateTool(_ sender: Any?) {
        setTool(.calibrate)
    }

    func setTool(_ mode: ToolMode) {
        switch mode {
        case .select:
            toolSelector.selectedSegment = 0
            takeoffSelector.selectedSegment = -1
        case .grab:
            toolSelector.selectedSegment = 1
            takeoffSelector.selectedSegment = -1
        case .pen:
            toolSelector.selectedSegment = 2
            takeoffSelector.selectedSegment = -1
        case .arrow:
            toolSelector.selectedSegment = 3
            takeoffSelector.selectedSegment = -1
        case .line:
            toolSelector.selectedSegment = 4
            takeoffSelector.selectedSegment = -1
        case .polyline:
            toolSelector.selectedSegment = 5
            takeoffSelector.selectedSegment = -1
        case .highlighter:
            toolSelector.selectedSegment = 6
            takeoffSelector.selectedSegment = -1
        case .cloud:
            toolSelector.selectedSegment = 7
            takeoffSelector.selectedSegment = -1
        case .rectangle:
            toolSelector.selectedSegment = 8
            takeoffSelector.selectedSegment = -1
        case .text:
            toolSelector.selectedSegment = 9
            takeoffSelector.selectedSegment = -1
        case .callout:
            toolSelector.selectedSegment = 10
            takeoffSelector.selectedSegment = -1
        case .area:
            toolSelector.selectedSegment = -1
            takeoffSelector.selectedSegment = 0
            toolSettingsLineWidthPopup.selectItem(withTitle: "1")
            pdfView.areaLineWidth = 1.0
        case .measure:
            toolSelector.selectedSegment = -1
            takeoffSelector.selectedSegment = 1
        case .calibrate:
            toolSelector.selectedSegment = -1
            takeoffSelector.selectedSegment = -1
            pdfView.cancelPendingCallout()
            pdfView.cancelPendingPolyline()
            pdfView.cancelPendingArrow()
            pdfView.cancelPendingArea()
            pdfView.toolMode = .calibrate
            updateToolSettingsUIForCurrentTool()
            applyToolSettingsToPDFView()
            updateStatusBar()
            return
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
            NSSound.beep()
            return
        }
        guard let selectedLayer = promptSnapshotLayerSelection() else {
            return
        }

        guard let snapshotURL = persistGrabSnapshotPDFData(pdfData) else {
            NSSound.beep()
            return
        }

        let annotation = PDFSnapshotAnnotation(bounds: sourceRect, snapshotURL: snapshotURL)
        annotation.renderOpacity = 1.0
        annotation.renderTintColor = tintColor(forSnapshotLayer: selectedLayer)
        annotation.renderTintStrength = 1.0
        annotation.tintBlendStyle = grabClipboardTintBlendStyle
        annotation.lineworkOnlyTint = true
        annotation.snapshotLayerName = selectedLayer
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

    private func persistGrabSnapshotPDFData(_ data: Data) -> URL? {
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let directory = root?
                .appendingPathComponent("Drawbridge", isDirectory: true)
                .appendingPathComponent("GrabSnapshots", isDirectory: true)
            guard let directory else { return nil }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("grab-\(UUID().uuidString).pdf")
            try data.write(to: url, options: .atomic)
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
            NSSound.beep()
            return
        }

        let document = PDFDocument()
        document.insert(page, at: 0)
        pdfView.document = document
        clearMarkupCache()
        openDocumentURL = nil
        hasPromptedForInitialMarkupSaveCopy = true
        isPresentingInitialMarkupSaveCopyPrompt = false
        configureAutosaveURL(for: nil)
        view.window?.title = "Drawbridge - Untitled"
        view.window?.makeFirstResponder(pdfView)
        markupChangeVersion = 0
        lastAutosavedChangeVersion = 0
        lastMarkupEditAt = .distantPast
        lastUserInteractionAt = .distantPast
        view.window?.isDocumentEdited = false
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

    @objc func saveCopy() {
        saveDocumentAsCopy()
    }

    @objc func saveDocument() {
        guard let document = pdfView.document else {
            NSSound.beep()
            return
        }
        if let url = openDocumentURL {
            // Keep Save fast for iterative markup work; full PDF rewrite stays on Save As PDF.
            persistProjectSnapshot(document: document, for: url, busyMessage: "Saving Changes…")
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
        guard let document = pdfView.document else {
            NSSound.beep()
            return
        }

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

    func pasteCopiedMarkupsFromPasteboard() {
        guard let document = pdfView.document else {
            NSSound.beep()
            return
        }
        guard ensureWorkingCopyBeforeFirstMarkup() else { return }
        guard let raw = NSPasteboard.general.data(forType: markupClipboardPasteboardType),
              let payload = try? PropertyListDecoder().decode(MarkupClipboardPayload.self, from: raw),
              !payload.records.isEmpty else {
            NSSound.beep()
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
            NSSound.beep()
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
            registerAnnotationPresenceUndo(page: destinationPage, annotation: annotation, shouldExist: false, actionName: "Paste Markup")
            markPageMarkupCacheDirty(destinationPage)
            pasted.append(annotation)
        }

        guard !pasted.isEmpty else {
            NSSound.beep()
            return
        }
        commitMarkupMutation(selecting: pasted.first, forceImmediateRefresh: true)
        selectMarkupsFromFence(page: destinationPage, annotations: pasted, enablesGroupedDrag: true)
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
                    let annotations = page.annotations
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
    }

    func totalCachedAnnotationCount() -> Int {
        cachedMarkupAnnotationCount
    }

    private func annotationSearchText(for annotation: PDFAnnotation) -> String {
        let type = annotation.type ?? ""
        let contents = annotation.contents ?? ""
        return "\(type)\n\(contents)".lowercased()
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
        return document.page(at: pageIndex)?.annotations ?? []
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

    private func markMarkupChanged() {
        promptInitialMarkupSaveCopyIfNeeded()
        markupChangeVersion += 1
        lastMarkupEditAt = Date()
        lastUserInteractionAt = Date()
        view.window?.isDocumentEdited = true
        refreshSearchIfNeeded()
    }

    private func markMarkupChangedAndScheduleAutosave() {
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
        if shouldScheduleAutosave {
            scheduleAutosave()
        }
        PerformanceMetrics.end(mutationSpan, extra: ["result": "ok"])
    }

    private func promptInitialMarkupSaveCopyIfNeeded() {
        guard !hasPromptedForInitialMarkupSaveCopy,
              !isPresentingInitialMarkupSaveCopyPrompt,
              !persistenceCoordinator.isManualSaveInFlight,
              let sourceURL = openDocumentURL,
              pdfView.document != nil else {
            return
        }
        let name = sourceURL.lastPathComponent.lowercased()
        if name.contains(" - markups ") {
            hasPromptedForInitialMarkupSaveCopy = true
            return
        }
        isPresentingInitialMarkupSaveCopyPrompt = true
        defer { isPresentingInitialMarkupSaveCopyPrompt = false }

        let didCreateWorkingCopy = promptForInitialMarkupWorkingCopy(from: sourceURL)
        hasPromptedForInitialMarkupSaveCopy = didCreateWorkingCopy
    }

    private func ensureWorkingCopyBeforeFirstMarkup() -> Bool {
        guard !hasPromptedForInitialMarkupSaveCopy,
              !isPresentingInitialMarkupSaveCopyPrompt,
              !persistenceCoordinator.isManualSaveInFlight,
              let sourceURL = openDocumentURL,
              pdfView.document != nil else {
            return true
        }
        let name = sourceURL.lastPathComponent.lowercased()
        if name.contains(" - markups ") {
            hasPromptedForInitialMarkupSaveCopy = true
            return true
        }
        isPresentingInitialMarkupSaveCopyPrompt = true
        defer { isPresentingInitialMarkupSaveCopyPrompt = false }
        let didCreateWorkingCopy = promptForInitialMarkupWorkingCopy(from: sourceURL)
        hasPromptedForInitialMarkupSaveCopy = didCreateWorkingCopy
        return didCreateWorkingCopy
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
            let alert = NSAlert()
            alert.messageText = "Failed to create working copy"
            alert.informativeText = "Could not copy \(sourceURL.lastPathComponent).\n\n\(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()
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
        guard let document = pdfView.document else {
            NSSound.beep()
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Drawbridge-Markups.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var rows: [String] = []
        rows.append("page,type,text,x,y,width,height")

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
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
            let alert = NSAlert()
            alert.messageText = "Failed to export CSV"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
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
            let alert = NSAlert()
            alert.messageText = "Unable to open PDF"
            alert.informativeText = "\(url.lastPathComponent) is not a valid PDF."
            alert.alertStyle = .critical
            alert.runModal()
            return
        }

        pdfView.document = document
        clearMarkupCache()
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
        markupChangeVersion = 0
        lastAutosavedChangeVersion = 0
        lastMarkupEditAt = .distantPast
        lastUserInteractionAt = .distantPast
        view.window?.isDocumentEdited = false
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

    func canonicalDocumentURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    func clearToStartState() {
        cancelAutoNameCapture()
        pdfView.document = nil
        clearMarkupCache()
        pageLabelOverrides.removeAll()
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
        markupChangeVersion = 0
        lastAutosavedChangeVersion = 0
        lastMarkupEditAt = .distantPast
        lastUserInteractionAt = .distantPast
        markupsTable.deselectAll(nil)
        clearSelectionOverlayLayers()
        refreshMarkups()
        resetSearchState(clearQuery: true)
        view.window?.title = "Drawbridge"
        view.window?.isDocumentEdited = false
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
        pdfView.go(to: destination)
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
            clearSelectionOverlayLayers()
            return
        }

        let genericPath = CGMutablePath()
        let textPath = CGMutablePath()
        var addedGeneric = false
        var addedText = false
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

        selectedMarkupOverlayLayer.path = genericPath
        selectedMarkupOverlayLayer.isHidden = !addedGeneric
        selectedTextOverlayLayer.path = textPath
        selectedTextOverlayLayer.isHidden = !addedText
    }

    private func selectMarkupsFromFence(page: PDFPage, annotations: [PDFAnnotation], enablesGroupedDrag: Bool = false) {
        guard let document = pdfView.document else { return }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return }

        var selected = Set(annotations.map(ObjectIdentifier.init))
        for annotation in annotations {
            for sibling in relatedCalloutAnnotations(for: annotation, on: page) {
                selected.insert(ObjectIdentifier(sibling))
            }
        }
        performRefreshMarkups(selecting: nil)
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
            let summary = measurementSummary(for: page.annotations)
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
        }

        let zoomPercent = Int(round(pdfView.scaleFactor * 100))
        statusZoomLabel.stringValue = "Zoom: \(zoomPercent)%"
        let scaleText = measurementScaleField.stringValue.isEmpty ? "1.0" : measurementScaleField.stringValue
        let unit = measurementUnitPopup.titleOfSelectedItem ?? pdfView.measurementUnitLabel
        statusScaleLabel.stringValue = "Scale: \(scaleText) \(unit)"
    }

    func currentToolName() -> String {
        switch pdfView.toolMode {
        case .select:
            return "Selection"
        case .grab:
            return "Grab"
        case .pen:
            return "Draw"
        case .arrow:
            return "Arrow"
        case .line:
            return "Line"
        case .polyline:
            return "Polyline"
        case .area:
            return "Area"
        case .highlighter:
            return "Highlighter"
        case .cloud:
            return "Cloud"
        case .rectangle:
            return "Rectangle"
        case .text:
            return "Text"
        case .callout:
            return "Callout"
        case .measure:
            return "Measure"
        case .calibrate:
            return "Calibrate"
        }
    }

    private func segmentIndex(for mode: ToolMode) -> Int {
        switch mode {
        case .select: return 0
        case .grab: return 1
        case .pen: return 2
        case .arrow: return 3
        case .line: return 4
        case .polyline: return 5
        case .highlighter: return 6
        case .cloud: return 7
        case .rectangle: return 8
        case .text: return 9
        case .callout: return 10
        case .area, .measure: return -1
        case .calibrate: return -1
        }
    }

    private func takeoffSegmentIndex(for mode: ToolMode) -> Int {
        switch mode {
        case .area: return 0
        case .measure: return 1
        default: return -1
        }
    }

    private func isDrawingScaleConfigured() -> Bool {
        let title = scalePresetPopup.titleOfSelectedItem ?? ""
        return title != "Scale: Not Set"
    }

    private func showAreaScaleRequiredWarning() {
        let alert = NSAlert()
        alert.messageText = "Set Drawing Scale First"
        alert.informativeText = "Area takeoff requires a drawing scale. Set scale before using the Area tool."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

    private func bookmarkContainsCurrentPage(_ outline: PDFOutline) -> Bool {
        guard sidebarCurrentPageIndex >= 0 else { return false }
        return destinationPageIndex(for: outline) == sidebarCurrentPageIndex
    }

    func startAutoGenerateSheetNamesFlow() {
        guard let document = pdfView.document,
              let currentPage = pdfView.currentPage else {
            NSSound.beep()
            return
        }
        autoNameReferencePageIndex = document.index(for: currentPage)
        guard autoNameReferencePageIndex ?? -1 >= 0 else {
            NSSound.beep()
            return
        }
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
            let alert = NSAlert()
            alert.messageText = "Capture On Reference Page"
            alert.informativeText = "Please capture zones on the same page where you started."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
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
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let numberRect = denormalize(rect: numberZone, for: page)
            let titleRect = denormalize(rect: titleZone, for: page)
            let detectedNumber = extractText(from: page, rectInPage: numberRect)
            let number = detectedNumber.isEmpty ? "Page \(pageIndex + 1)" : detectedNumber
            let title = extractText(from: page, rectInPage: titleRect)
            generated.append(
                AutoNamedSheet(
                    pageIndex: pageIndex,
                    sheetNumber: number,
                    sheetTitle: title
                )
            )
        }

        guard !generated.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Pages Found"
            alert.informativeText = "Could not generate names for this document."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
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

    private func applyAutoNamedSheets(_ sheets: [AutoNamedSheet], to document: PDFDocument, applyPageLabels: Bool) {
        if applyPageLabels {
            pageLabelOverrides.removeAll()
            for sheet in sheets {
                let cleanedTitle = sheet.sheetTitle.isEmpty ? "Untitled" : sheet.sheetTitle
                pageLabelOverrides[sheet.pageIndex] = "\(sheet.sheetNumber) - \(cleanedTitle)"
            }
        }

        let root = PDFOutline()
        for sheet in sheets {
            guard let page = document.page(at: sheet.pageIndex) else { continue }
            let item = PDFOutline()
            let cleanedTitle = sheet.sheetTitle.isEmpty ? "Untitled" : sheet.sheetTitle
            item.label = "\(sheet.sheetNumber) - \(cleanedTitle)"
            let target = NSPoint(x: 0, y: page.bounds(for: .mediaBox).maxY)
            item.destination = PDFDestination(page: page, at: target)
            root.insertChild(item, at: root.numberOfChildren)
        }
        document.outlineRoot = root

        markMarkupChangedAndScheduleAutosave()
        reloadBookmarks()
        updateStatusBar()

        let alert = NSAlert()
        alert.messageText = "Sheet Names Updated"
        if applyPageLabels {
            alert.informativeText = "Applied bookmarks and page labels for \(sheets.count) pages."
        } else {
            alert.informativeText = "Applied bookmarks for \(sheets.count) pages."
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func normalize(rectInPage: NSRect, for page: PDFPage) -> NormalizedPageRect {
        let bounds = page.bounds(for: .mediaBox)
        let safeWidth = max(bounds.width, 1)
        let safeHeight = max(bounds.height, 1)
        return NormalizedPageRect(
            x: (rectInPage.minX - bounds.minX) / safeWidth,
            y: (rectInPage.minY - bounds.minY) / safeHeight,
            width: rectInPage.width / safeWidth,
            height: rectInPage.height / safeHeight
        )
    }

    private func denormalize(rect: NormalizedPageRect, for page: PDFPage) -> NSRect {
        let bounds = page.bounds(for: .mediaBox)
        return NSRect(
            x: bounds.minX + rect.x * bounds.width,
            y: bounds.minY + rect.y * bounds.height,
            width: rect.width * bounds.width,
            height: rect.height * bounds.height
        )
    }

    private func extractText(from page: PDFPage, rectInPage: NSRect) -> String {
        let bounded = rectInPage.intersection(page.bounds(for: .mediaBox))
        guard !bounded.isEmpty else { return "" }

        if let selected = page.selection(for: bounded)?.string {
            let cleaned = cleanDetectedSheetText(selected)
            if !cleaned.isEmpty {
                return cleaned
            }
        }

        guard let image = renderCroppedImage(from: page, rectInPage: bounded) else {
            return ""
        }
        return recognizeText(in: image)
    }

    private func renderCroppedImage(from page: PDFPage, rectInPage: NSRect) -> CGImage? {
        let crop = rectInPage.intersection(page.bounds(for: .mediaBox))
        guard crop.width > 1, crop.height > 1 else { return nil }

        let scale: CGFloat = 2.0
        let width = Int((crop.width * scale).rounded(.up))
        let height = Int((crop.height * scale).rounded(.up))
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -crop.minX, y: -crop.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    private func recognizeText(in image: CGImage) -> String {
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .left, .down]
        var bestText = ""
        var bestScore: Float = -.greatestFiniteMagnitude

        for orientation in orientations {
            guard let result = recognizeText(in: image, orientation: orientation) else { continue }
            if result.score > bestScore {
                bestScore = result.score
                bestText = result.text
            }
        }
        return bestText
    }

    private func recognizeText(in image: CGImage, orientation: CGImagePropertyOrientation) -> (text: String, score: Float)? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
            guard let observations = request.results, !observations.isEmpty else { return nil }
            var pieces: [String] = []
            pieces.reserveCapacity(observations.count)
            var confidenceSum: Float = 0
            var recognizedCount: Float = 0
            for observation in observations {
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

    private func cleanDetectedSheetText(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
