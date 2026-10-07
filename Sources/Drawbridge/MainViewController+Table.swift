import AppKit

extension MainViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView.identifier?.rawValue == "pagesTable" {
            return sidebarPageCount()
        }
        return markupItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView.identifier?.rawValue == "pagesTable" {
            guard let pageLabel = sidebarPageLabel(at: row),
                  let document = pdfView.document, let page = document.page(at: row) else { return nil }
            pageThumbnailCache.bind(document)
            let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("pageThumbnail"), owner: self) as? PageThumbnailCell
                ?? PageThumbnailCell(frame: .zero)
            cell.configure(page: page, number: row + 1, label: pageLabel, current: isSidebarCurrentPage(row))
            pageThumbnailCache.request(cell)
            return cell
        }

        guard row >= 0, row < markupItems.count else { return nil }
        let item = markupItems[row]
        let columnId = tableColumn?.identifier.rawValue ?? ""

        let text: String
        if columnId == "page" {
            text = displayPageLabel(forPageIndex: item.pageIndex)
        } else if columnId == "type" {
            if isExtraneousEmbeddedPDFAnnotation(item.annotation),
               let author = item.annotation.userName,
               !author.isEmpty {
                text = author
            } else {
                text = item.annotation.type ?? "Unknown"
            }
        } else if columnId == "author" {
            text = item.annotation.userName?.isEmpty == false ? item.annotation.userName! : "(No author)"
        } else {
            text = item.annotation.contents?.isEmpty == false ? item.annotation.contents! : "(No text)"
        }

        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = .byTruncatingTail
        cell.font = NSFont.systemFont(ofSize: 12)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        if tableView.identifier?.rawValue == "pagesTable" {
            return
        }
        updateSelectionOverlay()
        updateStatusBar()
    }
}
