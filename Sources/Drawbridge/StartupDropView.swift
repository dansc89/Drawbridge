import AppKit
import UniformTypeIdentifiers

final class StartupDropView: NSView {
    private enum DropVisualState {
        case hidden
        case valid
        case invalid
    }

    var onOpenDroppedPDF: ((URL) -> Void)?
    var onAppearanceChanged: (() -> Void)?
    private let dropHighlightLayer = CAShapeLayer()
    private var dropVisualState: DropVisualState = .hidden

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        registerForDraggedTypes([.fileURL, .URL])
        configureDropHighlightLayerIfNeeded()
    }

    override func layout() {
        super.layout()
        updateDropHighlightPath()
    }

    private func configureDropHighlightLayerIfNeeded() {
        guard let hostLayer = layer else { return }
        if dropHighlightLayer.superlayer == nil {
            dropHighlightLayer.lineWidth = 2.0
            dropHighlightLayer.isHidden = true
            dropHighlightLayer.zPosition = 100
            hostLayer.addSublayer(dropHighlightLayer)
        }
        updateDropHighlightPath()
    }

    private func updateDropHighlightPath() {
        let inset: CGFloat = 4
        let rect = bounds.insetBy(dx: inset, dy: inset)
        dropHighlightLayer.path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
    }

    private func setDropVisualState(_ state: DropVisualState) {
        dropVisualState = state
        switch state {
        case .hidden:
            dropHighlightLayer.isHidden = true
        case .valid:
            dropHighlightLayer.isHidden = false
            dropHighlightLayer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.95).cgColor
            dropHighlightLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.16).cgColor
        case .invalid:
            dropHighlightLayer.isHidden = false
            dropHighlightLayer.strokeColor = NSColor.systemRed.withAlphaComponent(0.90).cgColor
            dropHighlightLayer.fillColor = NSColor.systemRed.withAlphaComponent(0.14).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let valid = droppedPDFURL(from: sender) != nil
        setDropVisualState(valid ? .valid : .invalid)
        return valid ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let valid = droppedPDFURL(from: sender) != nil
        setDropVisualState(valid ? .valid : .invalid)
        return valid ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let valid = droppedPDFURL(from: sender) != nil
        setDropVisualState(valid ? .valid : .invalid)
        return valid
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setDropVisualState(.hidden) }
        guard let url = droppedPDFURL(from: sender) else { return false }
        onOpenDroppedPDF?(url)
        return true
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropVisualState(.hidden)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDropVisualState(.hidden)
    }

    private func droppedPDFURL(from draggingInfo: NSDraggingInfo) -> URL? {
        let classes: [AnyClass] = [NSURL.self]
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let items = draggingInfo.draggingPasteboard.readObjects(forClasses: classes, options: options) as? [URL] else {
            return nil
        }
        for url in items {
            guard url.isFileURL else { continue }
            if url.pathExtension.lowercased() == "pdf" { return url }
            if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .pdf) {
                return url
            }
        }
        return nil
    }
}
