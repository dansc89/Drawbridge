import AppKit
import PDFKit

@MainActor
extension MainViewController {
    @objc func deleteSelectedMarkup() {
        let selectedRows = markupsTable.selectedRowIndexes
        var annotationsToDelete: [(page: PDFPage, annotation: PDFAnnotation)] = []
        var seen = Set<ObjectIdentifier>()

        if !selectedRows.isEmpty {
            for row in selectedRows.sorted(by: >) {
                guard row >= 0, row < markupItems.count else { continue }
                let item = markupItems[row]
                guard let page = pdfView.document?.page(at: item.pageIndex) else { continue }

                let primaryID = ObjectIdentifier(item.annotation)
                if seen.insert(primaryID).inserted {
                    annotationsToDelete.append((page: page, annotation: item.annotation))
                }

                for sibling in relatedCalloutAnnotations(for: item.annotation, on: page) where sibling !== item.annotation {
                    let siblingID = ObjectIdentifier(sibling)
                    if seen.insert(siblingID).inserted {
                        annotationsToDelete.append((page: page, annotation: sibling))
                    }
                }
            }
        } else if let direct = lastDirectlySelectedAnnotation, let page = direct.page {
            annotationsToDelete.append((page: page, annotation: direct))
        } else {
            NSSound.beep()
            return
        }

        for entry in annotationsToDelete {
            registerAnnotationPresenceUndo(page: entry.page, annotation: entry.annotation, shouldExist: true, actionName: "Delete Markup")
            entry.page.removeAnnotation(entry.annotation)
            markPageMarkupCacheDirty(entry.page)
        }
        lastDirectlySelectedAnnotation = nil
        commitMarkupMutation(selecting: nil, forceImmediateRefresh: true)
    }

    @objc func editSelectedMarkupText() {
        let row = markupsTable.selectedRow
        guard row >= 0, row < markupItems.count else {
            NSSound.beep()
            return
        }

        let item = markupItems[row]
        let alert = NSAlert()
        alert.messageText = "Edit Markup Text"
        alert.informativeText = "Update contents for this markup."
        alert.alertStyle = .informational

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = item.annotation.contents ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let before = snapshot(for: item.annotation)
        item.annotation.contents = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        markPageMarkupCacheDirty(item.annotation.page)
        registerAnnotationStateUndo(annotation: item.annotation, previous: before, actionName: "Edit Markup Text")
        commitMarkupMutation(selecting: item.annotation)
    }

    private func activeUndoManager() -> UndoManager? {
        view.window?.undoManager ?? undoManager
    }

    func snapshot(for annotation: PDFAnnotation) -> AnnotationSnapshot {
        let vectorSnapshot = annotation as? PDFSnapshotAnnotation
        return AnnotationSnapshot(
            bounds: annotation.bounds,
            contents: annotation.contents,
            color: annotation.color,
            interiorColor: annotation.interiorColor,
            fontColor: annotation.fontColor,
            fontName: annotation.font?.fontName,
            fontSize: annotation.font?.pointSize,
            lineWidth: resolvedLineWidth(for: annotation),
            renderOpacity: vectorSnapshot?.renderOpacity,
            renderTintColor: vectorSnapshot?.renderTintColor,
            renderTintStrength: vectorSnapshot?.renderTintStrength,
            tintBlendStyleRawValue: vectorSnapshot?.tintBlendStyle.rawValue,
            lineworkOnlyTint: vectorSnapshot?.lineworkOnlyTint,
            snapshotLayerName: vectorSnapshot?.snapshotLayerName
        )
    }

