import AppKit
import PDFKit

/// A retained editing document, not a detached same-document split presentation.
/// Keeping the session alive also keeps unsaved annotations and undo targets alive
/// when its canvas is reused for a third tab.
@MainActor
struct SplitDocumentSession {
    let url: URL
    let document: PDFDocument
    let persistence: DocumentPersistenceCoordinator
    let markup: RectangleMarkupController
    let viewport: MarkupPDFView.TabViewState?
    let labels: [Int: String]
    let suppressedLabels: Set<Int>
    let scaleLocks: [Int: PageScaleLock]
    let bookmarkLabels: [String: String]
    let lastExplicitScaleSetDocumentID: ObjectIdentifier?
    let lastExplicitScaleSetPageIndex: Int
    let explicitScaleSetDocumentID: ObjectIdentifier?
    let explicitScaleSetPageIndexes: Set<Int>
    let pendingScaleReminderSuppressionDocumentID: ObjectIdentifier?
    let pendingScaleReminderSuppressionPageIndex: Int
    let pendingScaleReminderSuppressionOneShot: Bool
    let dirty: Bool
    let changeVersion: Int
    let autosavedVersion: Int
    let lastEdit: Date
    let lastInteraction: Date
    let promptedForSaveCopy: Bool
    let searchQuery: String
}
