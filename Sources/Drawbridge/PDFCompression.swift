import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

enum PDFCompressionLevel: Int, CaseIterable, Sendable {
    case low, medium, high
    var title: String { ["Lossless Compression", "Image Compression — Preserve Vectors", "Rasterize Pages"][rawValue] }
    var detail: String {
        switch self {
        case .low: return "Reduces file size without changing image quality or drawing content. Preserves image resolution, vector linework, text, links and Unflatten recovery. Saves to the open PDF only if smaller."
        case .medium: return "Compresses eligible images at 80% JPEG quality. Vector linework, text, page geometry and links stay intact; image detail may change. Saves a separate copy only if smaller."
        case .high: return "Creates image-based pages at up to 200 DPI for simpler rendering and navigation. This is a navigation optimization, not a higher compression level; file size may increase. Text is no longer searchable; links, bookmarks, scale metadata, layers, forms and editable markups are flattened or removed. Large sheets use a bounded resolution. Saves a separate copy."
        }
    }
}

@MainActor final class PDFCompressionPicker: NSObject {
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    var level: PDFCompressionLevel { PDFCompressionLevel(rawValue: popup.indexOfSelectedItem) ?? .low }
    override init() {
        super.init()
        popup.addItems(withTitles: PDFCompressionLevel.allCases.map(\.title))
        popup.setAccessibilityLabel("PDF optimization")
        popup.identifier = NSUserInterfaceItemIdentifier("pdfCompressionLevel")
        popup.target = self; popup.action = #selector(updateDetail)
        updateDetail()
    }
    @objc func updateDetail() { descriptionLabel.stringValue = level.detail }
    func choose() -> PDFCompressionLevel? {
        let alert = NSAlert(); alert.messageText = "Optimize PDF"
        alert.informativeText = "Choose compression to reduce file size, or rasterize for simpler page rendering. Image Compression and Rasterize Pages save separate copies, keeping your original PDF and current edits unchanged."
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        let stack = NSStackView(views: [popup, descriptionLabel]); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 12
        stack.frame = NSRect(x: 0, y: 0, width: 440, height: 180)
        popup.widthAnchor.constraint(equalToConstant: 440).isActive = true
        descriptionLabel.widthAnchor.constraint(equalToConstant: 440).isActive = true
        alert.accessoryView = stack
        AppAppearance.applyInterface(to: alert.window)
        return alert.runModal() == .alertFirstButtonReturn ? level : nil
    }
}

enum PDFCompression {
    /// Operates on a private snapshot, writing a NEW copy. Never replaces a file.
    static func saveCopy(source: URL, destination: URL, level: PDFCompressionLevel,
                         progress: @Sendable (String) -> Void = { _ in },
                         cancelled: @Sendable () -> Bool = { false }) throws -> PDFLosslessReducer.Report {
        func failure(_ message: String) -> NSError { NSError(domain: "DrawbridgeCompression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        guard source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath(),
              !FileManager.default.fileExists(atPath: destination.path) else { throw failure("Choose a new filename. The original and existing files are never replaced.") }
        let directory = destination.deletingLastPathComponent().appendingPathComponent(".DrawbridgeCompression-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("compressed.pdf")
        if cancelled() { throw CancellationError() }
        let report: PDFLosslessReducer.Report
        if level != .high {
            try FileManager.default.copyItem(at: source, to: output)
            do {
                report = try PDFLosslessReducer.reduce(source: output, level: level, progress: progress, cancelled: cancelled)
            } catch is CancellationError { throw CancellationError() }
            catch { throw failure("Image compression could not be completed: \(error.localizedDescription)") }
            guard report.saved else { return report }
        } else {
            guard let document = PDFDocument(url: source), document.pageCount > 0, !document.isLocked else { throw failure("Open an unlocked, valid PDF first.") }
            let original = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard let consumer = CGDataConsumer(url: output as CFURL), let pdf = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw failure("Could not create the rasterized PDF.") }
            var closed = false; defer { if !closed { pdf.closePDF() } }
            for index in 0..<document.pageCount {
                if cancelled() { throw CancellationError() }
                progress("Rendering page \(index + 1) of \(document.pageCount)…")
                try autoreleasepool {
                    guard let page = document.page(at: index) else { throw failure("A PDF page could not be read.") }
                    let bounds = page.bounds(for: .cropBox)
                    let oriented = bounds.applying(page.transform(for: .cropBox)).standardized
                    guard oriented.width.isFinite, oriented.height.isFinite, oriented.width > 0, oriented.height > 0 else { throw failure("A PDF page has invalid dimensions.") }
                    let scale = min(200.0 / 72, sqrt(32_000_000 / oriented.width / oriented.height), 10_000 / max(oriented.width, oriented.height))
                    guard let rendered = PDFRegionRasterizer.render(page: page, box: .cropBox, rect: bounds, scale: scale) else { throw failure("Could not render page \(index + 1). No copy was saved.") }
                    let jpeg = NSMutableData()
                    guard let encoder = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { throw failure("Could not compress the page image.") }
                    CGImageDestinationAddImage(encoder, rendered, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
                    guard CGImageDestinationFinalize(encoder), let provider = CGDataProvider(data: jpeg),
                          let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw failure("Could not encode the page image.") }
                    var box = CGRect(origin: .zero, size: oriented.size)
                    let boxData = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
                    pdf.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
                    pdf.draw(image, in: box); pdf.endPDFPage()
                }
            }
            pdf.closePDF(); closed = true
            guard let result = PDFDocument(url: output), result.pageCount == document.pageCount else { throw failure("Rasterized page verification failed. No copy was saved.") }
            let bytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes > 0 else { throw failure("The output was empty. No copy was saved.") }
            report = PDFLosslessReducer.Report(originalBytes: original, reducedBytes: bytes, saved: true)
        }
        if cancelled() { throw CancellationError() }
        progress("Saving compressed copy…")
        // Same-volume hard link fails atomically if another file appeared at the target.
        do { try FileManager.default.linkItem(at: output, to: destination) }
        catch { throw failure("Could not save the new compressed copy: \(error.localizedDescription)") }
        return report
    }
}