    private func apply(snapshot: AnnotationSnapshot, to annotation: PDFAnnotation) {
        annotation.bounds = snapshot.bounds
        annotation.contents = snapshot.contents
        annotation.color = snapshot.color
        annotation.interiorColor = snapshot.interiorColor
        annotation.fontColor = snapshot.fontColor
        if let fontName = snapshot.fontName, let fontSize = snapshot.fontSize {
            annotation.font = resolveFont(family: fontName, size: fontSize)
        }
        assignLineWidth(snapshot.lineWidth, to: annotation)
        if let vectorSnapshot = annotation as? PDFSnapshotAnnotation {
            vectorSnapshot.renderOpacity = snapshot.renderOpacity ?? vectorSnapshot.renderOpacity
            vectorSnapshot.renderTintColor = snapshot.renderTintColor
            vectorSnapshot.renderTintStrength = snapshot.renderTintStrength ?? vectorSnapshot.renderTintStrength
            if let raw = snapshot.tintBlendStyleRawValue,
               let style = PDFSnapshotAnnotation.TintBlendStyle(rawValue: raw) {
                vectorSnapshot.tintBlendStyle = style
            }
            if let lineworkOnly = snapshot.lineworkOnlyTint {
                vectorSnapshot.lineworkOnlyTint = lineworkOnly
            }
            vectorSnapshot.snapshotLayerName = snapshot.snapshotLayerName
        }
    }

    func resolvedLineWidth(for annotation: PDFAnnotation) -> CGFloat {
        let annotationType = (annotation.type ?? "").lowercased()
        if annotationType.contains("ink"),
           let paths = annotation.paths,
           let maxPathWidth = paths.map(\.lineWidth).max(),
           maxPathWidth > 0 {
            return maxPathWidth
        }
        if let borderWidth = annotation.border?.lineWidth, borderWidth > 0 {
            return borderWidth
        }
        return 1.0
    }

    func assignLineWidth(_ lineWidth: CGFloat, to annotation: PDFAnnotation) {
        let normalized = max(0.0, lineWidth)
        let border = annotation.border ?? PDFBorder()
        border.lineWidth = normalized
        annotation.border = border
        let annotationType = (annotation.type ?? "").lowercased()
        if annotationType.contains("ink"),
           let paths = annotation.paths {
            for path in paths {
                path.lineWidth = normalized
            }
        }
    }

    func registerAnnotationStateUndo(annotation: PDFAnnotation, previous: AnnotationSnapshot, actionName: String) {
        guard let undo = activeUndoManager() else { return }
        undo.registerUndo(withTarget: self) { target in
            let current = target.snapshot(for: annotation)
            target.apply(snapshot: previous, to: annotation)
            target.markPageMarkupCacheDirty(annotation.page)
            target.commitMarkupMutation(selecting: annotation)
            target.registerAnnotationStateUndo(annotation: annotation, previous: current, actionName: actionName)
        }
        undo.setActionName(actionName)
    }

    func registerAnnotationPresenceUndo(page: PDFPage, annotation: PDFAnnotation, shouldExist: Bool, actionName: String) {
        guard let undo = activeUndoManager() else { return }
        undo.registerUndo(withTarget: self) { target in
            if shouldExist {
                page.addAnnotation(annotation)
            } else {
                page.removeAnnotation(annotation)
            }
            target.markPageMarkupCacheDirty(page)
            target.commitMarkupMutation(selecting: shouldExist ? annotation : nil)
            target.registerAnnotationPresenceUndo(page: page, annotation: annotation, shouldExist: !shouldExist, actionName: actionName)
        }
        undo.setActionName(actionName)
    }

