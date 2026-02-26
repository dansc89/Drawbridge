import AppKit
import Foundation
import PDFKit

enum StressHarness {
    static func run(arguments: [String]) -> Int {
        if let exportSourcePath = stringValue(after: "--export-link-compat", in: arguments),
           !exportSourcePath.isEmpty {
            let sourceURL = URL(fileURLWithPath: exportSourcePath)
            let outputDirectory = stringValue(after: "--export-link-compat-out", in: arguments).flatMap { path -> URL? in
                guard !path.isEmpty else { return nil }
                return URL(fileURLWithPath: path)
            }
            return runLinkCompatibilityExport(sourceURL: sourceURL, outputDirectory: outputDirectory)
        }

        let pages = max(1, intValue(after: "--pages", in: arguments) ?? 250)
        let markupsPerPage = max(1, intValue(after: "--markups-per-page", in: arguments) ?? 80)
        let iterations = max(1, intValue(after: "--iterations", in: arguments) ?? 1)
        let saveIterations = max(0, intValue(after: "--save-iterations", in: arguments) ?? 0)
        let verifyCustomMarkupCompat = arguments.contains("--verify-custom-markup-compat")
        let output = outputURL(from: arguments) ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Drawbridge-Stress.pdf")

        print("Drawbridge stress harness starting")
        print("pages=\(pages) markupsPerPage=\(markupsPerPage) iterations=\(iterations) save_iterations=\(saveIterations)")
        print("output=\(output.path)")

        let started = CFAbsoluteTimeGetCurrent()
        let generated = generateSyntheticPDF(pageCount: pages, markupsPerPage: markupsPerPage)
        let generationMs = Int(((CFAbsoluteTimeGetCurrent() - started) * 1000.0).rounded())
        print("generate_ms=\(generationMs)")

        guard generated.write(to: output) else {
            fputs("failed_to_write_pdf\n", stderr)
            return 2
        }

        guard let loaded = PDFDocument(url: output) else {
            fputs("failed_to_load_written_pdf\n", stderr)
            return 3
        }
        let loadStart = CFAbsoluteTimeGetCurrent()
        var totalMarkups = 0
        for pageIndex in 0..<loaded.pageCount {
            totalMarkups += loaded.page(at: pageIndex)?.annotations.count ?? 0
        }
        let loadMs = Int(((CFAbsoluteTimeGetCurrent() - loadStart) * 1000.0).rounded())
        print("load_scan_ms=\(loadMs)")
        print("total_markups=\(totalMarkups)")

        if iterations > 1 {
            runBenchmarkIterations(iterations: iterations, fileURL: output)
        }
        if saveIterations > 0 {
            runSaveCompatibilityBenchmark(iterations: saveIterations, fileURL: output)
        }
        if verifyCustomMarkupCompat {
            runCustomMarkupCompatibilityProbe()
        }
        print("done")
        return 0
    }

