import AppKit
import Foundation
import PDFKit

enum StressHarness {
    static func run(arguments: [String]) -> Int {
        let pages = max(1, intValue(after: "--pages", in: arguments) ?? 250)
        let markupsPerPage = max(1, intValue(after: "--markups-per-page", in: arguments) ?? 80)
        let iterations = max(1, intValue(after: "--iterations", in: arguments) ?? 1)
        let output = outputURL(from: arguments) ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Drawbridge-Stress.pdf")

        print("Drawbridge stress harness starting")
        print("pages=\(pages) markupsPerPage=\(markupsPerPage) iterations=\(iterations)")
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
        print("done")
        return 0
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

    private static func outputURL(from arguments: [String]) -> URL? {
        guard let idx = arguments.firstIndex(of: "--out"), arguments.indices.contains(idx + 1) else {
            return nil
        }
        let path = arguments[idx + 1]
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
