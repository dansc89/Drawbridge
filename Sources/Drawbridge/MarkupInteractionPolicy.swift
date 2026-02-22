import Foundation

struct MarkupInteractionPolicy {
    static func shouldDragGroupedPasteSelection<AnnotationID: Hashable, PageID: Hashable>(
        selectedAnnotationIDs: Set<AnnotationID>,
        anchorAnnotationID: AnnotationID,
        currentPageID: PageID,
        groupedPastePageID: PageID?,
        groupedPasteAnnotationIDs: Set<AnnotationID>
    ) -> Bool {
        guard selectedAnnotationIDs.count > 1 else { return false }
        guard groupedPastePageID == currentPageID else { return false }
        guard groupedPasteAnnotationIDs.contains(anchorAnnotationID) else { return false }
        return selectedAnnotationIDs.isSubset(of: groupedPasteAnnotationIDs)
    }
}

struct EscapePressTracker {
    var lastPressAt: Date = .distantPast
    let doublePressInterval: TimeInterval

    init(doublePressInterval: TimeInterval = 0.65) {
        self.doublePressInterval = max(0.05, doublePressInterval)
    }

    mutating func registerPress(at now: Date = Date()) -> Bool {
        if now.timeIntervalSince(lastPressAt) <= doublePressInterval {
            lastPressAt = .distantPast
            return true
        }
        lastPressAt = now
        return false
    }

    mutating func reset() {
        lastPressAt = .distantPast
    }
}

