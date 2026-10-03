import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

@MainActor
extension MainViewController {
    private struct CleanedPDFCopy {
        let document: PDFDocument
        let removedAnnotationCount: Int
    }

    private struct ReducedPDFResult {
        let removedAnnotationCount: Int
        let fileSize: Int64
        let method: String
    }

    private struct PDFProcessingPreset {
        let dpi: CGFloat
        let jpegQuality: CGFloat
    }

    func isExtraneousEmbeddedPDFAnnotation(_ annotation: PDFAnnotation) -> Bool {
        let userName = (annotation.userName ?? "").lowercased()
        let contents = (annotation.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let type = (annotation.type ?? "").lowercased()
        if userName.contains("autocad shx text") {
            return true
        }
        return type.contains("square") && !annotation.shouldPrint && !contents.isEmpty
    }

    func flattenPDF() {
        guard let document = pdfView.document, let source = openDocumentURL,
              !isPDFProcessingBusy else { beep(); return }
        if hasUnsavedChanges() {
            persistDocument(to: source, adoptAsPrimaryDocument: false, busyMessage: "Saving PDF…", document: document, completion: { [weak self] saved in
                if saved { self?.flattenPDF() }
            })
            return
        }
        let unflattening = PDFAnnotationFlattener.canUnflatten(document)
        let output = canonicalDocumentURL(source)
        isFlatteningDocumentOperation = true
        beginBusyIndicator(unflattening ? "Unflattening PDF…" : "Flattening PDF…", detail: "Checking annotations…")
        let documentID = ObjectIdentifier(document)
        let controller = self
        DispatchQueue.global(qos: .userInitiated).async {
            let progress: @Sendable (String) -> Void = { detail in
                DispatchQueue.main.async { controller.updateBusyIndicatorDetail(detail) }
            }
            let result = Result {
                try unflattening ? PDFAnnotationFlattener.unflatten(source: output, progress: progress)
                    : PDFAnnotationFlattener.flatten(source: source, destination: output, progress: progress)
            }
            DispatchQueue.main.async {
                let owner = controller
                owner.isFlatteningDocumentOperation = false
                owner.endBusyIndicator()
                switch result {
                case .success(let report):
                    if owner.pdfView.document.map(ObjectIdentifier.init) == documentID, !owner.hasUnsavedChanges() {
                        owner.openDocument(at: output)
                    }
                    var details: [String] = []
                    if unflattening { details.append("Restored \(report.restoredAnnotations) editable annotation(s) without duplicating their visible content.") }
                    if report.flattened > 0 {
                        details.append("Made \(report.flattened) visible markup(s) part of the page. Click Unflatten to restore editing.")
                    }
                    if report.removedSHXComments > 0 {
                        details.append("Removed \(report.removedSHXComments) redundant AutoCAD text comment box(es). The original drawing text and linework are preserved.")
                    }
                    if report.retainedMarkups > 0 {
                        details.append("\(report.retainedMarkups) unsupported or hidden markup(s) remain editable.")
                    }
                    details.append("Saved to the PDF you have open. Links and forms were preserved.")
                    owner.runAlert(title: unflattening ? "PDF Unflattened and Saved" : "PDF Flattened and Saved", informativeText: details.joined(separator: "\n\n"))
                case .failure(let error):
                    owner.runAlert(title: unflattening ? "Unflatten Failed" : "Flatten Failed", informativeText: error.localizedDescription, style: .warning)
                }
            }
        }
    }

    func reduceFileSize() {
        guard let document = pdfView.document else { beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = processedPDFName(suffix: "reduced")
        panel.prompt = "Reduce"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        beginBusyIndicator("Reducing File Size…", detail: "Creating compact copy…", lockInteraction: false)
        updateBusyIndicatorProgress(current: 0, total: document.pageCount)
        defer { endBusyIndicator() }

        do {
            let originalSize = openDocumentURL.flatMap { fileSizeBytes(at: $0) } ?? Int64(document.dataRepresentation()?.count ?? 0)
            let result = try writeCompactRasterReducedPDF(document: document, to: outputURL, originalSize: originalSize)
            let sizeDelta = result.fileSize - originalSize
            openDocument(at: outputURL)
            runAlert(
                title: "Reduce File Size Complete",
                informativeText: """
                Created \(outputURL.lastPathComponent).

                Before: \(formatFileSize(originalSize))
                After: \(formatFileSize(result.fileSize))
                Method: \(result.method)
                \(sizeDeltaSummary(sizeDelta))
                Removed \(result.removedAnnotationCount) embedded non-print annotation box(es).
                """
            )
        } catch {
            runAlert(
                title: "Reduce File Size Failed",
                informativeText: error.localizedDescription,
                style: .warning
            )
        }
    }

    private func processedPDFName(suffix: String) -> String {
        let base = (openDocumentURL?.deletingPathExtension().lastPathComponent).flatMap { name in
            name.isEmpty ? nil : name
        } ?? "Drawbridge"
        return "\(base)-\(suffix).pdf"
    }

    private func writeCompactRasterReducedPDF(document: PDFDocument, to outputURL: URL, originalSize: Int64) throws -> ReducedPDFResult {
        let presets = [
            PDFProcessingPreset(dpi: 216, jpegQuality: 0.78),
            PDFProcessingPreset(dpi: 200, jpegQuality: 0.72),
            PDFProcessingPreset(dpi: 180, jpegQuality: 0.66),
            PDFProcessingPreset(dpi: 160, jpegQuality: 0.58),
            PDFProcessingPreset(dpi: 144, jpegQuality: 0.52)
        ]
        var smallestResult: ReducedPDFResult?
        var smallestURL: URL?

        for preset in presets {
            let rasterURL = temporaryPDFURL(for: outputURL)
            do {
                let result = try writeRasterizedReducedPDF(document: document, to: rasterURL, preset: preset)
                if smallestResult == nil || result.fileSize < smallestResult!.fileSize {
                    if let smallestURL {
                        try? FileManager.default.removeItem(at: smallestURL)
                    }
                    smallestResult = result
                    smallestURL = rasterURL
                } else {
                    try? FileManager.default.removeItem(at: rasterURL)
                }
                if originalSize <= 0 || result.fileSize < originalSize {
                    try replacePDF(at: outputURL, with: rasterURL)
                    if let smallestURL, smallestURL != rasterURL {
                        try? FileManager.default.removeItem(at: smallestURL)
                    }
                    return result
                }
            } catch {
                try? FileManager.default.removeItem(at: rasterURL)
                throw error
            }
        }

        guard let smallestResult, let smallestURL else {
            throw NSError(
                domain: "DrawbridgePDFProcessing",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Could not create a compact PDF."]
            )
        }
        try replacePDF(at: outputURL, with: smallestURL)
        return smallestResult
    }

    private func writeRasterizedReducedPDF(
        document: PDFDocument,
        to outputURL: URL,
        preset: PDFProcessingPreset
    ) throws -> ReducedPDFResult {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else {
            throw NSError(domain: "DrawbridgePDFProcessing", code: 8, userInfo: [NSLocalizedDescriptionKey: "Could not create PDF output."])
        }
        guard let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw NSError(domain: "DrawbridgePDFProcessing", code: 9, userInfo: [NSLocalizedDescriptionKey: "Could not create PDF renderer."])
        }

        var removedAnnotationCount = 0
        for pageIndex in 0..<document.pageCount {
            autoreleasepool {
                guard let page = document.page(at: pageIndex) else { return }
                let pageBounds = page.bounds(for: .mediaBox).standardized
                let pageRect = CGRect(origin: .zero, size: pageBounds.size)
                updateBusyIndicatorDetail("Creating compact copy \(Int(preset.dpi)) DPI • page \(pageIndex + 1)/\(document.pageCount)")
                updateBusyIndicatorProgress(current: pageIndex + 1, total: document.pageCount)
                updateBusyIndicatorSubdetail("\(removedAnnotationCount) embedded boxes removed")
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))

                guard let jpegImage = renderedJPEGPageImage(
                    page: page,
                    pageBounds: pageBounds,
                    preset: preset,
                    removedAnnotationCount: &removedAnnotationCount
                ) else { return }
                context.beginPDFPage(pdfPageOptions(mediaBox: pageRect))
                context.setFillColor(NSColor.white.cgColor)
                context.fill(pageRect)
                context.draw(jpegImage, in: pageRect)
                context.endPDFPage()
            }
        }
        context.closePDF()
        try (data as Data).write(to: outputURL, options: .atomic)
        let pageLabels = embeddedPageLabelsForSave(in: document)
        if !pageLabels.isEmpty {
            try PDFPageLabelsEmbedder.embedPageLabels(pageLabels, in: outputURL)
        }
        return ReducedPDFResult(
            removedAnnotationCount: removedAnnotationCount,
            fileSize: try fileSizeBytesRequired(at: outputURL),
            method: "Compact raster copy at \(Int(preset.dpi)) DPI"
        )
    }

    private func renderedJPEGPageImage(
        page: PDFPage,
        pageBounds: NSRect,
        preset: PDFProcessingPreset,
        removedAnnotationCount: inout Int
    ) -> CGImage? {
        let scale = max(0.5, preset.dpi / 72.0)
        let width = max(1, Int((pageBounds.width * scale).rounded(.up)))
        let height = max(1, Int((pageBounds.height * scale).rounded(.up)))
        guard width < 12000, height < 12000 else { return nil }

        var hiddenAnnotations: [(annotation: PDFAnnotation, shouldDisplay: Bool, shouldPrint: Bool)] = []
        for annotation in page.annotations {
            guard isExtraneousEmbeddedPDFAnnotation(annotation) else { continue }
            hiddenAnnotations.append((annotation, annotation.shouldDisplay, annotation.shouldPrint))
            annotation.shouldDisplay = false
            annotation.shouldPrint = false
            removedAnnotationCount += 1
        }
        defer {
            for entry in hiddenAnnotations {
                entry.annotation.shouldDisplay = entry.shouldDisplay
                entry.annotation.shouldPrint = entry.shouldPrint
            }
        }

        let image = page.thumbnail(of: NSSize(width: width, height: height), for: .mediaBox)
        guard let rendered = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let jpegData = jpegData(from: rendered, quality: preset.jpegQuality),
              let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil) else {
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }

    private func pdfPageOptions(mediaBox: CGRect) -> CFDictionary {
        var box = mediaBox
        let boxData = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
        return [kCGPDFContextMediaBox as String: boxData] as CFDictionary
    }

    private func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality as String: max(0.1, min(1.0, quality))] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func fileSizeBytes(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    private func temporaryPDFURL(for outputURL: URL) -> URL {
        let directory = outputURL.deletingLastPathComponent()
        let baseName = outputURL.deletingPathExtension().lastPathComponent
        let extensionName = outputURL.pathExtension.isEmpty ? "pdf" : outputURL.pathExtension
        return directory.appendingPathComponent(".\(baseName)-drawbridge-\(UUID().uuidString).\(extensionName)")
    }

    private func replacePDF(at outputURL: URL, with temporaryURL: URL) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
    }

    private func fileSizeBytesRequired(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw NSError(
                domain: "DrawbridgePDFProcessing",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Could not read the PDF file size."]
            )
        }
        return Int64(size)
    }

    private func formatFileSize(_ size: Int64) -> String {
        guard size > 0 else { return "unknown" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func sizeDeltaSummary(_ delta: Int64) -> String {
        if delta < 0 {
            return "Saved: \(formatFileSize(abs(delta)))"
        }
        if delta > 0 {
            return "Optimized copy is \(formatFileSize(delta)) larger than the original."
        }
        return "Output is the same size as the original."
    }
}
