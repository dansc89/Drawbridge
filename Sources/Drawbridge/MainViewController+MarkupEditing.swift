import AppKit
import PDFKit

@MainActor
extension MainViewController {
    @objc func applySelectedMarkupsToPages() {
        // Compatibility entry point: annotation authoring is unavailable.
    }

    @objc func deleteSelectedMarkup() {
        // Compatibility entry point: annotation authoring is unavailable.
    }

    @objc func editSelectedMarkupText() {
        // Compatibility entry point: annotation authoring is unavailable.
    }

    func resolveFont(family: String, size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .regular)
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
        AnnotationStyleMutations.assignLineWidth(lineWidth, to: annotation)
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
        // Compatibility entry point: annotation authoring is unavailable.
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

}
