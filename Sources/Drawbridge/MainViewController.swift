import AppKit
@preconcurrency
import PDFKit
import UniformTypeIdentifiers
import Vision

@MainActor
final class MainViewController: NSViewController, NSToolbarDelegate, NSMenuItemValidation, NSSplitViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private struct PDFDocumentBox: @unchecked Sendable {
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
    private enum AutoNameCapturePhase {
        case sheetNumber
        case sheetTitle
    }

    private let lineWeightLevels = Array(1...10)

    private static let defaultsAdaptiveIndexCapEnabledKey = "DrawbridgeAdaptiveIndexCapEnabled"
    private static let defaultsIndexCapKey = "DrawbridgeIndexCap"
    private static let defaultsWatchdogEnabledKey = "DrawbridgeWatchdogEnabled"
    private static let defaultsWatchdogThresholdSecondsKey = "DrawbridgeWatchdogThresholdSeconds"
    private static let markupCopyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyMMdd"
        return formatter
    }()

    private let rulerThickness: CGFloat = 22
    private let showNavigationPane = true
    private let pdfView = MarkupPDFView(frame: .zero)
    private let pdfCanvasContainer = StartupDropView(frame: .zero)
    private let bookmarksContainer = NSVisualEffectView(frame: .zero)
    private let navigationTitleLabel = NSTextField(labelWithString: "Navigation")
    private let navigationModeControl = NSSegmentedControl(labels: ["Pages", "Bookmarks"], trackingMode: .selectOne, target: nil, action: nil)
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
    private let emptyStateSampleButton = NSButton(title: "Create New", target: nil, action: nil)
    private let markupsTable = NSTableView(frame: .zero)
    private let markupsCountLabel = NSTextField(labelWithString: "0 items")
    private let markupFilterField = NSSearchField(frame: .zero)
    private let measurementScaleField = NSTextField(frame: .zero)
    private let measurementUnitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
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
    private let pageJumpField = ClickOnlyTextField(frame: .zero)
    private let scalePresetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let measureLabel = NSTextField(labelWithString: "Measure:")
    private let toolbarControlsStack = NSStackView(frame: .zero)
    private let secondaryToolbarControlsStack = NSStackView(frame: .zero)
    private let documentTabsBar = NSVisualEffectView(frame: .zero)
    private let documentTabsStack = NSStackView(frame: .zero)
    private let statusBar = NSVisualEffectView(frame: .zero)
    private let busyOverlayView = NSVisualEffectView(frame: .zero)
    private let captureToastView = NSVisualEffectView(frame: .zero)
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
    private let statusToolsHintLabel = NSTextField(labelWithString: "Tools: V P H C R T Q M K  |  Esc Esc: Select")
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
    private let toolSettingsToolLabel = NSTextField(labelWithString: "Active Tool: Pen")
    private let toolSettingsStrokeTitleLabel = NSTextField(labelWithString: "Color:")
    private let toolSettingsFillTitleLabel = NSTextField(labelWithString: "Fill:")
    private let toolSettingsStrokeColorWell = NSColorWell(frame: .zero)
    private let toolSettingsFillColorWell = NSColorWell(frame: .zero)
    private let toolSettingsLineWidthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let toolSettingsOpacitySlider = NSSlider(value: 0.8, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let toolSettingsOpacityValueLabel = NSTextField(labelWithString: "80%")
    private let toolSettingsFillRow = NSStackView(frame: .zero)
    private let toolSettingsWidthRow = NSStackView(frame: .zero)
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
    var markupItems: [MarkupItem] = []
    private var markupsTimer: Timer?
    private var scrollEventMonitor: Any?
    private var keyEventMonitor: Any?
    private var markupFilterText = ""
    private var pendingCalibrationDistanceInPoints: CGFloat?
    private var busyOperationDepth = 0
    private var markupChangeVersion = 0
    private var lastAutosavedChangeVersion = 0
    private var openDocumentURL: URL?
    private var sessionDocumentURLs: [URL] = []
    private var autosaveURL: URL?
    private var pendingAutosaveWorkItem: DispatchWorkItem?
    private var pendingMarkupsRefreshWorkItem: DispatchWorkItem?
    private var markupsScanGeneration = 0
    private var cachedMarkupDocumentID: ObjectIdentifier?
    private var pageMarkupCache: [Int: [MarkupItem]] = [:]
    private var dirtyMarkupPageIndexes: Set<Int> = []
    private let minimumIndexedMarkupItems = 5_000
    private let maximumIndexedMarkupItems = 200_000
    private var lastKnownTotalMatchingMarkups = 0
    private var isMarkupListTruncated = false
    private var watchdog: MainThreadWatchdog?
    private var autosaveInFlight = false
    private var autosaveQueued = false
    private var manualSaveInFlight = false
    private var lastAutosaveAt: Date = .distantPast
    private var lastMarkupEditAt: Date = .distantPast
    private var lastUserInteractionAt: Date = .distantPast
    private var lastEscapePressAt: Date = .distantPast
    private var saveProgressTimer: Timer?
    private var saveOperationStartedAt: CFAbsoluteTime?
    private var savePhase: String?
    private var saveGenerateElapsed: Double = 0
    private var isSavingDocumentOperation = false
    private var busyInteractionLocked = false
    private var captureToastHideWorkItem: DispatchWorkItem?
    private var grabClipboardImage: NSImage?
    private var grabClipboardPageRect: NSRect?
    private var sidebarCurrentPageIndex: Int = -1
    private var bookmarkLabelOverrides: [String: String] = [:]
    private var pageLabelOverrides: [Int: String] = [:]
    private var hasPromptedForInitialMarkupSaveCopy = false
    private var isPresentingInitialMarkupSaveCopyPrompt = false
    private var isGridVisible = false
    private var autoNameCapturePhase: AutoNameCapturePhase?
    private var autoNameReferencePageIndex: Int?
    private var pendingSheetNumberZone: NormalizedPageRect?
    private var pendingSheetTitleZone: NormalizedPageRect?
    private var autoNamePreviousToolMode: ToolMode?
    var onDocumentOpened: ((URL) -> Void)?
    private var sidebarContainerView: NSView?
    private var lastSidebarExpandedWidth: CGFloat = 240
    private var isSidebarCollapsed = false
    private let markupsSectionButton = NSButton(title: "", target: nil, action: nil)
    private let summarySectionButton = NSButton(title: "", target: nil, action: nil)
    private let markupsSectionContent = NSStackView(frame: .zero)
    private let summarySectionContent = NSStackView(frame: .zero)
    private let toolSelector: NSSegmentedControl = {
        let control = NSSegmentedControl(labels: ["Select", "Grab", "Draw", "Line", "Polyline", "Highlighter", "Cloud", "Rect", "Text", "Callout"], trackingMode: .selectOne, target: nil, action: nil)
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
    private let drawingScalePresets: [(label: String, drawingInches: Double, realFeet: Double)] = [
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
    private var sidebarPreferredWidthConstraint: NSLayoutConstraint?
    private var didApplyInitialSplitLayout = false

    override func loadView() {
        let rootDropView = StartupDropView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
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
        openButton.title = "Open"
        openButton.target = self
        openButton.action = #selector(openPDF)
        autoNameSheetsButton.target = self
        autoNameSheetsButton.action = #selector(commandAutoGenerateSheetNames(_:))
        emptyStateOpenButton.title = "Open Existing PDF"
        emptyStateOpenButton.target = self
        emptyStateOpenButton.action = #selector(openPDF)
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
            self?.updateStatusBar()
            self?.updateSelectionOverlay()
            self?.refreshRulers()
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
            self?.markMarkupChanged()
            self?.scheduleMarkupsRefresh(selecting: nil)
            self?.scheduleAutosave()
        }
        pdfView.onAnnotationMoved = { [weak self] page, annotation, startBounds in
            guard let self else { return }
            let before = AnnotationSnapshot(
                bounds: startBounds,
                contents: annotation.contents,
                color: annotation.color,
                interiorColor: annotation.interiorColor,
                fontColor: annotation.fontColor,
                lineWidth: resolvedLineWidth(for: annotation)
            )
            self.registerAnnotationStateUndo(annotation: annotation, previous: before, actionName: "Move Markup")
            self.markPageMarkupCacheDirty(page)
            self.markMarkupChanged()
            self.scheduleMarkupsRefresh(selecting: annotation)
            self.scheduleAutosave()
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
        pdfView.onSnapshotCaptured = { [weak self] image, pageRect in
            self?.grabClipboardImage = image
            self?.grabClipboardPageRect = pageRect
            self?.showCaptureToast("Captured - Shift+Command+V to paste")
        }
        pdfView.onRegionCaptured = { [weak self] page, rectInPage in
            self?.handleAutoNameRegionCaptured(on: page, rectInPage: rectInPage)
        }
        pdfView.layer?.addSublayer(selectedMarkupOverlayLayer)

        view.addSubview(splitView)
        view.addSubview(documentTabsBar)
        view.addSubview(statusBar)
        view.addSubview(busyOverlayView)
        view.addSubview(captureToastView)
        view.addSubview(collapsedSidebarRevealButton)
        configureDocumentTabsBar()
        configureBusyOverlay()
        configureCaptureToast()

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
        updateStatusBar()
        refreshRulers()
        updateEmptyStateVisibility()
        refreshDocumentTabs()
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
        pdfCanvasContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        bookmarksContainer.translatesAutoresizingMaskIntoConstraints = false

        pdfCanvasContainer.addSubview(bookmarksContainer)
        pdfCanvasContainer.addSubview(pdfView)

        let bookmarksWidth = bookmarksContainer.widthAnchor.constraint(equalToConstant: showNavigationPane ? 220 : 0)
        NSLayoutConstraint.activate([
            bookmarksContainer.topAnchor.constraint(equalTo: pdfCanvasContainer.topAnchor),
            bookmarksContainer.leadingAnchor.constraint(equalTo: pdfCanvasContainer.leadingAnchor),
            bookmarksContainer.bottomAnchor.constraint(equalTo: pdfCanvasContainer.bottomAnchor),
            bookmarksWidth,

            pdfView.topAnchor.constraint(equalTo: pdfCanvasContainer.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: bookmarksContainer.trailingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: pdfCanvasContainer.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: pdfCanvasContainer.bottomAnchor)
        ])
        bookmarksWidthConstraint = bookmarksWidth
    }

    private func configureBookmarksSidebar() {
        if !bookmarksContainer.subviews.isEmpty {
            return
        }

        bookmarksContainer.material = .windowBackground
        bookmarksContainer.blendingMode = .withinWindow
        bookmarksContainer.state = .active
        bookmarksContainer.wantsLayer = true
        bookmarksContainer.layer?.borderWidth = 1
        bookmarksContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        bookmarksContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        navigationTitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        navigationTitleLabel.textColor = .secondaryLabelColor
        navigationModeControl.selectedSegment = 1
        navigationModeControl.controlSize = .small
        navigationModeControl.target = self
        navigationModeControl.action = #selector(changeNavigationMode)

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
        pagesTableView.backgroundColor = .controlBackgroundColor
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
        bookmarksOutlineView.backgroundColor = .controlBackgroundColor
        bookmarksOutlineView.delegate = self
        bookmarksOutlineView.dataSource = self
        bookmarksOutlineView.target = self
        bookmarksOutlineView.action = #selector(selectBookmarkFromSidebar)
        bookmarksOutlineView.doubleAction = #selector(renameBookmarkFromSidebar)

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
            navigationModeControl,
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
        updateStatusBar()
        refreshRulers()
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
        updateStatusBar()
        refreshRulers()
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
        bookmarkLabelOverrides[bookmarkKey(for: outline)] = updated
        bookmarksOutlineView.reloadData()
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
        toolSettingsOpacityValueLabel.alignment = .right
        toolSettingsOpacityValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        toolSettingsOpacitySlider.target = self
        toolSettingsOpacitySlider.action = #selector(toolSettingsOpacityChanged)
        toolSettingsStrokeColorWell.target = self
        toolSettingsStrokeColorWell.action = #selector(toolSettingsChanged)
        toolSettingsFillColorWell.target = self
        toolSettingsFillColorWell.action = #selector(toolSettingsChanged)
        toolSettingsLineWidthPopup.target = self
        toolSettingsLineWidthPopup.action = #selector(toolSettingsChanged)

        measurementCountLabel.textColor = .secondaryLabelColor
        measurementTotalLabel.textColor = .secondaryLabelColor
        configureSectionButtons()
        updateToolSettingsUIForCurrentTool()
        applyToolSettingsToPDFView()
    }

    private func configureSectionButtons() {
        markupsSectionButton.target = self
        markupsSectionButton.action = #selector(toggleMarkupsSection)
        summarySectionButton.target = self
        summarySectionButton.action = #selector(toggleSummarySection)

        toolSettingsSectionButton.isBordered = false
        toolSettingsSectionButton.isEnabled = false
        toolSettingsSectionButton.alignment = .left
        toolSettingsSectionButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        toolSettingsSectionButton.contentTintColor = .secondaryLabelColor

        [markupsSectionButton, summarySectionButton].forEach {
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

    private func updateSectionHeaders() {
        toolSettingsSectionButton.title = "Tool Settings"
        markupsSectionButton.title = "\(markupsSectionContent.isHidden ? "▸" : "▾") Markups"
        summarySectionButton.title = "\(summarySectionContent.isHidden ? "▸" : "▾") Takeoff Summary"
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

        for item in menu.items {
            item.target = self
        }
        actionsPopup.menu = menu
    }

    private func configureStatusBar() {
        statusBar.material = .windowBackground
        statusBar.blendingMode = .withinWindow
        statusBar.state = .active
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

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
        busyOverlayView.material = .windowBackground
        busyOverlayView.blendingMode = .withinWindow
        busyOverlayView.state = .active
        busyOverlayView.wantsLayer = true
        busyOverlayView.layer?.cornerRadius = 10
        busyOverlayView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
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
        captureToastView.material = .windowBackground
        captureToastView.blendingMode = .withinWindow
        captureToastView.state = .active
        captureToastView.wantsLayer = true
        captureToastView.layer?.cornerRadius = 8
        captureToastView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
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

    private func beginBusyIndicator(_ message: String, detail: String? = nil, lockInteraction: Bool = true) {
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

    private func endBusyIndicator() {
        busyOperationDepth = max(0, busyOperationDepth - 1)
        guard busyOperationDepth == 0 else { return }
        view.window?.ignoresMouseEvents = false
        busyInteractionLocked = false
        busyProgressIndicator.stopAnimation(nil)
        busyOverlayView.isHidden = true
        busyDetailLabel.stringValue = ""
    }

    private func updateBusyIndicatorDetail(_ detail: String) {
        busyDetailLabel.stringValue = detail
        busyOverlayView.displayIfNeeded()
    }

    private func installScrollMonitorIfNeeded() {
        guard scrollEventMonitor == nil else { return }
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            guard self.view.window?.isKeyWindow == true else { return event }
            guard self.pdfView.document != nil else { return event }

            let point = self.pdfView.convert(event.locationInWindow, from: nil)
            guard self.pdfView.bounds.contains(point) else { return event }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.control) {
                // CAD-style fallback: hold Control and wheel to move page-by-page.
                if event.scrollingDeltaY > 0 {
                    self.commandPreviousPage(nil)
                } else if event.scrollingDeltaY < 0 {
                    self.commandNextPage(nil)
                }
                self.lastUserInteractionAt = Date()
                return nil
            }

            self.pdfView.handleWheelZoom(event)
            self.lastUserInteractionAt = Date()
            return nil
        }
    }

    private func installKeyMonitorIfNeeded() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.view.window?.isKeyWindow == true else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if modifiers == [.command],
               event.charactersIgnoringModifiers?.lowercased() == "a" {
                self.lastUserInteractionAt = Date()
                if self.view.window?.firstResponder is NSTextView || self.view.window?.firstResponder is NSTextField {
                    return event
                }
                self.commandSelectAll(nil)
                return nil
            }
            if event.keyCode == 48 {
                if modifiers == [.control] {
                    self.lastUserInteractionAt = Date()
                    self.commandCycleNextDocument(nil)
                    return nil
                }
                if modifiers == [.control, .shift] {
                    self.lastUserInteractionAt = Date()
                    self.commandCyclePreviousDocument(nil)
                    return nil
                }
            }
            if modifiers == [.command, .shift],
               event.charactersIgnoringModifiers?.lowercased() == "v" {
                self.lastUserInteractionAt = Date()
                self.pasteGrabSnapshotInPlace()
                return nil
            }
            if modifiers == [.command],
               event.charactersIgnoringModifiers?.lowercased() == "w" {
                self.lastUserInteractionAt = Date()
                self.commandCloseDocument(nil)
                return nil
            }

            if modifiers.isDisjoint(with: [.command, .option, .control]) {
                if self.view.window?.firstResponder is NSTextView || self.view.window?.firstResponder is NSTextField {
                    return event
                }
                switch event.keyCode {
                case 123, 126: // Left / Up
                    self.lastUserInteractionAt = Date()
                    self.commandPreviousPage(nil)
                    return nil
                case 124, 125: // Right / Down
                    self.lastUserInteractionAt = Date()
                    self.commandNextPage(nil)
                    return nil
                default:
                    break
                }
            }

            let forbidden: NSEvent.ModifierFlags = [.command, .option, .control]
            guard modifiers.isDisjoint(with: forbidden) else {
                return event
            }

            if event.keyCode == 51 || event.keyCode == 117 {
                self.lastUserInteractionAt = Date()
                if self.view.window?.firstResponder is NSTextView || self.view.window?.firstResponder is NSTextField {
                    return event
                }
                self.deleteSelectedMarkup()
                return nil
            }

            if self.view.window?.firstResponder is NSTextView || self.view.window?.firstResponder is NSTextField {
                return event
            }

            if event.keyCode == 53 {
                self.lastUserInteractionAt = Date()
                self.handleEscapePress()
                return nil
            }

            guard let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            switch key {
            case "v":
                self.lastUserInteractionAt = Date()
                self.setTool(.select)
                return nil
            case "g":
                self.lastUserInteractionAt = Date()
                self.setTool(.grab)
                return nil
            case "d":
                self.lastUserInteractionAt = Date()
                self.setTool(.pen)
                return nil
            case "l":
                self.lastUserInteractionAt = Date()
                self.setTool(.line)
                return nil
            case "p":
                self.lastUserInteractionAt = Date()
                self.setTool(.polyline)
                return nil
            case "h":
                self.lastUserInteractionAt = Date()
                self.setTool(.highlighter)
                return nil
            case "c":
                self.lastUserInteractionAt = Date()
                self.setTool(.cloud)
                return nil
            case "r":
                self.lastUserInteractionAt = Date()
                self.setTool(.rectangle)
                return nil
            case "t":
                self.lastUserInteractionAt = Date()
                self.setTool(.text)
                return nil
            case "q":
                self.lastUserInteractionAt = Date()
                self.setTool(.callout)
                return nil
            case "m":
                self.lastUserInteractionAt = Date()
                self.setTool(.measure)
                return nil
            case "a":
                self.lastUserInteractionAt = Date()
                self.setTool(.area)
                return nil
            case "k":
                self.lastUserInteractionAt = Date()
                self.setTool(.calibrate)
                return nil
            default:
                return event
            }
        }
    }

    private func handleEscapePress() {
        let now = Date()
        if now.timeIntervalSince(lastEscapePressAt) <= 0.65 {
            if pdfView.toolMode == .polyline {
                _ = pdfView.endPendingPolyline()
                setTool(.select)
                lastEscapePressAt = .distantPast
                return
            }
            if pdfView.toolMode == .area {
                _ = pdfView.endPendingArea()
                setTool(.select)
                lastEscapePressAt = .distantPast
                return
            }
            if pdfView.toolMode == .select {
                clearMarkupSelection()
            } else {
                setTool(.select)
            }
            lastEscapePressAt = .distantPast
        } else {
            lastEscapePressAt = now
        }
    }

    private func clearMarkupSelection() {
        markupsTable.deselectAll(nil)
        selectedMarkupOverlayLayer.isHidden = true
        updateToolSettingsUIForCurrentTool()
        updateStatusBar()
    }

    private func configureEmptyStateView() {
        emptyStateView.material = .windowBackground
        emptyStateView.blendingMode = .withinWindow
        emptyStateView.state = .active
        emptyStateView.wantsLayer = true
        emptyStateView.layer?.cornerRadius = 12
        emptyStateView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        emptyStateTitle.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        emptyStateOpenButton.bezelStyle = .texturedRounded
        emptyStateSampleButton.bezelStyle = .texturedRounded

        let actions = NSStackView(views: [emptyStateOpenButton, emptyStateSampleButton])
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
        collapsedSidebarRevealButton.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        collapsedSidebarRevealButton.setContentHuggingPriority(.required, for: .horizontal)
        collapsedSidebarRevealButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        collapsedSidebarRevealButton.isHidden = !isSidebarCollapsed
    }

    private func configureDocumentTabsBar() {
        documentTabsBar.material = .windowBackground
        documentTabsBar.blendingMode = .withinWindow
        documentTabsBar.state = .active
        documentTabsBar.wantsLayer = true
        documentTabsBar.layer?.borderWidth = 1
        documentTabsBar.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        documentTabsBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
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
        toolSelector.setLabel("L", forSegment: 3)
        toolSelector.setLabel("P", forSegment: 4)
        toolSelector.setLabel("H", forSegment: 5)
        toolSelector.setLabel("C", forSegment: 6)
        toolSelector.setLabel("R", forSegment: 7)
        toolSelector.setLabel("T", forSegment: 8)
        toolSelector.setLabel("Q", forSegment: 9)
        for idx in 0..<10 {
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
        toolSelector.setToolTip("Line (L)", forSegment: 3)
        toolSelector.setToolTip("Polyline (P)", forSegment: 4)
        toolSelector.setToolTip("Highlighter (H)", forSegment: 5)
        toolSelector.setToolTip("Cloud (C)", forSegment: 6)
        toolSelector.setToolTip("Rectangle (R)", forSegment: 7)
        toolSelector.setToolTip("Text (T)", forSegment: 8)
        toolSelector.setToolTip("Callout (Q)", forSegment: 9)
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
        takeoffSelector.setToolTip("Area (A)", forSegment: 0)
        takeoffSelector.setToolTip("Measure (M)", forSegment: 1)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.drawbridgePrimaryControls, .flexibleSpace, .space, .drawbridgeSecondaryControls]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.drawbridgePrimaryControls, .flexibleSpace, .space, .drawbridgeSecondaryControls]
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
        toolSettingsSectionContent.addArrangedSubview(toolSettingsWidthRow)
        toolSettingsSectionContent.addArrangedSubview(toolOpacityRow)

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

        let sidebar = NSStackView(views: [
            toolSettingsHeaderRow,
            toolSettingsSectionContent
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
        case 3: requestedMode = .line
        case 4: requestedMode = .polyline
        case 5: requestedMode = .highlighter
        case 6: requestedMode = .cloud
        case 7: requestedMode = .rectangle
        case 8: requestedMode = .text
        case 9: requestedMode = .callout
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
        if requestedMode != .area {
            pdfView.cancelPendingArea()
        }

        pdfView.toolMode = requestedMode
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

    private func setTool(_ mode: ToolMode) {
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
        case .line:
            toolSelector.selectedSegment = 3
            takeoffSelector.selectedSegment = -1
        case .polyline:
            toolSelector.selectedSegment = 4
            takeoffSelector.selectedSegment = -1
        case .highlighter:
            toolSelector.selectedSegment = 5
            takeoffSelector.selectedSegment = -1
        case .cloud:
            toolSelector.selectedSegment = 6
            takeoffSelector.selectedSegment = -1
        case .rectangle:
            toolSelector.selectedSegment = 7
            takeoffSelector.selectedSegment = -1
        case .text:
            toolSelector.selectedSegment = 8
            takeoffSelector.selectedSegment = -1
        case .callout:
            toolSelector.selectedSegment = 9
            takeoffSelector.selectedSegment = -1
        case .area:
            toolSelector.selectedSegment = -1
            takeoffSelector.selectedSegment = 0
            toolSettingsLineWidthPopup.selectItem(withTitle: "1")
            pdfView.areaLineWidth = widthValue(for: 1, tool: .area)
        case .measure:
            toolSelector.selectedSegment = -1
            takeoffSelector.selectedSegment = 1
        case .calibrate:
            toolSelector.selectedSegment = -1
            takeoffSelector.selectedSegment = -1
            pdfView.cancelPendingCallout()
            pdfView.cancelPendingPolyline()
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

    @objc private func toggleSidebar() {
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

    @objc private func openPDF() {
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

    @objc private func createNewPDFAction() {
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

    private func pasteGrabSnapshotInPlace() {
        guard let image = grabClipboardImage,
              let sourceRect = grabClipboardPageRect,
              let page = pdfView.currentPage else {
            NSSound.beep()
            return
        }

        guard let imageURL = persistGrabSnapshotImage(image) else {
            NSSound.beep()
            return
        }

        let annotation = ImageMarkupAnnotation(bounds: sourceRect, imageURL: imageURL)
        annotation.renderOpacity = 0.2
        annotation.renderTintColor = .systemRed
        annotation.renderTintStrength = 0.65
        page.addAnnotation(annotation)
        registerAnnotationPresenceUndo(page: page, annotation: annotation, shouldExist: false, actionName: "Paste Grab Snapshot")
        markPageMarkupCacheDirty(page)
        markMarkupChanged()
        performRefreshMarkups(selecting: annotation)
        scheduleAutosave()
    }

    private func persistGrabSnapshotImage(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let directory = root?
                .appendingPathComponent("Drawbridge", isDirectory: true)
                .appendingPathComponent("GrabSnapshots", isDirectory: true)
            guard let directory else { return nil }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("grab-\(UUID().uuidString).png")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
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

    @objc private func highlightSelection() {
        pdfView.addHighlightForCurrentSelection()
        refreshMarkups()
        scheduleAutosave()
    }

    @objc private func saveCopy() {
        saveDocumentAsCopy()
    }

    @objc private func saveDocument() {
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

    private func saveDocumentAsProject(document: PDFDocument) {
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

    private func sidecarURL(for sourcePDFURL: URL) -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            let fallback = sourcePDFURL.deletingPathExtension()
            return fallback.appendingPathExtension("drawbridge.json")
        }
        let dir = appSupport.appendingPathComponent("Drawbridge").appendingPathComponent("ProjectSnapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = Data(sourcePDFURL.standardizedFileURL.path.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        let filename = (key.isEmpty ? UUID().uuidString : key) + ".drawbridge.snapshot"
        return dir.appendingPathComponent(filename)
    }

    private func cleanupLegacyJSONArtifacts(for sourcePDFURL: URL) {
        let fm = FileManager.default
        let legacySidecar = sourcePDFURL.deletingPathExtension().appendingPathExtension("drawbridge.json")
        if fm.fileExists(atPath: legacySidecar.path) {
            try? fm.removeItem(at: legacySidecar)
        }

        guard let autosaveDir = autosaveDirectoryURL() else { return }
        let stem = sourcePDFURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "/", with: "-")
        let autosave = autosaveDir.appendingPathComponent("\(stem)-autosave.drawbridge.json")
        if fm.fileExists(atPath: autosave.path) {
            try? fm.removeItem(at: autosave)
        }
    }

    private func buildSidecarSnapshot(document: PDFDocument, sourcePDFURL: URL) -> SidecarSnapshot {
        var records: [SidecarAnnotationRecord] = []
        records.reserveCapacity(max(64, totalCachedAnnotationCount()))
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                let archivedData = (try? NSKeyedArchiver.archivedData(withRootObject: annotation, requiringSecureCoding: true))
                    ?? (try? NSKeyedArchiver.archivedData(withRootObject: annotation, requiringSecureCoding: false))
                guard let data = archivedData else {
                    continue
                }
                records.append(
                    SidecarAnnotationRecord(
                        pageIndex: pageIndex,
                        archivedAnnotation: data,
                        lineWidth: resolvedLineWidth(for: annotation)
                    )
                )
            }
        }
        return SidecarSnapshot(
            sourcePDFPath: sourcePDFURL.standardizedFileURL.path,
            pageCount: document.pageCount,
            annotations: records,
            savedAt: Date()
        )
    }

    private func applySidecarSnapshot(_ snapshot: SidecarSnapshot, to document: PDFDocument) {
        guard snapshot.pageCount == document.pageCount else { return }
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let existing = page.annotations
            for annotation in existing {
                page.removeAnnotation(annotation)
            }
        }
        for record in snapshot.annotations {
            guard record.pageIndex >= 0,
                  record.pageIndex < document.pageCount,
                  let page = document.page(at: record.pageIndex),
                  let annotation = decodeAnnotation(from: record.archivedAnnotation) else {
                continue
            }
            if let lineWidth = record.lineWidth, lineWidth > 0 {
                assignLineWidth(lineWidth, to: annotation)
            }
            page.addAnnotation(annotation)
        }
    }

    private func loadSidecarSnapshotIfAvailable(for sourcePDFURL: URL, document: PDFDocument) {
        let url = sidecarURL(for: sourcePDFURL)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return }

        // Apply snapshot only when it is at least as new as the PDF file on disk.
        if let pdfModifiedAt = try? sourcePDFURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           let snapshotModifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           snapshotModifiedAt < pdfModifiedAt {
            return
        }

        let plistDecoder = PropertyListDecoder()
        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        guard let snapshot = (try? plistDecoder.decode(SidecarSnapshot.self, from: data))
            ?? (try? jsonDecoder.decode(SidecarSnapshot.self, from: data)) else { return }
        guard snapshot.sourcePDFPath == sourcePDFURL.standardizedFileURL.path else { return }
        applySidecarSnapshot(snapshot, to: document)
    }

    private func persistProjectSnapshot(document: PDFDocument, for sourcePDFURL: URL, busyMessage: String) {
        pendingAutosaveWorkItem?.cancel()
        pendingAutosaveWorkItem = nil
        autosaveQueued = false
        manualSaveInFlight = true
        beginBusyIndicator(busyMessage, detail: "Packing markups…", lockInteraction: false)
        startSaveProgressTracking(phase: "Packing")
        let sidecar = sidecarURL(for: sourcePDFURL)
        let started = CFAbsoluteTimeGetCurrent()
        let snapshot = buildSidecarSnapshot(document: document, sourcePDFURL: sourcePDFURL)
        updateSaveProgressPhase("Writing")
        updateBusyIndicatorDetail("Writing project file…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let success: Bool
            if let data = try? encoder.encode(snapshot) {
                do {
                    try data.write(to: sidecar, options: .atomic)
                    success = true
                } catch {
                    success = false
                }
            } else {
                success = false
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - started

            DispatchQueue.main.async {
                guard let self else { return }
                defer {
                    self.stopSaveProgressTracking()
                    self.endBusyIndicator()
                    self.manualSaveInFlight = false
                    if self.autosaveQueued {
                        self.autosaveQueued = false
                        self.scheduleAutosave()
                    }
                }
                guard success else {
                    self.updateBusyIndicatorDetail(String(format: "Project save failed after %.2fs", elapsed))
                    let alert = NSAlert()
                    alert.messageText = "Failed to save project"
                    alert.informativeText = "Could not write \(sidecar.lastPathComponent)."
                    alert.alertStyle = .warning
                    alert.runModal()
                    return
                }
                self.updateBusyIndicatorDetail(String(format: "Saved project in %.2fs", elapsed))
                self.markupChangeVersion = 0
                self.lastAutosavedChangeVersion = 0
                self.lastMarkupEditAt = .distantPast
                self.lastUserInteractionAt = .distantPast
                self.view.window?.isDocumentEdited = false
                self.updateStatusBar()
            }
        }
    }

    private func persistDocument(to url: URL, adoptAsPrimaryDocument: Bool, busyMessage: String, document: PDFDocument? = nil) {
        guard let document = document ?? pdfView.document else {
            NSSound.beep()
            return
        }
        guard !manualSaveInFlight else {
            NSSound.beep()
            return
        }
        // Prevent expensive markup-list rebuild work from competing with save completion on main.
        pendingMarkupsRefreshWorkItem?.cancel()
        pendingMarkupsRefreshWorkItem = nil
        markupsScanGeneration += 1
        pendingAutosaveWorkItem?.cancel()
        pendingAutosaveWorkItem = nil
        autosaveQueued = false
        manualSaveInFlight = true
        isSavingDocumentOperation = true
        beginBusyIndicator(busyMessage, detail: "Generating PDF…", lockInteraction: false)
        startSaveProgressTracking(phase: "Generating")
        let targetURL = url
        let originDocumentURLForAdoption = openDocumentURL.map { canonicalDocumentURL($0) }
        let startedAt = CFAbsoluteTimeGetCurrent()
        let documentBox = PDFDocumentBox(document: document)
        let destinationAlreadyExists = FileManager.default.fileExists(atPath: targetURL.path)
        let destinationIsFileProvider = Self.isLikelyFileProviderURL(targetURL)
        let fallbackStagingURL = destinationAlreadyExists ? saveStagingFileURL(for: targetURL) : targetURL

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var success = false
            var errorDescription: String?
            var writeElapsed: Double = 0
            var commitElapsed: Double = 0

            if destinationIsFileProvider {
                // File-provider volumes (iCloud/CloudStorage/Drive) are often very slow when PDFKit writes directly.
                // Render locally first, then do a single commit to the destination path.
                let localStagingURL = Self.temporaryLocalSaveURL(for: targetURL)
                let stagedWriteStartedAt = CFAbsoluteTimeGetCurrent()
                success = Self.writePDFDocument(documentBox.document, to: localStagingURL)
                writeElapsed = CFAbsoluteTimeGetCurrent() - stagedWriteStartedAt

                if success {
                    Task { @MainActor [weak self] in
                        self?.saveGenerateElapsed = writeElapsed
                        self?.updateSaveProgressPhase("Committing")
                    }
                    let commitStartedAt = CFAbsoluteTimeGetCurrent()
                    do {
                        try Self.commitStagedSave(from: localStagingURL, to: targetURL)
                        success = true
                    } catch {
                        success = false
                        errorDescription = error.localizedDescription
                    }
                    commitElapsed = CFAbsoluteTimeGetCurrent() - commitStartedAt
                }

                if FileManager.default.fileExists(atPath: localStagingURL.path) {
                    try? FileManager.default.removeItem(at: localStagingURL)
                }
            } else if destinationAlreadyExists {
                // Fast path: overwrite directly to avoid expensive replace/copy on file-provider volumes.
                let directWriteStartedAt = CFAbsoluteTimeGetCurrent()
                success = Self.writePDFDocument(documentBox.document, to: targetURL)
                writeElapsed = CFAbsoluteTimeGetCurrent() - directWriteStartedAt

                if !success {
                    // Fallback path: stage + commit if direct overwrite fails.
                    Task { @MainActor [weak self] in
                        self?.updateSaveProgressPhase("Retrying")
                    }
                    let stagingURL = fallbackStagingURL
                    let stagedWriteStartedAt = CFAbsoluteTimeGetCurrent()
                    success = Self.writePDFDocument(documentBox.document, to: stagingURL)
                    writeElapsed = CFAbsoluteTimeGetCurrent() - stagedWriteStartedAt
                    if success {
                        Task { @MainActor [weak self] in
                            self?.saveGenerateElapsed = writeElapsed
                            self?.updateSaveProgressPhase("Committing")
                        }
                        let commitStartedAt = CFAbsoluteTimeGetCurrent()
                        do {
                            try Self.commitStagedSave(from: stagingURL, to: targetURL)
                            success = true
                        } catch {
                            success = false
                            errorDescription = error.localizedDescription
                        }
                        commitElapsed = CFAbsoluteTimeGetCurrent() - commitStartedAt
                    }
                    if FileManager.default.fileExists(atPath: stagingURL.path) {
                        try? FileManager.default.removeItem(at: stagingURL)
                    }
                }
            } else {
                let writeStartedAt = CFAbsoluteTimeGetCurrent()
                success = Self.writePDFDocument(documentBox.document, to: targetURL)
                writeElapsed = CFAbsoluteTimeGetCurrent() - writeStartedAt
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

            DispatchQueue.main.async {
                guard let self else { return }
                defer {
                    self.stopSaveProgressTracking()
                    self.endBusyIndicator()
                    self.isSavingDocumentOperation = false
                    self.manualSaveInFlight = false
                    if self.autosaveQueued {
                        self.autosaveQueued = false
                        self.scheduleAutosave()
                    }
                }

                self.saveGenerateElapsed = writeElapsed
                guard success else {
                    if writeElapsed > 0, commitElapsed > 0 {
                        self.updateBusyIndicatorDetail(
                            String(format: "Write %.2fs • Commit %.2fs • Failed", writeElapsed, commitElapsed)
                        )
                    } else {
                        self.updateBusyIndicatorDetail(String(format: "Failed after %.2fs", elapsed))
                    }
                    let alert = NSAlert()
                    alert.messageText = "Failed to save PDF"
                    if let errorDescription {
                        alert.informativeText = "The file could not be written to \(targetURL.path).\n\n\(errorDescription)"
                    } else {
                        alert.informativeText = "The file could not be written to \(targetURL.path)."
                    }
                    alert.alertStyle = .warning
                    alert.runModal()
                    return
                }

                self.updateBusyIndicatorDetail(
                    String(
                        format: "Write %.2fs • Commit %.2fs • Total %.2fs",
                        writeElapsed,
                        commitElapsed,
                        elapsed
                    )
                )
                print(
                    String(
                        format: "Drawbridge save completed in %.2fs (write %.2fs + commit %.2fs) (%@)",
                        elapsed,
                        writeElapsed,
                        commitElapsed,
                        targetURL.lastPathComponent
                    )
                )

                if adoptAsPrimaryDocument {
                    let newDocumentURL = self.canonicalDocumentURL(targetURL)
                    if let originDocumentURLForAdoption, originDocumentURLForAdoption != newDocumentURL {
                        self.sessionDocumentURLs.removeAll {
                            self.canonicalDocumentURL($0) == originDocumentURLForAdoption
                        }
                    }
                    self.openDocumentURL = newDocumentURL
                    self.registerSessionDocument(newDocumentURL)
                    self.configureAutosaveURL(for: newDocumentURL)
                    self.cleanupLegacyJSONArtifacts(for: newDocumentURL)
                    self.view.window?.title = "Drawbridge - \(newDocumentURL.lastPathComponent)"
                    self.onDocumentOpened?(newDocumentURL)
                }
                self.markupChangeVersion = 0
                self.lastAutosavedChangeVersion = 0
                self.lastMarkupEditAt = .distantPast
                self.lastUserInteractionAt = .distantPast
                self.view.window?.isDocumentEdited = false
                self.updateStatusBar()
                self.scheduleMarkupsRefresh(selecting: self.currentSelectedAnnotation())
            }
        }
    }

    private func saveStagingFileURL(for destinationURL: URL) -> URL {
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

    private nonisolated static func temporaryLocalSaveURL(for destinationURL: URL) -> URL {
        let stem = destinationURL.deletingPathExtension().lastPathComponent
        let safeStem = stem.replacingOccurrences(of: "/", with: "-")
        let filename = "\(safeStem)-drawbridge-local-save-\(UUID().uuidString).pdf"
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    private nonisolated static func isLikelyFileProviderURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path.lowercased()
        return path.contains("/library/cloudstorage/")
            || path.contains("/google drive/")
            || path.contains("/onedrive/")
            || path.contains("/dropbox/")
            || path.contains("/box/")
    }

    private nonisolated static func commitStagedSave(from stagingURL: URL, to destinationURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            _ = try fm.replaceItemAt(destinationURL, withItemAt: stagingURL, backupItemName: nil, options: [])
            return
        }
        do {
            try fm.moveItem(at: stagingURL, to: destinationURL)
        } catch {
            try fm.copyItem(at: stagingURL, to: destinationURL)
            try? fm.removeItem(at: stagingURL)
        }
    }

    private nonisolated static func writePDFDocument(_ document: PDFDocument, to url: URL) -> Bool {
        // `write(to:withOptions:)` is materially faster than `write(to:)` on large drawing sets.
        return document.write(to: url, withOptions: nil)
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

    private func startSaveProgressTracking(phase: String) {
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

    private func updateSaveProgressPhase(_ phase: String) {
        savePhase = phase
    }

    private func stopSaveProgressTracking() {
        saveProgressTimer?.invalidate()
        saveProgressTimer = nil
        saveOperationStartedAt = nil
        savePhase = nil
        saveGenerateElapsed = 0
    }

    @objc private func refreshMarkups() {
        pendingMarkupsRefreshWorkItem?.cancel()
        performRefreshMarkups(selecting: currentSelectedAnnotation(), forceImmediate: true)
    }

    private func performRefreshMarkups(selecting selectedAnnotation: PDFAnnotation?, forceImmediate: Bool = false) {
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
            updateStatusBar()
            refreshRulers()
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
        let chunkSize = forceImmediate ? max(32, pagesToRebuild.count) : (pagesToRebuild.count >= 120 ? 8 : 16)

        if !forceImmediate && !pagesToRebuild.isEmpty {
            markupsCountLabel.stringValue = "Updating…"
        }

        func finish() {
            guard generation == self.markupsScanGeneration else { return }
            let pageIndices = self.pageMarkupCache.keys.sorted()
            let indexCap = self.effectiveIndexCap(for: document)
            var collected: [MarkupItem] = []
            let totalCached = self.totalCachedAnnotationCount()
            collected.reserveCapacity(min(totalCached, indexCap))
            var totalMatching = 0
            for pageIndex in pageIndices {
                guard let pageItems = self.pageMarkupCache[pageIndex] else { continue }
                if filter.isEmpty {
                    totalMatching += pageItems.count
                    if collected.count < indexCap {
                        let room = indexCap - collected.count
                        if room >= pageItems.count {
                            collected.append(contentsOf: pageItems)
                        } else {
                            collected.append(contentsOf: pageItems.prefix(room))
                        }
                    }
                } else {
                    for item in pageItems {
                        let type = (item.annotation.type ?? "").lowercased()
                        let contents = (item.annotation.contents ?? "").lowercased()
                        if type.contains(filter) || contents.contains(filter) {
                            totalMatching += 1
                            if collected.count < indexCap {
                                collected.append(item)
                            }
                        }
                    }
                }
            }
            self.lastKnownTotalMatchingMarkups = totalMatching
            self.isMarkupListTruncated = (totalMatching > indexCap)
            self.markupItems = collected
            self.markupsTable.reloadData()
            if self.isMarkupListTruncated {
                self.markupsCountLabel.stringValue = "\(collected.count) of \(totalMatching) items (refine filter)"
            } else {
                self.markupsCountLabel.stringValue = "\(collected.count) items"
            }
            self.updateMeasurementSummary()
            self.restoreSelection(for: selectedAnnotation)
            self.updateSelectionOverlay()
            self.updateStatusBar()
            self.refreshRulers()
            self.persistMarkupIndexSnapshot(document: document)
        }

        guard !pagesToRebuild.isEmpty else {
            finish()
            return
        }

        func rebuildChunk(from startIndex: Int) {
            guard generation == self.markupsScanGeneration else { return }
            let endIndex = min(startIndex + chunkSize, pagesToRebuild.count)
            if startIndex < endIndex {
                for idx in startIndex..<endIndex {
                    let pageIndex = pagesToRebuild[idx]
                    guard let page = document.page(at: pageIndex) else {
                        self.pageMarkupCache.removeValue(forKey: pageIndex)
                        self.dirtyMarkupPageIndexes.remove(pageIndex)
                        continue
                    }
                    let items = page.annotations.map { MarkupItem(pageIndex: pageIndex, annotation: $0) }
                    self.pageMarkupCache[pageIndex] = items
                    self.dirtyMarkupPageIndexes.remove(pageIndex)
                }
            }
            if endIndex < pagesToRebuild.count {
                DispatchQueue.main.async {
                    rebuildChunk(from: endIndex)
                }
                return
            }
            finish()
        }

        rebuildChunk(from: 0)
    }

    private func ensureMarkupCacheDocumentIdentity(for document: PDFDocument) {
        let id = ObjectIdentifier(document)
        guard cachedMarkupDocumentID != id else { return }
        cachedMarkupDocumentID = id
        pageMarkupCache.removeAll(keepingCapacity: false)
        dirtyMarkupPageIndexes = Set(0..<document.pageCount)
    }

    private func clearMarkupCache() {
        cachedMarkupDocumentID = nil
        pageMarkupCache.removeAll(keepingCapacity: false)
        dirtyMarkupPageIndexes.removeAll(keepingCapacity: false)
        lastKnownTotalMatchingMarkups = 0
        isMarkupListTruncated = false
        markupsScanGeneration += 1
    }

    private func markPageMarkupCacheDirty(_ page: PDFPage?) {
        guard let page, let document = pdfView.document else { return }
        ensureMarkupCacheDocumentIdentity(for: document)
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return }
        dirtyMarkupPageIndexes.insert(pageIndex)
    }

    private func totalCachedAnnotationCount() -> Int {
        pageMarkupCache.values.reduce(0) { $0 + $1.count }
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

    private func configuredIndexCap() -> Int {
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

    private func configureWatchdogFromDefaults() {
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

    private func scheduleMarkupsRefresh(selecting selectedAnnotation: PDFAnnotation?) {
        pendingMarkupsRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performRefreshMarkups(selecting: selectedAnnotation)
        }
        pendingMarkupsRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    private func markMarkupChanged() {
        promptInitialMarkupSaveCopyIfNeeded()
        markupChangeVersion += 1
        lastMarkupEditAt = Date()
        lastUserInteractionAt = Date()
        view.window?.isDocumentEdited = true
    }

    private func promptInitialMarkupSaveCopyIfNeeded() {
        guard !hasPromptedForInitialMarkupSaveCopy,
              !isPresentingInitialMarkupSaveCopyPrompt,
              !manualSaveInFlight,
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

    private func suggestedMarkupCopyFilename(for sourceURL: URL) -> String {
        let datePrefix = Self.markupCopyDateFormatter.string(from: Date())
        return "\(datePrefix) - markups \(sourceURL.lastPathComponent)"
    }

    private func promptForInitialMarkupWorkingCopy(from sourceURL: URL) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
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

    @objc private func deleteSelectedMarkup() {
        let selectedRows = markupsTable.selectedRowIndexes
        guard !selectedRows.isEmpty else {
            NSSound.beep()
            return
        }

        var annotationsToDelete: [(page: PDFPage, annotation: PDFAnnotation)] = []
        var seen = Set<ObjectIdentifier>()

        for row in selectedRows.sorted(by: >) {
            guard row >= 0, row < markupItems.count else { continue }
            let item = markupItems[row]
            guard let page = pdfView.document?.page(at: item.pageIndex) else { continue }

            let primaryID = ObjectIdentifier(item.annotation)
            if seen.insert(primaryID).inserted {
                annotationsToDelete.append((page: page, annotation: item.annotation))
            }

            for sibling in relatedCalloutAnnotations(for: item.annotation, on: page) where sibling !== item.annotation {
                let siblingID = ObjectIdentifier(sibling)
                if seen.insert(siblingID).inserted {
                    annotationsToDelete.append((page: page, annotation: sibling))
                }
            }
        }

        for entry in annotationsToDelete {
            registerAnnotationPresenceUndo(page: entry.page, annotation: entry.annotation, shouldExist: true, actionName: "Delete Markup")
            entry.page.removeAnnotation(entry.annotation)
            markPageMarkupCacheDirty(entry.page)
        }
        markMarkupChanged()
        performRefreshMarkups(selecting: nil, forceImmediate: true)
        scheduleAutosave()
    }

    @objc private func editSelectedMarkupText() {
        let row = markupsTable.selectedRow
        guard row >= 0, row < markupItems.count else {
            NSSound.beep()
            return
        }

        let item = markupItems[row]
        let alert = NSAlert()
        alert.messageText = "Edit Markup Text"
        alert.informativeText = "Update contents for this markup."
        alert.alertStyle = .informational

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = item.annotation.contents ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let before = snapshot(for: item.annotation)
        item.annotation.contents = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        markPageMarkupCacheDirty(item.annotation.page)
        registerAnnotationStateUndo(annotation: item.annotation, previous: before, actionName: "Edit Markup Text")
        markMarkupChanged()
        performRefreshMarkups(selecting: item.annotation)
        scheduleAutosave()
    }

    @objc private func selectMarkupFromTable() {
        jumpToSelectedMarkup()
        updateSelectionOverlay()
        updateToolSettingsUIForCurrentTool()
    }

    @objc private func toolSettingsOpacityChanged() {
        let opacityPercent = Int(round(toolSettingsOpacitySlider.doubleValue * 100))
        toolSettingsOpacityValueLabel.stringValue = "\(opacityPercent)%"
        applyToolSettingsToPDFView()
    }

    @objc private func toolSettingsChanged() {
        applyToolSettingsToPDFView()
    }

    @objc private func applyMeasurementScale() {
        let scale = max(0.0001, CGFloat(measurementScaleField.doubleValue > 0 ? measurementScaleField.doubleValue : 1.0))
        let unit = measurementUnitPopup.titleOfSelectedItem ?? "pt"
        let baseUnitsPerPoint = baseUnitsPerPoint(for: unit)

        pdfView.measurementUnitsPerPoint = baseUnitsPerPoint * scale
        pdfView.measurementUnitLabel = unit
        synchronizeScalePresetSelection()
        updateMeasurementSummary()
        updateStatusBar()
    }

    @objc private func changeScalePreset() {
        let idx = max(0, scalePresetPopup.indexOfSelectedItem)
        let preset = drawingScalePresets[min(idx, drawingScalePresets.count - 1)]
        if preset.drawingInches < 0 {
            commandSetDrawingScale(nil)
            return
        }
        if preset.drawingInches == 0 || preset.realFeet == 0 {
            measurementUnitPopup.selectItem(withTitle: "ft")
            measurementScaleField.stringValue = "1.000000"
            applyMeasurementScale()
            return
        }
        guard preset.drawingInches > 0, preset.realFeet > 0 else {
            return
        }
        applyDrawingScale(drawingInches: preset.drawingInches, realFeet: preset.realFeet)
    }

    private func applyDrawingScale(drawingInches: Double, realFeet: Double) {
        let points = CGFloat(drawingInches * 72.0)
        guard points > 0, realFeet > 0 else { return }
        let unitsPerPoint = CGFloat(realFeet) / points
        let base = baseUnitsPerPoint(for: "ft")
        let scale = unitsPerPoint / base
        measurementUnitPopup.selectItem(withTitle: "ft")
        measurementScaleField.stringValue = String(format: "%.6f", scale)
        applyMeasurementScale()
    }

    @objc func commandSetDrawingScale(_ sender: Any?) {
        guard pdfView.document != nil else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Set Drawing Scale"
        alert.informativeText = "Architectural scale format. Example: 1/8\" = 1'-0\"."
        alert.alertStyle = .informational

        let drawingField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        drawingField.placeholderString = "1/8"
        drawingField.stringValue = "1/8"
        drawingField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        drawingField.alignment = .right
        drawingField.translatesAutoresizingMaskIntoConstraints = false
        drawingField.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let realFeetField = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        realFeetField.stringValue = "1"
        realFeetField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        realFeetField.alignment = .right
        realFeetField.translatesAutoresizingMaskIntoConstraints = false
        realFeetField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let realInchesField = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        realInchesField.stringValue = "0"
        realInchesField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        realInchesField.alignment = .right
        realInchesField.translatesAutoresizingMaskIntoConstraints = false
        realInchesField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let drawingLabel = NSTextField(labelWithString: "Drawing")
        drawingLabel.alignment = .right
        drawingLabel.setContentHuggingPriority(.required, for: .horizontal)
        let realLabel = NSTextField(labelWithString: "Real")
        realLabel.alignment = .right
        realLabel.setContentHuggingPriority(.required, for: .horizontal)

        let drawingInput = NSStackView(views: [drawingField, NSTextField(labelWithString: "\"")])
        drawingInput.orientation = .horizontal
        drawingInput.spacing = 6
        drawingInput.alignment = .centerY

        let realInput = NSStackView(views: [realFeetField, NSTextField(labelWithString: "ft"), realInchesField, NSTextField(labelWithString: "in")])
        realInput.orientation = .horizontal
        realInput.spacing = 6
        realInput.alignment = .centerY

        let grid = NSGridView(views: [
            [drawingLabel, drawingInput],
            [realLabel, realInput]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.xPlacement = .fill
        grid.yPlacement = .center
        grid.column(at: 0).xPlacement = .trailing

        let helperLabel = NSTextField(labelWithString: "Supported drawing values: decimal, fraction, or mixed (e.g. 0.125, 1/8, 1 1/2).")
        helperLabel.textColor = .secondaryLabelColor
        helperLabel.font = NSFont.systemFont(ofSize: 11)
        helperLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [grid, helperLabel])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 112))
        accessory.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: accessory.topAnchor),
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
        ])
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Apply Scale")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let drawingInches = parseArchitecturalInches(drawingField.stringValue),
              drawingInches > 0 else {
            NSSound.beep()
            return
        }
        let feet = max(0, realFeetField.doubleValue)
        let inches = max(0, realInchesField.doubleValue)
        let realFeet = feet + (inches / 12.0)
        guard realFeet > 0 else {
            NSSound.beep()
            return
        }

        applyDrawingScale(drawingInches: drawingInches, realFeet: realFeet)
        scalePresetPopup.selectItem(withTitle: "Custom…")
    }

    private func synchronizeScalePresetSelection() {
        let unit = measurementUnitPopup.titleOfSelectedItem ?? "pt"
        guard unit == "ft" else {
            scalePresetPopup.selectItem(withTitle: "Custom…")
            return
        }

        let scale = max(0.0001, measurementScaleField.doubleValue > 0 ? measurementScaleField.doubleValue : 1.0)
        let tolerance = 0.000001
        for preset in drawingScalePresets where preset.drawingInches > 0 && preset.realFeet > 0 {
            let expectedScale = preset.realFeet / (preset.drawingInches * 72.0) / Double(baseUnitsPerPoint(for: "ft"))
            if abs(expectedScale - scale) <= tolerance {
                scalePresetPopup.selectItem(withTitle: preset.label)
                return
            }
        }
        scalePresetPopup.selectItem(withTitle: "Custom…")
    }

    private func parseArchitecturalInches(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let decimal = Double(value) {
            return decimal
        }

        let parts = value.split(separator: " ")
        if parts.count == 2,
           let whole = Double(parts[0]),
           let fraction = parseFraction(parts[1]) {
            return whole + fraction
        }

        return parseFraction(Substring(value))
    }

    private func parseFraction(_ fraction: Substring) -> Double? {
        let items = fraction.split(separator: "/")
        guard items.count == 2,
              let numerator = Double(items[0]),
              let denominator = Double(items[1]),
              denominator != 0 else { return nil }
        return numerator / denominator
    }

    @objc private func exportMarkupsCSV() {
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

    @objc func commandOpen(_ sender: Any?) { openPDF() }
    @objc func commandNew(_ sender: Any?) { createNewPDFAction() }
    @objc func commandSave(_ sender: Any?) { saveDocument() }
    @objc func commandSaveCopy(_ sender: Any?) { saveCopy() }
    @objc func commandExportCSV(_ sender: Any?) { exportMarkupsCSV() }
    @objc func commandAutoGenerateSheetNames(_ sender: Any?) { startAutoGenerateSheetNamesFlow() }
    @objc func commandSetScale(_ sender: Any?) { commandSetDrawingScale(sender) }
    @objc func commandPerformanceSettings(_ sender: Any?) {
        let defaults = UserDefaults.standard
        let adaptiveDefault = defaults.bool(forKey: Self.defaultsAdaptiveIndexCapEnabledKey)
        let capDefault = configuredIndexCap()
        let watchdogDefault = defaults.bool(forKey: Self.defaultsWatchdogEnabledKey)
        let thresholdDefault = max(0.5, defaults.double(forKey: Self.defaultsWatchdogThresholdSecondsKey))

        let adaptiveButton = NSButton(checkboxWithTitle: "Adaptive index cap for very large PDFs", target: nil, action: nil)
        adaptiveButton.state = adaptiveDefault ? .on : .off

        let capLabel = NSTextField(labelWithString: "Max indexed markups:")
        let capField = NSTextField(string: "\(capDefault)")
        capField.alignment = .right
        capField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        capField.translatesAutoresizingMaskIntoConstraints = false
        capField.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let watchdogButton = NSButton(checkboxWithTitle: "Enable main-thread stall watchdog logging", target: nil, action: nil)
        watchdogButton.state = watchdogDefault ? .on : .off

        let thresholdLabel = NSTextField(labelWithString: "Stall threshold (seconds):")
        let thresholdField = NSTextField(string: String(format: "%.1f", thresholdDefault))
        thresholdField.alignment = .right
        thresholdField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        thresholdField.translatesAutoresizingMaskIntoConstraints = false
        thresholdField.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let capRow = NSStackView(views: [capLabel, capField])
        capRow.orientation = .horizontal
        capRow.spacing = 10
        capRow.alignment = .centerY
        capLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        capRow.distribution = .fill
        let thresholdRow = NSStackView(views: [thresholdLabel, thresholdField])
        thresholdRow.orientation = .horizontal
        thresholdRow.spacing = 10
        thresholdRow.alignment = .centerY
        thresholdLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        thresholdRow.distribution = .fill

        let help = NSTextField(labelWithString: "Watchdog logs: ~/Library/Application Support/Drawbridge/Logs/watchdog.log")
        help.textColor = .secondaryLabelColor
        help.font = NSFont.systemFont(ofSize: 11)
        help.lineBreakMode = .byWordWrapping
        help.maximumNumberOfLines = 2

        let stack = NSStackView(views: [adaptiveButton, capRow, watchdogButton, thresholdRow, help])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 160))
        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(stack)
        NSLayoutConstraint.activate([
            accessory.widthAnchor.constraint(equalToConstant: 520),
            stack.topAnchor.constraint(equalTo: accessory.topAnchor),
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
        ])

        let alert = NSAlert()
        alert.messageText = "Performance Settings"
        alert.informativeText = "Tune large-document indexing and watchdog behavior."
        alert.alertStyle = .informational
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let cap = min(max(capField.integerValue, minimumIndexedMarkupItems), maximumIndexedMarkupItems)
        let threshold = min(max(thresholdField.doubleValue, 0.5), 30.0)
        defaults.set(adaptiveButton.state == .on, forKey: Self.defaultsAdaptiveIndexCapEnabledKey)
        defaults.set(cap, forKey: Self.defaultsIndexCapKey)
        defaults.set(watchdogButton.state == .on, forKey: Self.defaultsWatchdogEnabledKey)
        defaults.set(threshold, forKey: Self.defaultsWatchdogThresholdSecondsKey)
        configureWatchdogFromDefaults()
        scheduleMarkupsRefresh(selecting: currentSelectedAnnotation())
    }
    @objc func commandCycleNextDocument(_ sender: Any?) {
        cycleDocument(step: 1)
    }
    @objc func commandCyclePreviousDocument(_ sender: Any?) {
        cycleDocument(step: -1)
    }
    @objc func commandCloseDocument(_ sender: Any?) {
        guard confirmDiscardUnsavedChangesIfNeeded() else {
            return
        }

        if let current = openDocumentURL.map({ canonicalDocumentURL($0) }) {
            sessionDocumentURLs.removeAll { canonicalDocumentURL($0) == current }
        }

        while let fallback = sessionDocumentURLs.last {
            guard FileManager.default.fileExists(atPath: fallback.path) else {
                sessionDocumentURLs.removeLast()
                continue
            }
            openDocument(at: fallback)
            return
        }

        clearToStartState()
    }

    private func cycleDocument(step: Int) {
        guard sessionDocumentURLs.count > 1 else {
            NSSound.beep()
            return
        }

        guard confirmDiscardUnsavedChangesIfNeeded() else {
            return
        }

        let normalizedCurrent = openDocumentURL.map { canonicalDocumentURL($0) }
        let currentIndex = normalizedCurrent.flatMap { current in
            sessionDocumentURLs.firstIndex(where: { canonicalDocumentURL($0) == current })
        } ?? (sessionDocumentURLs.count - 1)

        let count = sessionDocumentURLs.count
        let rawNext = (currentIndex + step) % count
        let nextIndex = rawNext < 0 ? rawNext + count : rawNext
        let nextURL = sessionDocumentURLs[nextIndex]
        openDocument(at: nextURL)
    }
    @objc func commandHighlight(_ sender: Any?) { highlightSelection() }
    @objc func commandRefreshMarkups(_ sender: Any?) { refreshMarkups() }
    @objc func commandDeleteMarkup(_ sender: Any?) { deleteSelectedMarkup() }
    @objc func commandSelectAll(_ sender: Any?) {
        guard let document = pdfView.document, let page = pdfView.currentPage else {
            NSSound.beep()
            return
        }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else {
            NSSound.beep()
            return
        }
        let rows = IndexSet(markupItems.enumerated().compactMap { idx, item in
            item.pageIndex == pageIndex ? idx : nil
        })
        guard !rows.isEmpty else {
            markupsTable.deselectAll(nil)
            updateSelectionOverlay()
            return
        }
        markupsTable.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first {
            markupsTable.scrollRowToVisible(first)
        }
        updateSelectionOverlay()
        updateStatusBar()
    }
    @objc func commandEditMarkup(_ sender: Any?) { editSelectedMarkupText() }
    @objc func commandToggleSidebar(_ sender: Any?) { toggleSidebar() }
    @objc func commandQuickStart(_ sender: Any?) { showQuickStartGuide() }
    @objc func commandZoomIn(_ sender: Any?) { zoom(by: 1.12) }
    @objc func commandZoomOut(_ sender: Any?) { zoom(by: 1.0 / 1.12) }
    @objc func commandPreviousPage(_ sender: Any?) { navigatePage(delta: -1) }
    @objc func commandNextPage(_ sender: Any?) { navigatePage(delta: 1) }
    @objc func commandActualSize(_ sender: Any?) {
        guard pdfView.document != nil else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = 1.0
        updateStatusBar()
    }
    @objc func commandFitWidth(_ sender: Any?) {
        guard pdfView.document != nil else { return }
        pdfView.autoScales = true
        let fit = pdfView.scaleFactorForSizeToFit
        if fit > 0 {
            pdfView.scaleFactor = fit
            pdfView.autoScales = false
        }
        updateStatusBar()
    }

    func openDocumentFromExternalURL(_ url: URL) {
        guard confirmDiscardUnsavedChangesIfNeeded() else {
            return
        }
        openDocument(at: url)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let action = menuItem.action
        let hasDocument = (pdfView.document != nil)
        let hasSelection = (currentSelectedMarkupItem() != nil)
        let hasTextSelection = (pdfView.currentSelection != nil)

        if action == #selector(commandOpen(_:)) {
            return true
        }
        if action == #selector(commandNew(_:)) {
            return true
        }
        if action == #selector(commandCycleNextDocument(_:)) || action == #selector(commandCyclePreviousDocument(_:)) {
            return sessionDocumentURLs.count > 1
        }
        if action == #selector(commandCloseDocument(_:)) {
            return pdfView.document != nil || !sessionDocumentURLs.isEmpty
        }
        if action == #selector(commandSave(_:)) || action == #selector(commandSaveCopy(_:)) || action == #selector(commandExportCSV(_:)) {
            return hasDocument
        }
        if action == #selector(commandAutoGenerateSheetNames(_:)) {
            return hasDocument
        }
        if action == #selector(commandSetScale(_:)) {
            return hasDocument
        }
        if action == #selector(commandPerformanceSettings(_:)) {
            return true
        }
        if action == #selector(commandHighlight(_:)) {
            return hasTextSelection
        }
        if action == #selector(commandRefreshMarkups(_:)) {
            return hasDocument
        }
        if action == #selector(commandDeleteMarkup(_:)) || action == #selector(commandEditMarkup(_:)) {
            return hasSelection
        }
        if action == #selector(commandSelectAll(_:)) {
            return hasDocument
        }
        if action == #selector(selectSelectionTool(_:)) ||
            action == #selector(selectGrabTool(_:)) ||
            action == #selector(selectPenTool(_:)) ||
            action == #selector(selectHighlighterTool(_:)) ||
            action == #selector(selectCloudTool(_:)) ||
            action == #selector(selectRectangleTool(_:)) ||
            action == #selector(selectTextTool(_:)) ||
            action == #selector(selectCalloutTool(_:)) ||
            action == #selector(selectMeasureTool(_:)) ||
            action == #selector(selectCalibrateTool(_:)) {
            return hasDocument
        }
        if action == #selector(commandZoomIn(_:)) ||
            action == #selector(commandZoomOut(_:)) ||
            action == #selector(commandPreviousPage(_:)) ||
            action == #selector(commandNextPage(_:)) ||
            action == #selector(commandActualSize(_:)) ||
            action == #selector(commandFitWidth(_:)) {
            return hasDocument
        }
        return true
    }

    private func showQuickStartGuide() {
        let alert = NSAlert()
        alert.messageText = "Drawbridge Quick Start"
        alert.informativeText = "Open a PDF, choose a tool, and place markups directly on the page."
        alert.alertStyle = .informational

        let guide = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 210))
        guide.isEditable = false
        guide.drawsBackground = false
        guide.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        guide.string = """
1) Open PDF: ⌘O
2) Tools (keyboard shortcuts): V Select, D Draw, L Line, P Polyline, A Area, H Highlighter, C Cloud, R Rect, T Text, Q Callout, M Measure, K Calibrate
   Mac menu keys: ⌘1 Pen, ⌘2 Highlighter, ⌘3 Cloud, ⌘4 Rect, ⌘5 Text, ⌘6 Callout
3) Navigation:
   • Mouse wheel = zoom in/out
   • Middle mouse drag = pan
   • Single-page view only (no continuous scroll)
   • Page nav: use the left navigation pane (Pages/Bookmarks)
4) Markups:
   • Select text then Highlight
   • Use right panel to edit, filter, delete
5) Export:
   • Export CSV from Actions or File menu
6) System Requirements:
   • Apple Silicon Mac (M1/M2/M3/M4)
   • macOS 13.0 or newer
"""
        alert.accessoryView = guide
        alert.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func zoom(by factor: CGFloat) {
        guard pdfView.document != nil else { return }
        lastUserInteractionAt = Date()
        pdfView.autoScales = false
        let target = min(max(pdfView.minScaleFactor, pdfView.scaleFactor * factor), pdfView.maxScaleFactor)
        pdfView.scaleFactor = target
        updateStatusBar()
    }

    @objc private func jumpToPageFromField() {
        defer {
            view.window?.makeFirstResponder(pdfView)
        }
        guard let document = pdfView.document else { return }
        let requested = pageJumpField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return }

        for idx in 0..<document.pageCount {
            if displayPageLabel(forPageIndex: idx).lowercased() == requested.lowercased() {
                goToPageIndex(idx)
                return
            }
        }

        if let pageNumber = Int(requested) {
            goToPageIndex(pageNumber - 1)
            return
        }
        NSSound.beep()
    }

    private func navigatePage(delta: Int) {
        guard let document = pdfView.document else { return }
        let current = pdfView.currentPage.map { document.index(for: $0) } ?? 0
        goToPageIndex(current + delta)
    }

    private func goToPageIndex(_ index: Int) {
        guard let document = pdfView.document else { return }
        let clamped = min(max(0, index), max(0, document.pageCount - 1))
        guard let page = document.page(at: clamped) else { return }
        let destination = PDFDestination(page: page, at: NSPoint(x: page.bounds(for: .cropBox).midX, y: page.bounds(for: .cropBox).midY))
        pdfView.go(to: destination)
        updateStatusBar()
    }

    private func activeUndoManager() -> UndoManager? {
        view.window?.undoManager ?? undoManager
    }

    private func snapshot(for annotation: PDFAnnotation) -> AnnotationSnapshot {
        AnnotationSnapshot(
            bounds: annotation.bounds,
            contents: annotation.contents,
            color: annotation.color,
            interiorColor: annotation.interiorColor,
            fontColor: annotation.fontColor,
            lineWidth: resolvedLineWidth(for: annotation)
        )
    }

    private func apply(snapshot: AnnotationSnapshot, to annotation: PDFAnnotation) {
        annotation.bounds = snapshot.bounds
        annotation.contents = snapshot.contents
        annotation.color = snapshot.color
        annotation.interiorColor = snapshot.interiorColor
        annotation.fontColor = snapshot.fontColor
        assignLineWidth(snapshot.lineWidth, to: annotation)
    }

    private func resolvedLineWidth(for annotation: PDFAnnotation) -> CGFloat {
        let annotationType = (annotation.type ?? "").lowercased()
        if annotationType.contains("ink"),
           let paths = annotation.paths,
           let maxPathWidth = paths.map(\.lineWidth).max(),
           maxPathWidth > 0 {
            return maxPathWidth
        }
        if let borderWidth = annotation.border?.lineWidth, borderWidth > 0 {
            return borderWidth
        }
        return 1.0
    }

    private func assignLineWidth(_ lineWidth: CGFloat, to annotation: PDFAnnotation) {
        let normalized = max(0.1, lineWidth)
        let border = annotation.border ?? PDFBorder()
        border.lineWidth = normalized
        annotation.border = border
        let annotationType = (annotation.type ?? "").lowercased()
        if annotationType.contains("ink"),
           let paths = annotation.paths {
            for path in paths {
                path.lineWidth = normalized
            }
        }
    }

    private func registerAnnotationStateUndo(annotation: PDFAnnotation, previous: AnnotationSnapshot, actionName: String) {
        guard let undo = activeUndoManager() else { return }
        undo.registerUndo(withTarget: self) { target in
            let current = target.snapshot(for: annotation)
            target.apply(snapshot: previous, to: annotation)
            target.markPageMarkupCacheDirty(annotation.page)
            target.markMarkupChanged()
            target.performRefreshMarkups(selecting: annotation)
            target.scheduleAutosave()
            target.registerAnnotationStateUndo(annotation: annotation, previous: current, actionName: actionName)
        }
        undo.setActionName(actionName)
    }

    private func registerAnnotationPresenceUndo(page: PDFPage, annotation: PDFAnnotation, shouldExist: Bool, actionName: String) {
        guard let undo = activeUndoManager() else { return }
        undo.registerUndo(withTarget: self) { target in
            if shouldExist {
                page.addAnnotation(annotation)
            } else {
                page.removeAnnotation(annotation)
            }
            target.markPageMarkupCacheDirty(page)
            target.markMarkupChanged()
            target.performRefreshMarkups(selecting: shouldExist ? annotation : nil)
            target.scheduleAutosave()
            target.registerAnnotationPresenceUndo(page: page, annotation: annotation, shouldExist: !shouldExist, actionName: actionName)
        }
        undo.setActionName(actionName)
    }


    private func openDocument(at url: URL) {
        cancelAutoNameCapture()
        beginBusyIndicator("Loading PDF…")
        defer { endBusyIndicator() }
        guard let document = PDFDocument(url: url) else {
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
        rehydrateImageAnnotationsIfNeeded(in: document)
        loadSidecarSnapshotIfAvailable(for: url, document: document)
        repairInkPathLineWidthsIfNeeded(in: document)
        openDocumentURL = url
        registerSessionDocument(url)
        configureAutosaveURL(for: url)
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
        refreshRulers()
        onDocumentOpened?(url)
        DispatchQueue.main.async { [weak self] in
            self?.profileOpenedDocumentAndWarn(document: document, sourceURL: url)
        }
    }

    private func rehydrateImageAnnotationsIfNeeded(in document: PDFDocument) {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let existing = page.annotations
            for annotation in existing {
                guard !(annotation is ImageMarkupAnnotation),
                      let contents = annotation.contents,
                      contents.hasPrefix(ImageMarkupAnnotation.contentsPrefix) else { continue }
                let replacement = ImageMarkupAnnotation(bounds: annotation.bounds, imageURL: URL(fileURLWithPath: String(contents.dropFirst(ImageMarkupAnnotation.contentsPrefix.count))), contents: contents)
                replacement.border = annotation.border
                replacement.color = annotation.color
                replacement.shouldDisplay = annotation.shouldDisplay
                replacement.shouldPrint = annotation.shouldPrint
                page.removeAnnotation(annotation)
                page.addAnnotation(replacement)
            }
        }
    }

    private func repairInkPathLineWidthsIfNeeded(in document: PDFDocument) {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                let annotationType = (annotation.type ?? "").lowercased()
                guard annotationType.contains("ink"),
                      let target = annotation.border?.lineWidth,
                      target > 0,
                      let paths = annotation.paths,
                      !paths.isEmpty else { continue }
                for path in paths where abs(path.lineWidth - target) > 0.01 {
                    path.lineWidth = target
                }
            }
        }
    }

    private func profileOpenedDocumentAndWarn(document: PDFDocument, sourceURL: URL) {
        let started = CFAbsoluteTimeGetCurrent()
        let pageCount = document.pageCount
        let samplePageCount = min(pageCount, 24)
        var sampleAnnotationCount = 0
        if samplePageCount > 0 {
            for pageIndex in 0..<samplePageCount {
                sampleAnnotationCount += document.page(at: pageIndex)?.annotations.count ?? 0
            }
        }

        let estimatedTotalAnnotations: Int
        if pageCount == 0 || samplePageCount == 0 {
            estimatedTotalAnnotations = 0
        } else {
            let density = Double(sampleAnnotationCount) / Double(samplePageCount)
            estimatedTotalAnnotations = Int((density * Double(pageCount)).rounded())
        }

        let fileBytes = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let fileMB = Double(fileBytes) / (1024.0 * 1024.0)
        let elapsedMs = Int(((CFAbsoluteTimeGetCurrent() - started) * 1000.0).rounded())

        let isHeavy = pageCount >= 400 || estimatedTotalAnnotations >= 12000 || fileMB >= 180
        guard isHeavy else { return }

        let alert = NSAlert()
        alert.messageText = "Large Drawing Set Detected"
        alert.informativeText = """
\(sourceURL.lastPathComponent)
Pages: \(pageCount)
Estimated Markups: \(estimatedTotalAnnotations)
File Size: \(String(format: "%.1f", fileMB)) MB
Profile Time: \(elapsedMs) ms

Drawbridge is tuned for this, but very large files may refresh slower during heavy editing.
"""
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
        markMarkupChanged()
        performRefreshMarkups(selecting: annotation)
        scheduleAutosave()
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

    private func registerSessionDocument(_ url: URL) {
        let normalized = canonicalDocumentURL(url)
        sessionDocumentURLs.removeAll { canonicalDocumentURL($0) == normalized }
        sessionDocumentURLs.append(normalized)
        refreshDocumentTabs()
    }

    private func canonicalDocumentURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func clearToStartState() {
        cancelAutoNameCapture()
        pdfView.document = nil
        clearMarkupCache()
        pageLabelOverrides.removeAll()
        openDocumentURL = nil
        hasPromptedForInitialMarkupSaveCopy = true
        isPresentingInitialMarkupSaveCopyPrompt = false
        pendingCalibrationDistanceInPoints = nil
        pendingAutosaveWorkItem?.cancel()
        pendingAutosaveWorkItem = nil
        pendingMarkupsRefreshWorkItem?.cancel()
        pendingMarkupsRefreshWorkItem = nil
        autosaveURL = nil
        autosaveInFlight = false
        autosaveQueued = false
        markupChangeVersion = 0
        lastAutosavedChangeVersion = 0
        lastMarkupEditAt = .distantPast
        lastUserInteractionAt = .distantPast
        markupsTable.deselectAll(nil)
        selectedMarkupOverlayLayer.isHidden = true
        refreshMarkups()
        view.window?.title = "Drawbridge"
        view.window?.isDocumentEdited = false
        updateEmptyStateVisibility()
        refreshRulers()
        updateStatusBar()
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

    private func selectMarkupFromPageClick(page: PDFPage, annotation: PDFAnnotation) {
        guard let document = pdfView.document else { return }
        let pageIndex = document.index(for: page)
        if pageIndex < 0 {
            NSSound.beep()
            return
        }

        if !markupItems.contains(where: { $0.pageIndex == pageIndex && $0.annotation === annotation }) {
            performRefreshMarkups(selecting: annotation)
        }
        let related = Set(relatedCalloutAnnotations(for: annotation, on: page).map(ObjectIdentifier.init))
        let relatedRows = IndexSet(markupItems.enumerated().compactMap { idx, item in
            guard item.pageIndex == pageIndex else { return nil }
            return related.contains(ObjectIdentifier(item.annotation)) ? idx : nil
        })
        if !relatedRows.isEmpty {
            markupsTable.selectRowIndexes(relatedRows, byExtendingSelection: false)
            if let first = relatedRows.first {
                markupsTable.scrollRowToVisible(first)
            }
            updateToolSettingsUIForCurrentTool()
            updateStatusBar()
            return
        }

        let targetRow = markupItems.firstIndex(where: { $0.pageIndex == pageIndex && $0.annotation === annotation })
            ?? nearestMarkupRow(to: annotation.bounds, onPageIndex: pageIndex)
        if let row = targetRow {
            markupsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            markupsTable.scrollRowToVisible(row)
            updateToolSettingsUIForCurrentTool()
            updateStatusBar()
            return
        }
        NSSound.beep()
    }

    private func nearestMarkupRow(to bounds: NSRect, onPageIndex pageIndex: Int) -> Int? {
        var bestRow: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        let targetCenter = NSPoint(x: bounds.midX, y: bounds.midY)
        for (idx, item) in markupItems.enumerated() where item.pageIndex == pageIndex {
            let b = item.annotation.bounds
            let center = NSPoint(x: b.midX, y: b.midY)
            let d = hypot(center.x - targetCenter.x, center.y - targetCenter.y)
            if d < bestDistance {
                bestDistance = d
                bestRow = idx
            }
        }
        return bestRow
    }

    private func autosaveDirectoryURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("Drawbridge").appendingPathComponent("Autosave")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
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

    private func configureAutosaveURL(for _: URL?) {
        autosaveURL = nil
    }

    private func scheduleAutosave() {
        return
    }

    private func performAutosaveNow() {
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

    private func currentSelectedMarkupItem() -> MarkupItem? {
        let row = markupsTable.selectedRow
        guard row >= 0, row < markupItems.count else {
            return nil
        }
        return markupItems[row]
    }

    private func currentSelectedMarkupItems() -> [MarkupItem] {
        markupsTable.selectedRowIndexes.compactMap { row in
            guard row >= 0, row < markupItems.count else { return nil }
            return markupItems[row]
        }
    }

    private func currentSelectedAnnotation() -> PDFAnnotation? {
        currentSelectedMarkupItem()?.annotation
    }

    private func restoreSelection(for annotation: PDFAnnotation?) {
        guard let annotation else {
            markupsTable.deselectAll(nil)
            selectedMarkupOverlayLayer.isHidden = true
            updateToolSettingsUIForCurrentTool()
            return
        }
        guard let row = markupItems.firstIndex(where: { $0.annotation === annotation }) else {
            markupsTable.deselectAll(nil)
            selectedMarkupOverlayLayer.isHidden = true
            updateToolSettingsUIForCurrentTool()
            return
        }
        markupsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        updateToolSettingsUIForCurrentTool()
    }

    func updateSelectionOverlay() {
        let selectedItems = currentSelectedMarkupItems()
        guard !selectedItems.isEmpty else {
            selectedMarkupOverlayLayer.isHidden = true
            return
        }

        let path = CGMutablePath()
        var addedAny = false
        for item in selectedItems {
            guard let page = pdfView.document?.page(at: item.pageIndex) else { continue }
            let bounds = item.annotation.bounds
            let p1 = pdfView.convert(bounds.origin, from: page)
            let p2 = pdfView.convert(NSPoint(x: bounds.maxX, y: bounds.maxY), from: page)
            let annotationType = (item.annotation.type ?? "").lowercased()
            let overlayInset: CGFloat = annotationType.contains("ink") ? -1 : -3
            let rect = NSRect(
                x: min(p1.x, p2.x),
                y: min(p1.y, p2.y),
                width: abs(p2.x - p1.x),
                height: abs(p2.y - p1.y)
            ).insetBy(dx: overlayInset, dy: overlayInset)

            guard rect.width > 2, rect.height > 2 else { continue }
            addedAny = true
            path.addRoundedRect(in: rect, cornerWidth: 4, cornerHeight: 4)

            let handleSize: CGFloat = 6
            let handles = [
                NSRect(x: rect.minX - handleSize * 0.5, y: rect.minY - handleSize * 0.5, width: handleSize, height: handleSize),
                NSRect(x: rect.maxX - handleSize * 0.5, y: rect.minY - handleSize * 0.5, width: handleSize, height: handleSize),
                NSRect(x: rect.minX - handleSize * 0.5, y: rect.maxY - handleSize * 0.5, width: handleSize, height: handleSize),
                NSRect(x: rect.maxX - handleSize * 0.5, y: rect.maxY - handleSize * 0.5, width: handleSize, height: handleSize)
            ]
            for h in handles {
                path.addRect(h)
            }
        }

        guard addedAny else {
            selectedMarkupOverlayLayer.isHidden = true
            return
        }

        selectedMarkupOverlayLayer.path = path
        selectedMarkupOverlayLayer.isHidden = false
    }

    private func selectMarkupsFromFence(page: PDFPage, annotations: [PDFAnnotation]) {
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
            markupsTable.deselectAll(nil)
            updateSelectionOverlay()
            updateToolSettingsUIForCurrentTool()
            return
        }
        markupsTable.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first {
            markupsTable.scrollRowToVisible(first)
        }
        updateSelectionOverlay()
        updateToolSettingsUIForCurrentTool()
        updateStatusBar()
    }

    private func relatedCalloutAnnotations(for annotation: PDFAnnotation, on page: PDFPage) -> [PDFAnnotation] {
        if let groupID = pdfView.calloutGroupID(for: annotation) {
            let grouped = page.annotations.filter { pdfView.calloutGroupID(for: $0) == groupID }
            return grouped.isEmpty ? [annotation] : grouped
        }

        let annotationType = (annotation.type ?? "").lowercased()
        let contents = (annotation.contents ?? "").lowercased()
        let isLeader = contents.contains("callout leader")
        let isFreeText = annotationType.contains("free") && annotationType.contains("text")
        guard isLeader || isFreeText else { return [annotation] }

        func centerDistance(_ a: NSRect, _ b: NSRect) -> CGFloat {
            let ac = NSPoint(x: a.midX, y: a.midY)
            let bc = NSPoint(x: b.midX, y: b.midY)
            return hypot(ac.x - bc.x, ac.y - bc.y)
        }

        if isLeader {
            let searchRect = annotation.bounds.insetBy(dx: -30, dy: -30)
            let partner = page.annotations
                .filter { candidate in
                    let type = (candidate.type ?? "").lowercased()
                    guard type.contains("free") && type.contains("text") else { return false }
                    let center = NSPoint(x: candidate.bounds.midX, y: candidate.bounds.midY)
                    return candidate.bounds.intersects(searchRect) || searchRect.contains(center)
                }
                .min(by: { centerDistance($0.bounds, annotation.bounds) < centerDistance($1.bounds, annotation.bounds) })
            if let partner {
                return [annotation, partner]
            }
            return [annotation]
        }

        let expandedTextRect = annotation.bounds.insetBy(dx: -30, dy: -30)
        let partner = page.annotations
            .filter { candidate in
                let candidateContents = (candidate.contents ?? "").lowercased()
                guard candidateContents.contains("callout leader") else { return false }
                let center = NSPoint(x: candidate.bounds.midX, y: candidate.bounds.midY)
                return candidate.bounds.intersects(expandedTextRect) || expandedTextRect.contains(center)
            }
            .min(by: { centerDistance($0.bounds, annotation.bounds) < centerDistance($1.bounds, annotation.bounds) })
        if let partner {
            return [annotation, partner]
        }
        return [annotation]
    }

    private func baseUnitsPerPoint(for unit: String) -> CGFloat {
        switch unit {
        case "in":
            return 1.0 / 72.0
        case "ft":
            return 1.0 / 864.0
        case "m":
            return 0.0003527777778
        default:
            return 1.0
        }
    }

    private func showCalibrationDialog(distanceInPoints: CGFloat) {
        pendingCalibrationDistanceInPoints = distanceInPoints

        let alert = NSAlert()
        alert.messageText = "Calibrate Measurement Scale"
        alert.informativeText = "Enter the real-world distance between the two calibration points."
        alert.alertStyle = .informational

        let knownDistanceField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        knownDistanceField.placeholderString = "Known distance"
        knownDistanceField.stringValue = "10"

        let unitPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 100, height: 24), pullsDown: false)
        unitPopup.addItems(withTitles: ["pt", "in", "ft", "m"])
        if let current = measurementUnitPopup.titleOfSelectedItem {
            unitPopup.selectItem(withTitle: current)
        } else {
            unitPopup.selectItem(withTitle: "ft")
        }

        let row = NSStackView(views: [NSTextField(labelWithString: "Distance:"), knownDistanceField, unitPopup])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        alert.accessoryView = row
        alert.addButton(withTitle: "Apply Calibration")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let knownDistance = CGFloat(knownDistanceField.doubleValue)
        let selectedUnit = unitPopup.titleOfSelectedItem ?? "ft"
        guard knownDistance > 0, let points = pendingCalibrationDistanceInPoints, points > 0 else {
            NSSound.beep()
            return
        }

        let unitsPerPoint = knownDistance / points
        let base = baseUnitsPerPoint(for: selectedUnit)
        let scale = unitsPerPoint / base

        measurementUnitPopup.selectItem(withTitle: selectedUnit)
        measurementScaleField.stringValue = String(format: "%.6f", scale)
        applyMeasurementScale()
        pendingCalibrationDistanceInPoints = nil
        setTool(.measure)
    }

    private func applyToolSettingsToPDFView() {
        let opacity = max(0.0, min(1.0, CGFloat(toolSettingsOpacitySlider.doubleValue)))
        let currentWidth = widthValue(for: selectedLineWeightLevel(), tool: pdfView.toolMode)
        let stroke = toolSettingsStrokeColorWell.color.withAlphaComponent(opacity)
        let fill = toolSettingsFillColorWell.color.withAlphaComponent(opacity)
        let selectedItems = currentSelectedMarkupItems()

        if pdfView.toolMode == .select, !selectedItems.isEmpty {
            var editedAny = false
            var firstEdited: PDFAnnotation?
            for item in selectedItems {
                let annotation = item.annotation
                let annotationType = (annotation.type ?? "").lowercased()
                let previous = snapshot(for: annotation)
                var didEdit = false

                if annotationType.contains("freetext") {
                    annotation.color = stroke.withAlphaComponent(opacity * 0.5)
                    annotation.fontColor = fill
                    didEdit = true
                } else {
                    annotation.color = stroke
                    if annotationType.contains("square") || annotationType.contains("circle") {
                        annotation.interiorColor = fill
                    }
                    if !annotationType.contains("highlight") {
                        let inferredTool = inferredToolMode(for: annotation)
                        let updatedWidth = widthValue(for: selectedLineWeightLevel(), tool: inferredTool)
                        assignLineWidth(updatedWidth, to: annotation)
                    }
                    didEdit = true
                }

                if didEdit {
                    registerAnnotationStateUndo(annotation: annotation, previous: previous, actionName: "Edit Markup Appearance")
                    markPageMarkupCacheDirty(annotation.page)
                    editedAny = true
                    if firstEdited == nil {
                        firstEdited = annotation
                    }
                }
            }
            if editedAny {
                markMarkupChanged()
                performRefreshMarkups(selecting: firstEdited)
                scheduleAutosave()
            }
            return
        }

        switch pdfView.toolMode {
        case .grab:
            break
        case .pen, .line, .polyline:
            pdfView.penColor = stroke
            pdfView.penLineWidth = currentWidth
        case .area:
            pdfView.penColor = stroke
            pdfView.areaLineWidth = currentWidth
        case .highlighter:
            pdfView.highlighterColor = stroke
            pdfView.highlighterLineWidth = currentWidth
        case .cloud, .rectangle:
            pdfView.rectangleStrokeColor = stroke
            pdfView.rectangleFillColor = fill
            pdfView.rectangleLineWidth = currentWidth
        case .text:
            pdfView.textForegroundColor = fill
            pdfView.textBackgroundColor = stroke.withAlphaComponent(opacity * 0.5)
        case .callout:
            pdfView.calloutStrokeColor = stroke
            pdfView.calloutLineWidth = currentWidth
            pdfView.textForegroundColor = fill
            pdfView.textBackgroundColor = stroke.withAlphaComponent(opacity * 0.5)
        case .measure, .calibrate:
            pdfView.measurementStrokeColor = stroke
            pdfView.calibrationStrokeColor = stroke
            pdfView.measurementLineWidth = currentWidth
        case .select:
            break
        }
    }

    private func updateToolSettingsUIForCurrentTool() {
        let selectedItems = currentSelectedMarkupItems()
        if pdfView.toolMode == .select, let primary = selectedItems.first?.annotation {
            let inferredTool = inferredToolMode(for: primary)
            let annotationType = (primary.type ?? "").lowercased()
            let count = selectedItems.count
            toolSettingsToolLabel.stringValue = count == 1 ? "Selected Markup" : "Selected Markups: \(count)"

            if annotationType.contains("freetext") {
                toolSettingsStrokeTitleLabel.stringValue = "Background:"
                toolSettingsFillTitleLabel.stringValue = "Text:"
                toolSettingsFillRow.isHidden = false
                toolSettingsWidthRow.isHidden = true
                toolSettingsLineWidthPopup.isEnabled = false
                let background = primary.color
                toolSettingsStrokeColorWell.color = background.withAlphaComponent(1.0)
                toolSettingsOpacitySlider.doubleValue = Double(background.alphaComponent)
                toolSettingsFillColorWell.color = (primary.fontColor ?? NSColor.labelColor).withAlphaComponent(1.0)
            } else {
                toolSettingsStrokeTitleLabel.stringValue = "Color:"
                toolSettingsFillTitleLabel.stringValue = "Fill:"
                toolSettingsFillRow.isHidden = !(annotationType.contains("square") || annotationType.contains("circle"))
                toolSettingsWidthRow.isHidden = false
                toolSettingsLineWidthPopup.isEnabled = true
                toolSettingsStrokeColorWell.color = primary.color.withAlphaComponent(1.0)
                toolSettingsOpacitySlider.doubleValue = Double(primary.color.alphaComponent)
                toolSettingsFillColorWell.color = (primary.interiorColor ?? NSColor.systemYellow).withAlphaComponent(1.0)
                let currentLineWidth = resolvedLineWidth(for: primary)
                selectLineWeightLevel(
                    for: currentLineWidth > 0 ? currentLineWidth : widthValue(for: 5, tool: inferredTool),
                    tool: inferredTool
                )
            }

            toolSettingsOpacityValueLabel.stringValue = "\(Int(round(toolSettingsOpacitySlider.doubleValue * 100)))%"
            toolSettingsOpacitySlider.isEnabled = true
            toolSettingsStrokeColorWell.isEnabled = true
            toolSettingsFillColorWell.isEnabled = !toolSettingsFillRow.isHidden
            return
        }

        toolSettingsToolLabel.stringValue = "Active Tool: \(currentToolName())"
        toolSettingsOpacityValueLabel.stringValue = "\(Int(round(toolSettingsOpacitySlider.doubleValue * 100)))%"

        switch pdfView.toolMode {
        case .grab:
            toolSettingsStrokeTitleLabel.stringValue = "Color:"
            toolSettingsFillTitleLabel.stringValue = "Fill:"
            toolSettingsFillRow.isHidden = true
            toolSettingsWidthRow.isHidden = true
            toolSettingsOpacitySlider.isEnabled = false
            toolSettingsStrokeColorWell.isEnabled = false
            toolSettingsFillColorWell.isEnabled = false
            toolSettingsLineWidthPopup.isEnabled = false
        case .select:
            toolSettingsStrokeTitleLabel.stringValue = "Color:"
            toolSettingsFillTitleLabel.stringValue = "Fill:"
            toolSettingsFillRow.isHidden = true
            toolSettingsWidthRow.isHidden = true
            toolSettingsOpacitySlider.isEnabled = false
            toolSettingsStrokeColorWell.isEnabled = false
            toolSettingsFillColorWell.isEnabled = false
            toolSettingsLineWidthPopup.isEnabled = false
        case .pen, .line, .polyline:
            toolSettingsStrokeColorWell.color = pdfView.penColor.withAlphaComponent(1.0)
            toolSettingsOpacitySlider.doubleValue = Double(pdfView.penColor.alphaComponent)
            toolSettingsOpacityValueLabel.stringValue = "\(Int(round(toolSettingsOpacitySlider.doubleValue * 100)))%"
            selectLineWeightLevel(for: pdfView.penLineWidth, tool: pdfView.toolMode)
            toolSettingsStrokeTitleLabel.stringValue = "Color:"
            toolSettingsFillTitleLabel.stringValue = "Fill:"
            toolSettingsFillRow.isHidden = true
            toolSettingsWidthRow.isHidden = false
            toolSettingsOpacitySlider.isEnabled = true
            toolSettingsStrokeColorWell.isEnabled = true
            toolSettingsFillColorWell.isEnabled = true
            toolSettingsLineWidthPopup.isEnabled = true
        case .area:
            toolSettingsStrokeColorWell.color = pdfView.penColor.withAlphaComponent(1.0)
            toolSettingsOpacitySlider.doubleValue = Double(pdfView.penColor.alphaComponent)
            toolSettingsOpacityValueLabel.stringValue = "\(Int(round(toolSettingsOpacitySlider.doubleValue * 100)))%"
            selectLineWeightLevel(for: pdfView.areaLineWidth, tool: .area)
            toolSettingsStrokeTitleLabel.stringValue = "Color:"
            toolSettingsFillTitleLabel.stringValue = "Fill:"
            toolSettingsFillRow.isHidden = true
            toolSettingsWidthRow.isHidden = false
            toolSettingsOpacitySlider.isEnabled = true
            toolSettingsStrokeColorWell.isEnabled = true
            toolSettingsFillColorWell.isEnabled = true
            toolSettingsLineWidthPopup.isEnabled = true
        case .highlighter:
            toolSettingsStrokeColorWell.color = pdfView.highlighterColor.withAlphaComponent(1.0)
            toolSettingsOpacitySlider.doubleValue = Double(pdfView.highlighterColor.alphaComponent)
            toolSettingsOpacityValueLabel.stringValue = "\(Int(round(toolSettingsOpacitySlider.doubleValue * 100)))%"
            selectLineWeightLevel(for: pdfView.highlighterLineWidth, tool: .highlighter)
            toolSettingsStrokeTitleLabel.stringValue = "Color:"
            toolSettingsFillTitleLabel.stringValue = "Fill:"
            toolSettingsFillRow.isHidden = true
            toolSettingsWidthRow.isHidden = false
            toolSettingsOpacitySlider.isEnabled = true
            toolSettingsStrokeColorWell.isEnabled = true
            toolSettingsFillColorWell.isEnabled = true
            toolSettingsLineWidthPopup.isEnabled = true
        case .cloud, .rectangle:
            selectLineWeightLevel(for: pdfView.rectangleLineWidth, tool: .rectangle)
            toolSettingsStrokeTitleLabel.stringValue = "Stroke:"
            toolSettingsFillTitleLabel.stringValue = "Fill:"
            toolSettingsFillRow.isHidden = false
            toolSettingsWidthRow.isHidden = false
            toolSettingsOpacitySlider.isEnabled = true
            toolSettingsStrokeColorWell.isEnabled = true
            toolSettingsFillColorWell.isEnabled = true
            toolSettingsLineWidthPopup.isEnabled = true
        case .text:
            toolSettingsStrokeTitleLabel.stringValue = "Background:"
            toolSettingsFillTitleLabel.stringValue = "Text:"
            toolSettingsFillRow.isHidden = false
            toolSettingsWidthRow.isHidden = true
            toolSettingsOpacitySlider.isEnabled = true
            toolSettingsStrokeColorWell.isEnabled = true
            toolSettingsFillColorWell.isEnabled = true
            toolSettingsLineWidthPopup.isEnabled = false
        case .callout:
            selectLineWeightLevel(for: pdfView.calloutLineWidth, tool: .callout)
            toolSettingsStrokeTitleLabel.stringValue = "Leader:"
            toolSettingsFillTitleLabel.stringValue = "Text:"
            toolSettingsFillRow.isHidden = false
            toolSettingsWidthRow.isHidden = false
            toolSettingsOpacitySlider.isEnabled = true
            toolSettingsStrokeColorWell.isEnabled = true
            toolSettingsFillColorWell.isEnabled = true
            toolSettingsLineWidthPopup.isEnabled = true
        case .measure, .calibrate:
            selectLineWeightLevel(for: pdfView.measurementLineWidth, tool: .measure)
            toolSettingsStrokeTitleLabel.stringValue = "Line:"
            toolSettingsFillTitleLabel.stringValue = "Fill:"
            toolSettingsFillRow.isHidden = true
            toolSettingsWidthRow.isHidden = false
            toolSettingsOpacitySlider.isEnabled = true
            toolSettingsStrokeColorWell.isEnabled = true
            toolSettingsFillColorWell.isEnabled = true
            toolSettingsLineWidthPopup.isEnabled = true
        }
    }

    private func selectedLineWeightLevel() -> Int {
        let selected = Int(toolSettingsLineWidthPopup.titleOfSelectedItem ?? "") ?? 5
        return min(max(selected, 1), 10)
    }

    private func selectLineWeightLevel(for lineWidth: CGFloat, tool: ToolMode) {
        let nearest = lineWeightLevels.min { lhs, rhs in
            abs(widthValue(for: lhs, tool: tool) - lineWidth) < abs(widthValue(for: rhs, tool: tool) - lineWidth)
        } ?? 5
        toolSettingsLineWidthPopup.selectItem(withTitle: "\(nearest)")
    }

    private func widthValue(for lineWeightLevel: Int, tool: ToolMode) -> CGFloat {
        let level = min(max(lineWeightLevel, 1), 10)
        switch tool {
        case .grab:
            return 1
        case .area:
            return interpolateLevel(level, lowAt1: 1, midAt5: 2, highAt10: 4)
        case .pen, .line, .polyline:
            return interpolateLevel(level, lowAt1: 6, midAt5: 15, highAt10: 25)
        case .highlighter:
            return interpolateLevel(level, lowAt1: 12, midAt5: 25, highAt10: 40)
        case .cloud, .rectangle:
            return interpolateLevel(level, lowAt1: 12, midAt5: 25, highAt10: 50)
        case .callout, .measure, .calibrate:
            return interpolateLevel(level, lowAt1: 1, midAt5: 2, highAt10: 4)
        case .select, .text:
            return 1
        }
    }

    private func inferredToolMode(for annotation: PDFAnnotation) -> ToolMode {
        let type = (annotation.type ?? "").lowercased()
        if type.contains("freetext") {
            return .text
        }
        if type.contains("square") || type.contains("circle") {
            return .rectangle
        }
        if type.contains("highlight") {
            return .highlighter
        }
        if type.contains("ink") {
            let contents = (annotation.contents ?? "").lowercased()
            if contents.contains("highlighter") {
                return .highlighter
            }
            if contents.contains("polyline") {
                return .polyline
            }
            if contents == "line" {
                return .line
            }
            if contents.contains("area") {
                return .area
            }
            if contents.contains("callout") {
                return .callout
            }
            if contents.contains("measure") {
                return .measure
            }
            return .pen
        }
        if type.contains("line") {
            return .measure
        }
        return .pen
    }

    private func interpolateLevel(_ level: Int, lowAt1: CGFloat, midAt5: CGFloat, highAt10: CGFloat) -> CGFloat {
        if level <= 5 {
            let t = CGFloat(level - 1) / 4.0
            return lowAt1 + (midAt5 - lowAt1) * t
        }
        let t = CGFloat(level - 5) / 5.0
        return midAt5 + (highAt10 - midAt5) * t
    }

    private func updateMeasurementSummary() {
        guard let document = pdfView.document else {
            measurementCountLabel.stringValue = "Measurements: 0"
            measurementTotalLabel.stringValue = "Total Length: 0 \(pdfView.measurementUnitLabel)"
            return
        }

        var count = 0
        var totalPoints: CGFloat = 0
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                guard let contents = annotation.contents,
                      contents.hasPrefix("DrawbridgeMeasure|"),
                      let points = Double(contents.replacingOccurrences(of: "DrawbridgeMeasure|", with: "")) else { continue }
                count += 1
                totalPoints += CGFloat(points)
            }
        }

        let totalInDisplayUnits = totalPoints * pdfView.measurementUnitsPerPoint
        measurementCountLabel.stringValue = "Measurements: \(count)"
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

    private func currentToolName() -> String {
        switch pdfView.toolMode {
        case .select:
            return "Selection"
        case .grab:
            return "Grab"
        case .pen:
            return "Draw"
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
        case .line: return 3
        case .polyline: return 4
        case .highlighter: return 5
        case .cloud: return 6
        case .rectangle: return 7
        case .text: return 8
        case .callout: return 9
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

    private func startAutoGenerateSheetNamesFlow() {
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
            runAutoNameExtraction()
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

        markMarkupChanged()
        scheduleAutosave()
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
        return cleanDetectedSheetText(recognizeText(in: image))
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
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            guard let observations = request.results else { return "" }
            return observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
        } catch {
            return ""
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
        let hasDocument = (pdfView.document != nil)
        emptyStateView.isHidden = hasDocument
        emptyStateSampleButton.isEnabled = true
        pdfView.isHidden = !hasDocument
        bookmarksContainer.isHidden = !showNavigationPane
        bookmarksWidthConstraint?.constant = showNavigationPane ? 220 : 0
        didApplyInitialSplitLayout = false
        applySplitLayoutIfPossible(force: true)
        view.layoutSubtreeIfNeeded()
        refreshRulers()
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

    private func saveCurrentDocumentForClosePrompt() -> Bool {
        guard let document = pdfView.document else { return true }
        if let sourceURL = openDocumentURL {
            return persistProjectSnapshotSynchronously(document: document, for: sourceURL, busyMessage: "Saving Changes…")
        }
        // Unsaved new document path still requires Save As flow.
        saveDocumentAsProject(document: document)
        return false
    }

    private func persistProjectSnapshotSynchronously(document: PDFDocument, for sourcePDFURL: URL, busyMessage: String) -> Bool {
        pendingAutosaveWorkItem?.cancel()
        pendingAutosaveWorkItem = nil
        autosaveQueued = false
        manualSaveInFlight = true
        beginBusyIndicator(busyMessage, detail: "Saving…", lockInteraction: true)
        defer {
            endBusyIndicator()
            manualSaveInFlight = false
            if autosaveQueued {
                autosaveQueued = false
                scheduleAutosave()
            }
        }

        let sidecar = sidecarURL(for: sourcePDFURL)
        let snapshot = buildSidecarSnapshot(document: document, sourcePDFURL: sourcePDFURL)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary

        guard let data = try? encoder.encode(snapshot) else {
            let alert = NSAlert()
            alert.messageText = "Failed to save changes"
            alert.informativeText = "Could not encode project snapshot."
            alert.alertStyle = .warning
            alert.runModal()
            return false
        }

        do {
            try data.write(to: sidecar, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to save changes"
            alert.informativeText = "Could not write changes to disk.\n\n\(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()
            return false
        }

        markupChangeVersion = 0
        lastAutosavedChangeVersion = 0
        lastMarkupEditAt = .distantPast
        lastUserInteractionAt = .distantPast
        view.window?.isDocumentEdited = false
        updateStatusBar()
        return true
    }
}
