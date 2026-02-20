import AppKit
import PDFKit

enum StressHarness {
    static func run(arguments: [String]) -> Int {
        let pages = max(1, intValue(after: "--pages", in: arguments) ?? 250)
        let markupsPerPage = max(1, intValue(after: "--markups-per-page", in: arguments) ?? 80)
        let output = outputURL(from: arguments) ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Drawbridge-Stress.pdf")

        print("Drawbridge stress harness starting")
        print("pages=\(pages) markupsPerPage=\(markupsPerPage)")
        print("output=\(output.path)")

        let started = CFAbsoluteTimeGetCurrent()
        let generated = generateSyntheticPDF(pageCount: pages, markupsPerPage: markupsPerPage)
        let generationMs = Int(((CFAbsoluteTimeGetCurrent() - started) * 1000.0).rounded())
        print("generate_ms=\(generationMs)")

        guard generated.write(to: output) else {
            fputs("failed_to_write_pdf\n", stderr)
            return 2
        }

        let loadStart = CFAbsoluteTimeGetCurrent()
        guard let loaded = PDFDocument(url: output) else {
            fputs("failed_to_load_written_pdf\n", stderr)
            return 3
        }
        var totalMarkups = 0
        for pageIndex in 0..<loaded.pageCount {
            totalMarkups += loaded.page(at: pageIndex)?.annotations.count ?? 0
        }
        let loadMs = Int(((CFAbsoluteTimeGetCurrent() - loadStart) * 1000.0).rounded())
        print("load_scan_ms=\(loadMs)")
        print("total_markups=\(totalMarkups)")
        print("done")
        return 0
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

