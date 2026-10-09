import Foundation
import PDFKit

/// Original annotation slots are retained across saves, so undo can restore the
/// exact external annotation and its appearance rather than recreate it.
struct ImportedMarkupPlan: @unchecked Sendable {
    struct Change {
        let sourcePage: Int
        let page: Int
        let slot: Int
        let deleted: Bool
        let offset: CGPoint
        let originalBounds: CGRect
        let subtype: String
        let name: String?
    }
    let stamp: PDFMarkupSourceStamp
    let changes: [Change]
    var source: URL? { stamp.recoverySourceURL }
    func rebased(to stamp: PDFMarkupSourceStamp) -> ImportedMarkupPlan {
        ImportedMarkupPlan(stamp: stamp, changes: changes.map {
            Change(sourcePage: $0.page, page: $0.page, slot: $0.slot, deleted: $0.deleted, offset: $0.offset, originalBounds: $0.originalBounds, subtype: $0.subtype, name: $0.name)
        })
    }
}

@MainActor
final class ImportedMarkupState: NSObject {
    struct Entry {
        let annotation: PDFAnnotation
        let page: PDFPage
        let sourcePage: Int
        let slot: Int
        let bounds: CGRect
    }
    let entries: [Entry]
    let openingStamp: PDFMarkupSourceStamp?
    var touched: Set<ObjectIdentifier> = []
    init(document: PDFDocument) {
        openingStamp = document.documentURL.flatMap(PDFMarkupSourceStamp.capture)
        entries = (0..<document.pageCount).flatMap { index -> [Entry] in
            guard let page = document.page(at: index) else { return [] }
            return page.annotations.enumerated().compactMap { slot, annotation in
                guard Self.selectable(annotation) && !RectangleMarkupRecord.owns(annotation) else { return nil }
                return Entry(annotation: annotation, page: page, sourcePage: index, slot: slot, bounds: annotation.bounds)
            }
        }
    }
    static func selectable(_ annotation: PDFAnnotation) -> Bool {
        // Links, form widgets, popups, and AutoCAD SHX helper boxes are not markups.
        let flags = (annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/F")) as? NSNumber)?.intValue ?? 0
        return ["Square", "Circle", "Line", "FreeText", "Ink", "Polygon", "PolyLine", "Highlight", "Underline", "StrikeOut", "Squiggly", "Text", "Stamp", "Caret"].contains(annotation.type ?? "")
            && !annotation.isReadOnly && annotation.shouldDisplay && flags & (1 | 2 | 32 | 64 | 128 | 512) == 0
    }
    func touch(_ annotation: PDFAnnotation) { touched.insert(ObjectIdentifier(annotation)) }
    func plan(document: PDFDocument, stamp: PDFMarkupSourceStamp?) -> ImportedMarkupPlan? {
        guard let stamp = openingStamp ?? stamp, !touched.isEmpty else { return nil }
        let changes = entries.compactMap { entry -> ImportedMarkupPlan.Change? in
            guard touched.contains(ObjectIdentifier(entry.annotation)) else { return nil }
            let index = document.index(for: entry.page)
            guard index != NSNotFound else { return nil }
            return .init(sourcePage: entry.sourcePage, page: index, slot: entry.slot,
                         deleted: !entry.page.annotations.contains { $0 === entry.annotation },
                         offset: CGPoint(x: entry.annotation.bounds.minX - entry.bounds.minX,
                                         y: entry.annotation.bounds.minY - entry.bounds.minY), originalBounds: entry.bounds,
                         subtype: entry.annotation.type ?? "",
                         name: entry.annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NM")) as? String)
        }
        return changes.isEmpty ? nil : ImportedMarkupPlan(stamp: stamp, changes: changes)
    }
}
