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
    let fontName: String?
    let fontSize: CGFloat?
    let lineWidth: CGFloat
    let renderOpacity: CGFloat?
    let renderTintColor: NSColor?
    let renderTintStrength: CGFloat?
    let tintBlendStyleRawValue: Int?
    let lineworkOnlyTint: Bool?
    let snapshotLayerName: String?
}

struct MarkupIndexSnapshot: Codable {
    let documentKey: String
    let pageCount: Int
    let totalAnnotations: Int
    let perPageCounts: [Int: Int]
    let generatedAt: Date
}

struct SidecarAnnotationRecord: Codable, Sendable {
    let pageIndex: Int
    let archivedAnnotation: Data
    let lineWidth: CGFloat?
}

struct PageScaleLock: Codable, Equatable, Sendable {
    let unit: String
    let scale: Double
}

struct SidecarBookmarkRecord: Codable, Equatable, Sendable {
    let label: String?
    let pageIndex: Int?
    let destinationX: Double?
    let destinationY: Double?
    let children: [SidecarBookmarkRecord]
}

struct SidecarSnapshot: Codable, Sendable {
    let sourcePDFPath: String
    let pageCount: Int
    let annotations: [SidecarAnnotationRecord]
    let pageScaleLocks: [Int: PageScaleLock]?
    let pageLabels: [Int: String]?
    let bookmarks: [SidecarBookmarkRecord]?
    let savedAt: Date
}
