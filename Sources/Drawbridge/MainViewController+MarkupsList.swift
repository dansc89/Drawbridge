import AppKit
import PDFKit

@MainActor
enum MarkupListPresentation {
    static func includes(_ annotation: PDFAnnotation) -> Bool {
        guard !["Link", "Widget", "Popup"].contains(annotation.type ?? "") else { return false }
        let author = (annotation.userName ?? "").lowercased()
        return !author.contains("autocad shx")
    }
    static func author(_ annotation: PDFAnnotation) -> String {
        let name = annotation.userName ?? ""
        return name.hasPrefix(RectangleMarkupRecord.prefix) ? MarkupAuthorPreference.currentName : name.isEmpty ? "Unknown" : name
    }
    static func typeName(_ annotation: PDFAnnotation) -> String {
        switch annotation.type {
        case "Square": return "Rectangle"
        case "Circle": return "Ellipse"
        case "FreeText": return "Text Box"
        case "Line": return annotation.endLineStyle == .openArrow ? "Arrow" : "Line"
        case "Ink": return RectangleMarkupRecord.vertices(annotation).isEmpty ? "Pen" : "Polyline"
        default: return annotation.type ?? "Markup"
        }
    }
}

@MainActor
extension MainViewController {
    func configureMarkupsPanel() {
        markupsPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(markupsPanel)
        let height = markupsPanel.heightAnchor.constraint(equalToConstant: 0)
        markupsPanelHeight = height
        NSLayoutConstraint.activate([
            markupsPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            markupsPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            markupsPanel.bottomAnchor.constraint(equalTo: statusBar.topAnchor), height
        ])
        markupsPanel.isHidden = true
        let title = NSTextField(labelWithString: "Markups List")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        markupsCountLabel.font = .systemFont(ofSize: 11)
        markupsCountLabel.textColor = .secondaryLabelColor
        markupsSearchField.placeholderString = "Search markups or authors"
        markupsSearchField.target = self; markupsSearchField.action = #selector(filterListedMarkups(_:))
        markupsSearchField.sendsSearchStringImmediately = true
        markupsSearchField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        markupsDeleteButton.target = self; markupsDeleteButton.action = #selector(deleteListedMarkups(_:))
        markupsDeleteButton.bezelStyle = .rounded; markupsDeleteButton.controlSize = .small
        let close = NSButton(title: "Hide", target: self, action: #selector(commandToggleMarkupsList(_:)))
        close.bezelStyle = .rounded; close.controlSize = .small
        let header = NSStackView(views: [title, markupsCountLabel, markupsSearchField, markupsDeleteButton, close])
        header.spacing = 12; header.alignment = .centerY; header.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.translatesAutoresizingMaskIntoConstraints = false
        markupsTable.identifier = NSUserInterfaceItemIdentifier("markupsList")
        markupsTable.delegate = self; markupsTable.dataSource = self
        markupsTable.allowsMultipleSelection = true
        markupsTable.usesAlternatingRowBackgroundColors = true
        markupsTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        markupsTable.rowHeight = 24
        for (id, name, width) in [("type", "Markup", 130.0), ("page", "Page", 220.0), ("contents", "Comment", 320.0), ("author", "Author", 220.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = name; column.width = width; column.minWidth = 80
            markupsTable.addTableColumn(column)
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Delete Selected Markups", action: #selector(deleteListedMarkups(_:)), keyEquivalent: "").target = self
        markupsTable.menu = menu
        scroll.documentView = markupsTable
        markupsPanel.addSubview(header); markupsPanel.addSubview(scroll)
        let bottom = scroll.bottomAnchor.constraint(equalTo: markupsPanel.bottomAnchor)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: markupsPanel.leadingAnchor, constant: 12),
            header.topAnchor.constraint(equalTo: markupsPanel.topAnchor, constant: 6),
            header.trailingAnchor.constraint(lessThanOrEqualTo: markupsPanel.trailingAnchor, constant: -12),
            header.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: markupsPanel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: markupsPanel.trailingAnchor),
            bottom
        ])
    }
    @objc func commandToggleMarkupsList(_ sender: Any?) {
        isMarkupsPanelVisible.toggle()
        markupsPanel.isHidden = !isMarkupsPanelVisible
        markupsPanelHeight?.constant = isMarkupsPanelVisible ? 200 : 0
        markupsToggleButton.state = isMarkupsPanelVisible ? .on : .off
        if isMarkupsPanelVisible { scheduleMarkupsRefresh(selecting: pdfView.rectangleMarkup.selected) }
    }
    @objc func filterListedMarkups(_ sender: Any?) {
        markupFilterText = markupsSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        scheduleMarkupsRefresh(selecting: nil)
    }
    func jumpToSelectedMarkup() {
        guard isMarkupsPanelVisible, !isPDFProcessingBusy, markupsTable.numberOfSelectedRows == 1,
              let item = currentSelectedMarkupItem(), let page = item.annotation.page,
              page.document === pdfView.document else { return }
        pdfView.rectangleMarkup.selectFromList(item.annotation)
        // A queued edit/filter refresh must not restore an older selection.
        if pendingMarkupsRefreshWorkItem != nil {
            scheduleMarkupsRefresh(selecting: item.annotation)
        }
        pdfView.revealMarkup(item.annotation)
    }
    @objc func deleteListedMarkups(_ sender: Any?) {
        guard !isPDFProcessingBusy else { return }
        let items = markupsTable.selectedRowIndexes.compactMap { row -> MarkupItem? in
            markupItems.indices.contains(row) ? markupItems[row] : nil
        }
        let eligible = items.filter { !$0.annotation.isReadOnly && (RectangleMarkupRecord.owns($0.annotation) || ImportedMarkupState.selectable($0.annotation)) }
        guard !eligible.isEmpty else { return }
        let session = pdfView.rectangleMarkup
        session.undo.beginUndoGrouping()
        for item in eligible { session.selectFromList(item.annotation); session.deleteSelected() }
        session.undo.setActionName("Delete Markups"); session.undo.endUndoGrouping()
        scheduleMarkupsRefresh(selecting: nil)
    }
}