    func reorderSelectedMarkups(_ action: AnnotationReorderAction) {
        guard let document = pdfView.document else {
            NSSound.beep()
            return
        }
        let selectedItems = currentSelectedMarkupItems()
        guard !selectedItems.isEmpty else {
            NSSound.beep()
            return
        }

        var groupedByPage: [ObjectIdentifier: (page: PDFPage, ids: Set<ObjectIdentifier>)] = [:]
        for item in selectedItems {
            guard let page = document.page(at: item.pageIndex) else { continue }
            let pageID = ObjectIdentifier(page)
            if groupedByPage[pageID] == nil {
                groupedByPage[pageID] = (page, [])
            }
            groupedByPage[pageID]?.ids.insert(ObjectIdentifier(item.annotation))
            for sibling in relatedCalloutAnnotations(for: item.annotation, on: page) {
                groupedByPage[pageID]?.ids.insert(ObjectIdentifier(sibling))
            }
        }

        var changedAny = false
        var firstSelected: PDFAnnotation?
        for (_, group) in groupedByPage {
            let page = group.page
            let before = page.annotations
            let after = reorderedAnnotations(before, selectedIDs: group.ids, action: action)
            guard !before.elementsEqual(after, by: { $0 === $1 }) else { continue }
            applyAnnotationOrder(after, on: page)
            registerAnnotationOrderUndo(page: page, before: before, after: after, actionName: action.undoTitle)
            markPageMarkupCacheDirty(page)
            changedAny = true
            if firstSelected == nil {
                firstSelected = after.first(where: { group.ids.contains(ObjectIdentifier($0)) })
            }
        }

        guard changedAny else {
            NSSound.beep()
            return
        }
        commitMarkupMutation(selecting: firstSelected ?? currentSelectedAnnotation())
    }

    private func reorderedAnnotations(_ annotations: [PDFAnnotation], selectedIDs: Set<ObjectIdentifier>, action: AnnotationReorderAction) -> [PDFAnnotation] {
        guard !annotations.isEmpty, !selectedIDs.isEmpty else { return annotations }
        let isSelected: (PDFAnnotation) -> Bool = { selectedIDs.contains(ObjectIdentifier($0)) }
        switch action {
        case .bringToFront:
            let others = annotations.filter { !isSelected($0) }
            let selected = annotations.filter(isSelected)
            return others + selected
        case .sendToBack:
            let selected = annotations.filter(isSelected)
            let others = annotations.filter { !isSelected($0) }
            return selected + others
        case .bringForward:
            var ordered = annotations
            guard ordered.count > 1 else { return ordered }
            for i in stride(from: ordered.count - 2, through: 0, by: -1) {
                if isSelected(ordered[i]) && !isSelected(ordered[i + 1]) {
                    ordered.swapAt(i, i + 1)
                }
            }
            return ordered
        case .sendBackward:
            var ordered = annotations
            guard ordered.count > 1 else { return ordered }
            for i in 1..<ordered.count {
                if isSelected(ordered[i]) && !isSelected(ordered[i - 1]) {
                    ordered.swapAt(i - 1, i)
                }
            }
            return ordered
        }
    }

    private func applyAnnotationOrder(_ ordered: [PDFAnnotation], on page: PDFPage) {
        for existing in page.annotations {
            page.removeAnnotation(existing)
        }
        for annotation in ordered {
            page.addAnnotation(annotation)
        }
    }

    private func registerAnnotationOrderUndo(page: PDFPage, before: [PDFAnnotation], after: [PDFAnnotation], actionName: String) {
        guard let undo = activeUndoManager() else { return }
        undo.registerUndo(withTarget: self) { target in
            target.applyAnnotationOrder(before, on: page)
            target.markPageMarkupCacheDirty(page)
            target.commitMarkupMutation(selecting: before.first)
            target.registerAnnotationOrderUndo(page: page, before: after, after: before, actionName: actionName)
        }
        undo.setActionName(actionName)
    }


    func selectMarkupFromPageClick(page: PDFPage, annotation: PDFAnnotation) {
        lastDirectlySelectedAnnotation = annotation
        guard let document = pdfView.document else { return }
        let pageIndex = document.index(for: page)
        if pageIndex < 0 {
            NSSound.beep()
            return
        }

        if !markupItems.contains(where: { $0.pageIndex == pageIndex && $0.annotation === annotation }) {
            performRefreshMarkups(selecting: annotation)
        }
        let related = Set(relatedCalloutAnnotations(for: annotation, on: page).map(ObjectIdentifier.init))
        let relatedRows = IndexSet(markupItems.enumerated().compactMap { idx, item in
            guard item.pageIndex == pageIndex else { return nil }
            return related.contains(ObjectIdentifier(item.annotation)) ? idx : nil
        })
        if !relatedRows.isEmpty {
            applyMarkupTableSelectionRows(relatedRows)
            return
        }

        let targetRow = markupItems.firstIndex(where: { $0.pageIndex == pageIndex && $0.annotation === annotation })
            ?? nearestMarkupRow(to: annotation.bounds, onPageIndex: pageIndex)
        if let row = targetRow {
            applyMarkupTableSelectionRows(IndexSet(integer: row))
            return
        }
        // Keep the clicked annotation selected even when the table is filtered/capped and has no matching row.
        clearMarkupTableSelectionUI()
    }

