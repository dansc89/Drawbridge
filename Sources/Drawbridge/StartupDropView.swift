import AppKit
import UniformTypeIdentifiers

final class StartupDropView: NSView {
    var onOpenDroppedPDF: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .URL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .URL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedPDFURL(from: sender) != nil ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        droppedPDFURL(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedPDFURL(from: sender) else { return false }
        onOpenDroppedPDF?(url)
        return true
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
