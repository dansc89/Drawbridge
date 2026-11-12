import Foundation
import PDFKit

enum SharedReviewPDFExport {
    static func write(basePDF: Data, records: [RectangleMarkupRecord], to destination: URL) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Source.pdf")
        try basePDF.write(to: source)
        guard let baseDocument = PDFDocument(url: source) else {
            throw SharedReviewError("The original Review PDF could not be opened.")
        }
        let labels = Dictionary(uniqueKeysWithValues: (0..<baseDocument.pageCount).compactMap { index in
            baseDocument.page(at: index)?.label.map { (index, $0) }
        })
        guard PDFRectangleWriter.write(document: baseDocument, source: source, destination: destination,
                                       pageLabels: labels, records: records) else {
            throw SharedReviewError("The PDF and its markups could not be exported.")
        }
    }
}
