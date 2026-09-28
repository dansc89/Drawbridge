import AppKit

/// Editable review of every generated bookmark before replacing the document outline.
@MainActor
final class BookmarkReviewView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    struct Row {
        var number: String
        var title: String
        let note: String
    }
    private(set) var rows: [Row]
    private let table = NSTableView()

    init(rows: [Row]) {
        self.rows = rows
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 360))
        hasVerticalScroller = true
        hasHorizontalScroller = true
        borderType = .bezelBorder
        for (name, width, editable) in [("Page", 45.0, false), ("Sheet number", 110, true), ("Sheet title", 280, true), ("Review notes", 430, false)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            column.title = name
            column.width = width
            column.isEditable = editable
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        documentView = table
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        switch tableColumn?.identifier.rawValue {
        case "Page": return row + 1
        case "Sheet number": return rows[row].number
        case "Sheet title": return rows[row].title
        default: return rows[row].note
        }
    }

    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard let text = object as? String else { return }
        switch tableColumn?.identifier.rawValue {
        case "Sheet number": rows[row].number = PDFBookmarkExtractor.clean(text)
        case "Sheet title": rows[row].title = PDFBookmarkExtractor.clean(text)
        default: break
        }
    }

    func finishEditing() { window?.makeFirstResponder(nil) }
}