    private static func runLinkCompatibilityExport(sourceURL: URL, outputDirectory: URL?) -> Int {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            fputs("link_compat_export_missing_source path=\(sourceURL.path)\n", stderr)
            return 4
        }
        do {
            let outputs = try PDFAutoSheetLinkFitDestinationRewriter.exportCompatibilityVariants(
                for: sourceURL,
                outputDirectory: outputDirectory
            )
            print("link_compat_export_count=\(outputs.count)")
            for output in outputs {
                print("link_compat_export_file=\(output.path)")
            }
            return 0
        } catch {
            fputs("link_compat_export_failed error=\(error.localizedDescription)\n", stderr)
            return 5
        }
    }

    private static func runBenchmarkIterations(iterations: Int, fileURL: URL) {
        var loadDurationsMs: [Double] = []
        var markupScanDurationsMs: [Double] = []
        var textSearchDurationsMs: [Double] = []
        var refreshModelDurationsMs: [Double] = []
        var filteredModelDurationsMs: [Double] = []
        loadDurationsMs.reserveCapacity(iterations)
        markupScanDurationsMs.reserveCapacity(iterations)
        textSearchDurationsMs.reserveCapacity(iterations)
        refreshModelDurationsMs.reserveCapacity(iterations)
        filteredModelDurationsMs.reserveCapacity(iterations)

        for index in 1...iterations {
            let loadStart = CFAbsoluteTimeGetCurrent()
            guard let document = PDFDocument(url: fileURL) else {
                fputs("benchmark_failed_load_iteration=\(index)\n", stderr)
                break
            }
            loadDurationsMs.append((CFAbsoluteTimeGetCurrent() - loadStart) * 1000.0)

            let scanStart = CFAbsoluteTimeGetCurrent()
            var markups = 0
            for pageIndex in 0..<document.pageCount {
                markups += document.page(at: pageIndex)?.annotations.count ?? 0
            }
            markupScanDurationsMs.append((CFAbsoluteTimeGetCurrent() - scanStart) * 1000.0)

            let searchStart = CFAbsoluteTimeGetCurrent()
            let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            var cursor: PDFSelection?
            var textHits = 0
            while textHits < 600,
                  let match = document.findString("Stress", fromSelection: cursor, withOptions: options) {
                cursor = match
                textHits += 1
            }
            textSearchDurationsMs.append((CFAbsoluteTimeGetCurrent() - searchStart) * 1000.0)

            let refreshModelStart = CFAbsoluteTimeGetCurrent()
            let refreshModelResult = benchmarkRefreshModel(document: document, filter: nil, cap: 25_000)
            refreshModelDurationsMs.append((CFAbsoluteTimeGetCurrent() - refreshModelStart) * 1000.0)

            let filteredModelStart = CFAbsoluteTimeGetCurrent()
            let filteredModelResult = benchmarkRefreshModel(document: document, filter: "ink", cap: 25_000)
            filteredModelDurationsMs.append((CFAbsoluteTimeGetCurrent() - filteredModelStart) * 1000.0)
            print(
                "benchmark_iter=\(index) load_ms=\(format(loadDurationsMs.last)) annotation_scan_ms=\(format(markupScanDurationsMs.last)) text_search_ms=\(format(textSearchDurationsMs.last)) refresh_model_ms=\(format(refreshModelDurationsMs.last)) filtered_model_ms=\(format(filteredModelDurationsMs.last)) listed=\(refreshModelResult.listed) filtered_listed=\(filteredModelResult.listed) markups=\(markups) text_hits=\(textHits)"
            )
        }

        print("benchmark_summary iterations=\(iterations)")
        print(statsLine(label: "load_ms", values: loadDurationsMs))
        print(statsLine(label: "annotation_scan_ms", values: markupScanDurationsMs))
        print(statsLine(label: "text_search_ms", values: textSearchDurationsMs))
        print(statsLine(label: "refresh_model_ms", values: refreshModelDurationsMs))
        print(statsLine(label: "filtered_model_ms", values: filteredModelDurationsMs))
    }

    private static func benchmarkRefreshModel(document: PDFDocument, filter: String?, cap: Int) -> (listed: Int, totalMatching: Int) {
        var cache: [Int: [PDFAnnotation]] = [:]
        cache.reserveCapacity(document.pageCount)
        for pageIndex in 0..<document.pageCount {
            cache[pageIndex] = document.page(at: pageIndex)?.annotations ?? []
        }

        let loweredFilter = filter?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var listed = 0
        var totalMatching = 0

        for pageIndex in 0..<document.pageCount {
            guard let annotations = cache[pageIndex] else { continue }
            if loweredFilter.isEmpty {
                totalMatching += annotations.count
                if listed < cap {
                    listed += min(cap - listed, annotations.count)
                }
                continue
            }

            for annotation in annotations {
                let type = annotation.type ?? ""
                let contents = annotation.contents ?? ""
                let text = "\(type)\n\(contents)".lowercased()
                if text.contains(loweredFilter) {
                    totalMatching += 1
                    if listed < cap {
                        listed += 1
                    }
                }
            }
        }

        return (listed, totalMatching)
    }

    private static func statsLine(label: String, values: [Double]) -> String {
        guard !values.isEmpty else { return "\(label) no_data=1" }
        return "\(label) avg=\(format(values.reduce(0, +) / Double(values.count))) p50=\(format(percentile(values, 50))) p95=\(format(percentile(values, 95))) max=\(format(values.max()))"
    }

    private static func percentile(_ values: [Double], _ pct: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = (pct / 100.0) * Double(max(sorted.count - 1, 0))
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper {
            return sorted[lower]
        }
        let weight = position - Double(lower)
        return sorted[lower] * (1.0 - weight) + sorted[upper] * weight
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "0.00" }
        return String(format: "%.2f", value)
    }

    private static func runSaveCompatibilityBenchmark(iterations: Int, fileURL: URL) {
        print("save_benchmark_start iterations=\(iterations)")
        var writeDurationsMs: [Double] = []
        var reloadDurationsMs: [Double] = []
        writeDurationsMs.reserveCapacity(iterations)
        reloadDurationsMs.reserveCapacity(iterations)

        for index in 1...iterations {
            guard let document = PDFDocument(url: fileURL) else {
                fputs("save_benchmark_failed_load_iteration=\(index)\n", stderr)
                break
            }
            guard let firstPage = document.page(at: 0) else {
                fputs("save_benchmark_failed_no_pages_iteration=\(index)\n", stderr)
                break
            }

            let annotation = PDFAnnotation(
                bounds: NSRect(x: 24 + (index % 16) * 8, y: 24 + (index % 16) * 8, width: 72, height: 20),
                forType: .freeText,
                withProperties: nil
            )
            annotation.contents = "Save benchmark \(index)"
            annotation.font = NSFont.systemFont(ofSize: 10, weight: .regular)
            annotation.fontColor = .labelColor
            annotation.color = NSColor.systemYellow.withAlphaComponent(0.08)
            firstPage.addAnnotation(annotation)

            let writeStarted = CFAbsoluteTimeGetCurrent()
            let writeOK = document.write(to: fileURL, withOptions: nil)
            let writeMs = (CFAbsoluteTimeGetCurrent() - writeStarted) * 1000.0
            writeDurationsMs.append(writeMs)
            guard writeOK else {
                fputs("save_benchmark_failed_write_iteration=\(index)\n", stderr)
                break
            }

            let reloadStarted = CFAbsoluteTimeGetCurrent()
            guard let reloaded = PDFDocument(url: fileURL) else {
                fputs("save_benchmark_failed_reload_iteration=\(index)\n", stderr)
                break
            }
            let reloadMs = (CFAbsoluteTimeGetCurrent() - reloadStarted) * 1000.0
            reloadDurationsMs.append(reloadMs)

            let pageZeroAnnotations = reloaded.page(at: 0)?.annotations ?? []
            let annotationCount = pageZeroAnnotations.count
            let hasSavedMarker = pageZeroAnnotations.contains { ($0.contents ?? "").contains("Save benchmark \(index)") }
            print(
                "save_iter=\(index) write_ms=\(format(writeMs)) reload_ms=\(format(reloadMs)) page0_annotations=\(annotationCount) marker_present=\(hasSavedMarker ? 1 : 0)"
            )
        }

        print(statsLine(label: "save_write_ms", values: writeDurationsMs))
        print(statsLine(label: "save_reload_ms", values: reloadDurationsMs))
        print("save_benchmark_done")
    }

    private static func runCustomMarkupCompatibilityProbe() {
        print("custom_compat_probe_start")
        let probeURL = FileManager.default.temporaryDirectory.appendingPathComponent("drawbridge-custom-compat-\(UUID().uuidString).pdf")
        let sourceSnapshotURL = FileManager.default.temporaryDirectory.appendingPathComponent("drawbridge-custom-source-\(UUID().uuidString).pdf")
        let sourceImageURL = FileManager.default.temporaryDirectory.appendingPathComponent("drawbridge-custom-source-\(UUID().uuidString).png")

        defer {
            try? FileManager.default.removeItem(at: probeURL)
            try? FileManager.default.removeItem(at: sourceSnapshotURL)
            try? FileManager.default.removeItem(at: sourceImageURL)
        }

        guard let sourceSnapshotData = syntheticSnapshotPDFData(),
              (try? sourceSnapshotData.write(to: sourceSnapshotURL, options: .atomic)) != nil,
              let sourceImageData = syntheticMarkupImagePNGData(),
              (try? sourceImageData.write(to: sourceImageURL, options: .atomic)) != nil else {
            fputs("custom_compat_probe_failed_setup\n", stderr)
            return
        }

        let pageSize = NSSize(width: 700, height: 500)
        let baseImage = NSImage(size: pageSize)
        baseImage.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: pageSize)).fill()
        baseImage.unlockFocus()
        guard let page = PDFPage(image: baseImage) else {
            fputs("custom_compat_probe_failed_page\n", stderr)
            return
        }

        let document = PDFDocument()
        document.insert(page, at: 0)

        let snapshot = PDFSnapshotAnnotation(bounds: NSRect(x: 80, y: 300, width: 240, height: 120), snapshotURL: sourceSnapshotURL)
        snapshot.contents = PDFSnapshotAnnotation.contentsPrefix + sourceSnapshotURL.path
        page.addAnnotation(snapshot)

        let image = ImageMarkupAnnotation(bounds: NSRect(x: 380, y: 130, width: 180, height: 180), imageURL: sourceImageURL)
        image.contents = ImageMarkupAnnotation.contentsPrefix + sourceImageURL.path
        page.addAnnotation(image)

        guard document.write(to: probeURL, withOptions: nil),
              let reloaded = PDFDocument(url: probeURL),
              let reloadedPage = reloaded.page(at: 0) else {
            fputs("custom_compat_probe_failed_write_reload\n", stderr)
            return
        }

        let reloadedAnnotations = reloadedPage.annotations
        let hasCustomSubclassAfterReload = reloadedAnnotations.contains {
            ($0 is PDFSnapshotAnnotation) || ($0 is ImageMarkupAnnotation)
        }
        let renderedPixels = nonWhitePixelCount(
            image: reloadedPage.thumbnail(of: NSSize(width: 900, height: 640), for: .mediaBox)
        )
        let renderedVisible = renderedPixels > 1_000
        print(
            "custom_compat_probe_result annotations=\(reloadedAnnotations.count) custom_subclass=\(hasCustomSubclassAfterReload ? 1 : 0) nonwhite_pixels=\(renderedPixels) visible=\(renderedVisible ? 1 : 0)"
        )
        print("custom_compat_probe_done")
    }

    private static func syntheticSnapshotPDFData() -> Data? {
        let pageSize = NSSize(width: 320, height: 180)
        let image = NSImage(size: pageSize)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: pageSize)).fill()
        NSColor.black.setStroke()
        let frame = NSBezierPath(rect: NSRect(x: 8, y: 8, width: 304, height: 164))
        frame.lineWidth = 4
        frame.stroke()
        NSColor.systemRed.setStroke()
        let diag = NSBezierPath()
        diag.move(to: NSPoint(x: 12, y: 12))
        diag.line(to: NSPoint(x: 308, y: 168))
        diag.lineWidth = 6
        diag.stroke()
        image.unlockFocus()
        guard let page = PDFPage(image: image) else { return nil }
        let document = PDFDocument()
        document.insert(page, at: 0)
        return document.dataRepresentation()
    }

    private static func syntheticMarkupImagePNGData() -> Data? {
        let size = NSSize(width: 180, height: 180)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: NSRect(x: 20, y: 20, width: 140, height: 140)).fill()
        NSColor.white.setStroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: 45, y: 90))
        cross.line(to: NSPoint(x: 135, y: 90))
        cross.move(to: NSPoint(x: 90, y: 45))
        cross.line(to: NSPoint(x: 90, y: 135))
        cross.lineWidth = 10
        cross.stroke()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func nonWhitePixelCount(image: NSImage) -> Int {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return 0
        }
        let bytesPerRow = max(1, cg.bytesPerRow)
        let width = cg.width
        let height = cg.height
        if width <= 0 || height <= 0 {
            return 0
        }
        let channels = max(1, cg.bitsPerPixel / max(1, cg.bitsPerComponent))
        var count = 0
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let index = row + (x * channels)
                if channels >= 3 {
                    let r = Int(bytes[index])
                    let g = Int(bytes[index + 1])
                    let b = Int(bytes[index + 2])
                    if r < 248 || g < 248 || b < 248 {
                        count += 1
                    }
                } else {
                    let v = Int(bytes[index])
                    if v < 248 {
                        count += 1
                    }
                }
            }
        }
        return count
    }

    private static func generateSyntheticPDF(pageCount: Int, markupsPerPage: Int) -> PDFDocument {
        let document = PDFDocument()
        let pageSize = NSSize(width: 36.0 * 72.0, height: 24.0 * 72.0)

        for pageIndex in 0..<pageCount {
            let pageImage = NSImage(size: pageSize)
            pageImage.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: pageSize)).fill()
            pageImage.unlockFocus()

            guard let page = PDFPage(image: pageImage) else { continue }
            document.insert(page, at: pageIndex)

            for itemIndex in 0..<markupsPerPage {
                let x = CGFloat((itemIndex * 37) % 2400) + 40
                let y = CGFloat((itemIndex * 61) % 1500) + 40
                let w = CGFloat(40 + (itemIndex % 6) * 12)
                let h = CGFloat(20 + (itemIndex % 5) * 10)
                let bounds = NSRect(x: x, y: y, width: w, height: h)

                if itemIndex % 3 == 0 {
                    let annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
                    annotation.color = .systemRed
                    let border = PDFBorder()
                    border.lineWidth = 2
                    annotation.border = border
                    annotation.contents = "Stress Rectangle \(pageIndex)-\(itemIndex)"
                    page.addAnnotation(annotation)
                } else if itemIndex % 3 == 1 {
                    let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
                    annotation.contents = "Stress Text \(pageIndex)-\(itemIndex)"
                    annotation.font = NSFont.systemFont(ofSize: 10, weight: .regular)
                    annotation.fontColor = .labelColor
                    annotation.color = NSColor.systemYellow.withAlphaComponent(0.15)
                    page.addAnnotation(annotation)
                } else {
                    let path = NSBezierPath()
                    path.move(to: NSPoint(x: 2, y: 2))
                    path.line(to: NSPoint(x: bounds.width - 2, y: bounds.height - 2))
                    let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
                    annotation.color = .systemBlue
                    let border = PDFBorder()
                    border.lineWidth = 2
                    annotation.border = border
                    annotation.contents = "Stress Ink \(pageIndex)-\(itemIndex)"
                    annotation.add(path)
                    page.addAnnotation(annotation)
                }
            }
        }
        return document
    }

    private static func intValue(after flag: String, in arguments: [String]) -> Int? {
        guard let idx = arguments.firstIndex(of: flag), arguments.indices.contains(idx + 1) else {
            return nil
        }
        return Int(arguments[idx + 1])
    }

    private static func stringValue(after flag: String, in arguments: [String]) -> String? {
        guard let idx = arguments.firstIndex(of: flag), arguments.indices.contains(idx + 1) else {
            return nil
        }
        return arguments[idx + 1]
    }

    private static func outputURL(from arguments: [String]) -> URL? {
        guard let idx = arguments.firstIndex(of: "--out"), arguments.indices.contains(idx + 1) else {
            return nil
        }
        let path = arguments[idx + 1]
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
