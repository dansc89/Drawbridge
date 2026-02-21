import AppKit
import PDFKit
import UniformTypeIdentifiers

struct MarkupItem {
    let pageIndex: Int
    let annotation: PDFAnnotation
}

struct AnnotationSnapshot {
    let bounds: NSRect
    let contents: String?
    let color: NSColor
    let interiorColor: NSColor?
    let fontColor: NSColor?
    let lineWidth: CGFloat
}

struct MarkupIndexSnapshot: Codable {
    let documentKey: String
    let pageCount: Int
    let totalAnnotations: Int
    let perPageCounts: [Int: Int]
    let generatedAt: Date
}

struct SidecarAnnotationRecord: Codable {
    let pageIndex: Int
    let archivedAnnotation: Data
    let lineWidth: CGFloat?
}

struct SidecarSnapshot: Codable {
    let sourcePDFPath: String
    let pageCount: Int
    let annotations: [SidecarAnnotationRecord]
    let savedAt: Date
}
