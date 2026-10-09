import AppKit
import PDFKit

@MainActor
final class PageThumbnailTableView: NSTableView {
    override func menu(for event: NSEvent) -> NSMenu? {
        selectContextRow(in: self, event: event)
        return super.menu(for: event)
    }

    override func layout() {
        super.layout()
        guard let scrollView = enclosingScrollView, let column = tableColumns.first else { return }
        let width = max(80, scrollView.contentView.bounds.width - intercellSpacing.width)
        if abs(column.width - width) > 0.5 { column.width = width }
    }
}

@MainActor
final class PageThumbnailCell: NSTableCellView {
    weak var representedPage: PDFPage?
    let preview = NSImageView()
    let caption = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("pageThumbnail")
        autoresizingMask = [.width]
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 3
        caption.font = .systemFont(ofSize: 11)
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingTail
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for child in [preview, caption] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            preview.centerXAnchor.constraint(equalTo: centerXAnchor),
            preview.widthAnchor.constraint(equalTo: widthAnchor, constant: -24),
            preview.heightAnchor.constraint(equalToConstant: 126),
            caption.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 6),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            caption.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(page: PDFPage, number: Int, label: String, current: Bool) {
        if representedPage !== page { preview.image = nil }
        representedPage = page
        caption.stringValue = "\(number) · \(label)"
        caption.textColor = current ? .controlAccentColor : .labelColor
        caption.font = .systemFont(ofSize: 11, weight: current ? .semibold : .regular)
        preview.layer?.borderWidth = current ? 2 : 0
        preview.layer?.borderColor = NSColor.controlAccentColor.cgColor
        toolTip = "Page \(number): \(label)"
        setAccessibilityLabel(toolTip)
    }
}

/// PDFKit rendering stays on the main thread, serialized with annotation edits.
/// Only cells currently on screen are rendered; a bounded cache serves revisits.
@MainActor
final class PageThumbnailCache {
    private weak var document: PDFDocument?
    private let images = NSCache<PDFPage, NSImage>()
    private var pending: [WeakCell] = []
    private var scheduled = false
    private var generation = 0
    private struct WeakCell { weak var cell: PageThumbnailCell? }
    private(set) var renderedCount = 0

    init() { images.countLimit = 48; images.totalCostLimit = 24 * 1024 * 1024 }

    func bind(_ document: PDFDocument?) {
        guard self.document !== document else { return }
        self.document = document
        images.removeAllObjects()
        pending.removeAll()
        generation += 1
        renderedCount = 0
    }

    func invalidate(_ page: PDFPage?) {
        if let page { images.removeObject(forKey: page) }
        else { images.removeAllObjects() }
    }

    func request(_ cell: PageThumbnailCell) {
        guard let page = cell.representedPage else { return }
        if let image = images.object(forKey: page) { cell.preview.image = image; return }
        if !pending.contains(where: { $0.cell === cell }) { pending.append(WeakCell(cell: cell)) }
        schedule()
    }

    private func schedule() {
        guard !scheduled, !pending.isEmpty else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.renderNext()
        }
    }

    private func renderNext() {
        guard let document else { pending.removeAll(); return }
        while !pending.isEmpty {
            let item = pending.removeFirst()
            guard let cell = item.cell, cell.window != nil, !cell.visibleRect.isEmpty,
                  !cell.isHiddenOrHasHiddenAncestor,
                  let page = cell.representedPage, page.document === document else { continue }
            if let image = images.object(forKey: page) { cell.preview.image = image; continue }
            let before = generation
            let image = page.thumbnail(of: NSSize(width: 360, height: 252), for: .cropBox)
            guard before == generation, cell.representedPage === page else { continue }
            images.setObject(image, forKey: page, cost: 360 * 252 * 4)
            cell.preview.image = image
            renderedCount += 1
            break // Yield between pages so input and saving can run.
        }
        schedule()
    }
}

@MainActor
private func selectContextRow(in table: NSTableView, event: NSEvent) {
    let row = table.row(at: table.convert(event.locationInWindow, from: nil))
    if row >= 0, !table.selectedRowIndexes.contains(row) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
    table.window?.makeFirstResponder(table)
}

@MainActor
final class SidebarBookmarkOutlineView: NSOutlineView {
    override func menu(for event: NSEvent) -> NSMenu? {
        selectContextRow(in: self, event: event)
        return super.menu(for: event)
    }
}