    private func nearestMarkupRow(to bounds: NSRect, onPageIndex pageIndex: Int) -> Int? {
        var bestRow: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        let targetCenter = NSPoint(x: bounds.midX, y: bounds.midY)
        for (idx, item) in markupItems.enumerated() where item.pageIndex == pageIndex {
            let b = item.annotation.bounds
            let center = NSPoint(x: b.midX, y: b.midY)
            let d = hypot(center.x - targetCenter.x, center.y - targetCenter.y)
            if d < bestDistance {
                bestDistance = d
                bestRow = idx
            }
        }
        return bestRow
    }

    func currentSelectedMarkupItem() -> MarkupItem? {
        currentSelectedMarkupItems().first
    }

    func currentSelectedMarkupItems() -> [MarkupItem] {
        var selectedFromTable: [MarkupItem] = []
        selectedFromTable.reserveCapacity(markupsTable.numberOfSelectedRows)
        for row in markupsTable.selectedRowIndexes {
            guard row >= 0, row < markupItems.count else { continue }
            selectedFromTable.append(markupItems[row])
        }
        if !selectedFromTable.isEmpty {
            return selectedFromTable
        }
        guard let direct = lastDirectlySelectedAnnotation,
              let page = direct.page,
              let document = pdfView.document else {
            return []
        }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return [] }
        return [MarkupItem(pageIndex: pageIndex, annotation: direct)]
    }

    func relatedCalloutAnnotations(for annotation: PDFAnnotation, on page: PDFPage) -> [PDFAnnotation] {
        if let userName = annotation.userName {
            let sameUser = page.annotations.filter { $0.userName == userName }
            if sameUser.count > 1 {
                return sameUser
            }
        }
        if let groupID = pdfView.calloutGroupID(for: annotation) {
            let grouped = page.annotations.filter { pdfView.calloutGroupID(for: $0) == groupID }
            return grouped.isEmpty ? [annotation] : grouped
        }

        let annotationType = (annotation.type ?? "").lowercased()
        let contents = (annotation.contents ?? "").lowercased()
        let isLeader = contents.contains("callout leader")
        let isFreeText = annotationType.contains("free") && annotationType.contains("text")
        guard isLeader || isFreeText else { return [annotation] }

        func centerDistance(_ a: NSRect, _ b: NSRect) -> CGFloat {
            let ac = NSPoint(x: a.midX, y: a.midY)
            let bc = NSPoint(x: b.midX, y: b.midY)
            return hypot(ac.x - bc.x, ac.y - bc.y)
        }

        if isLeader {
            let searchRect = annotation.bounds.insetBy(dx: -30, dy: -30)
            let partner = page.annotations
                .filter { candidate in
                    let type = (candidate.type ?? "").lowercased()
                    guard type.contains("free") && type.contains("text") else { return false }
                    let center = NSPoint(x: candidate.bounds.midX, y: candidate.bounds.midY)
                    return candidate.bounds.intersects(searchRect) || searchRect.contains(center)
                }
                .min(by: { centerDistance($0.bounds, annotation.bounds) < centerDistance($1.bounds, annotation.bounds) })
            if let partner {
                return [annotation, partner]
            }
            return [annotation]
        }

        // For ungrouped free-text markups, avoid proximity auto-linking to nearby callouts.
        // This prevents normal T textboxes from accidentally dragging adjacent Q leaders.
        return [annotation]
    }
}
