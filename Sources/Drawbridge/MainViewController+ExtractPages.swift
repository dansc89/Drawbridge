import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class ExtractPagesForm: NSView, NSTextFieldDelegate {
    enum Scope: Int { case range, selectedPages, selectedMarkups, allMarkups }
    let scope = NSPopUpButton(frame:.zero,pullsDown:false)
    let range = NSTextField(string:"")
    let summary = NSTextField(labelWithString:"")
    let pageCount: Int
    let selectedPages: [Int], selectedMarkups: [Int], allMarkups: [Int]
    init(pageCount: Int, currentPage: Int, selectedPages: [Int], selectedMarkups: [Int], allMarkups: [Int]) {
        self.pageCount=pageCount;self.selectedPages=selectedPages;self.selectedMarkups=selectedMarkups;self.allMarkups=allMarkups
        super.init(frame:NSRect(x:0,y:0,width:440,height:120))
        scope.autoenablesItems=false
        scope.addItems(withTitles:["Page range", "Selected pages", "Pages containing selected markups", "All pages with markups"])
        scope.item(at:1)?.isEnabled = !selectedPages.isEmpty
        scope.item(at:2)?.isEnabled = !selectedMarkups.isEmpty
        scope.item(at:3)?.isEnabled = !allMarkups.isEmpty
        scope.selectItem(at:!selectedMarkups.isEmpty ? 2 : selectedPages.count > 1 ? 1 : 0)
        scope.target=self;scope.action=#selector(update)
        range.stringValue=String(max(0,min(currentPage,pageCount-1))+1)
        range.placeholderString="For example: 1-20, 25, 30-35";range.delegate=self
        range.setAccessibilityLabel("Pages to extract")
        summary.font = .systemFont(ofSize:11);summary.textColor = .secondaryLabelColor
        let stack=NSStackView(views:[scope,range,summary]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=10
        stack.frame=bounds;stack.autoresizingMask=[.width,.height];addSubview(stack)
        scope.widthAnchor.constraint(equalToConstant:440).isActive=true;range.widthAnchor.constraint(equalToConstant:440).isActive=true
        update()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    var indices: [Int]? {
        switch Scope(rawValue:scope.indexOfSelectedItem) {
        case .range: return MeasurementGeometry.pages(range.stringValue,count:pageCount)
        case .selectedPages: return selectedPages.isEmpty ? nil : selectedPages
        case .selectedMarkups: return selectedMarkups.isEmpty ? nil : selectedMarkups
        case .allMarkups: return allMarkups.isEmpty ? nil : allMarkups
        case nil: return nil
        }
    }
    @objc func update() {
        range.isEnabled=scope.indexOfSelectedItem == 0
        summary.stringValue=indices.map { "\($0.count) page(s), in document order. Each page is included once." } ?? "Enter valid page numbers from 1 to \(pageCount)."
    }
    func controlTextDidChange(_ notification:Notification) { update() }
}

@MainActor
extension MainViewController {
    func extractionForm(for document: PDFDocument) -> ExtractPagesForm {
        func indices(_ annotations:[PDFAnnotation]) -> [Int] {
            Array(Set(annotations.compactMap { a in
                guard let page=a.page, page.document === document, MarkupListPresentation.includes(a) else { return nil }
                let i=document.index(for:page);return i == NSNotFound ? nil : i
            })).sorted()
        }
        let listed = isMarkupsPanelVisible ? markupsTable.selectedRowIndexes.compactMap { markupItems.indices.contains($0) ? markupItems[$0].annotation : nil } : []
        let selected = listed.isEmpty ? pdfView.rectangleMarkup.selectedItems : listed
        let marked = (0..<document.pageCount).filter { i in document.page(at:i)?.annotations.contains(where:MarkupListPresentation.includes) == true }
        return ExtractPagesForm(pageCount:document.pageCount,currentPage:pdfView.currentPage.map(document.index(for:)) ?? 0,
            selectedPages:pagesTableView.selectedRowIndexes.filter { $0 < document.pageCount },selectedMarkups:indices(selected),allMarkups:marked)
    }

    @objc func commandExtractPages(_ sender:Any?) {
        guard let document=pdfView.document,document.pageCount > 0,!isPDFProcessingBusy,!isPDFFileProcessingOperation,!persistenceCoordinator.isManualSaveInFlight else { beep();return }
        pdfView.rectangleMarkup.finishTextEditing();pdfView.rectangleMarkup.cancelGesture()
        let form=extractionForm(for:document)
        let alert=NSAlert();alert.messageText="Extract Pages"
        alert.informativeText="Save the chosen pages, including their markups, to a separate PDF. Use physical page numbers, not sheet labels."
        alert.accessoryView=form;alert.addButton(withTitle:"Extract…");alert.addButton(withTitle:"Cancel")
        while alert.runModal() == .alertFirstButtonReturn {
            guard pdfView.document === document else { return }
            guard let indices=form.indices,!indices.isEmpty else { alert.informativeText="Choose at least one page. Enter a range such as 1-20, 25, using page numbers from 1 to \(document.pageCount).";continue }
            let panel=NSSavePanel();panel.title="Save Extracted Pages";panel.allowedContentTypes=[.pdf];panel.canCreateDirectories=true
            panel.nameFieldStringValue=(openDocumentURL?.deletingPathExtension().lastPathComponent ?? "Document")+" - Extracted.pdf"
            guard panel.runModal() == .OK,let destination=panel.url else { return }
            startPageExtraction(document:document,indices:indices,destination:destination)
            return
        }
    }

    /// Freeze the current edits without saving/cleaning/replacing the user's document.
    func startPageExtraction(document:PDFDocument,indices:[Int],destination:URL,completion:(@MainActor @Sendable (Bool)->Void)? = nil) {
        guard document === pdfView.document,!isPDFProcessingBusy,!isPDFFileProcessingOperation,!persistenceCoordinator.isManualSaveInFlight else { completion?(false);return }
        pdfView.rectangleMarkup.finishTextEditing();pdfView.rectangleMarkup.cancelGesture()
        pdfView.rectangleMarkup.ensureLayerCatalogMarker()
        let records=RectangleMarkupRecord.capture(document)
        let imported=pdfView.rectangleMarkup.importedPlan()
        let structure=pageStructureState?.document === document ? pageStructureState?.plan(for:document,forceOriginal:imported != nil) : nil
        let navigation=PDFTKBookmarkWriter.captureNavigation(in:document)
        let labels=embeddedPageLabelsForSave(in:document)
        let source=openDocumentURL ?? document.documentURL
        let stamp=pdfView.rectangleMarkup.sourceStamp
        let protected=sessionDocumentURLs + (source.map { [$0] } ?? [])
        let box=PDFDocumentBox(document:document)
        isPDFFileProcessingOperation=true;beginBusyIndicator("Extracting pages…",detail:"Preparing current markups…")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result=Result { () throws -> Void in
                let dir=FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgeExtractSnapshot-\(UUID())")
                try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
                defer { try? FileManager.default.removeItem(at:dir) }
                let snapshot=dir.appendingPathComponent("current.pdf")
                let saved:Bool
                if let structure,let source {
                    saved=structure.write(document:box.document,currentSource:source,destination:snapshot,expectedStamp:stamp,labels:labels,records:records,navigation:navigation,importedPlan:imported,onCommitted:{ _ in })
                } else {
                    saved=Self.writePDFDocument(box.document,to:snapshot,pageLabels:labels,navigationSourceURL:source,
                        rectangleRecords:source == nil ? nil : records,rectangleSourceStamp:stamp,navigationSnapshot:navigation,importedPlan:imported)
                }
                guard saved else { throw NSError(domain:"DrawbridgeExtract",code:1,userInfo:[NSLocalizedDescriptionKey:"Could not prepare the current edits safely. No extracted PDF was saved."]) }
                try PDFPageExtractor.extract(source:snapshot,destination:destination,indices:indices,protectedSources:protected)
            }
            DispatchQueue.main.async {
                guard let self else { completion?(false);return }
                self.isPDFFileProcessingOperation=false;self.endBusyIndicator()
                switch result {
                case .success:
                    completion?(true)
                    if completion == nil { self.runAlert(title:"Pages Extracted",informativeText:"Saved \(Set(indices).count) page(s) to \(destination.lastPathComponent). The open document and its unsaved edits are unchanged.") }
                case .failure(let error):
                    completion?(false)
                    if completion == nil { self.runAlert(title:"Extract Pages Failed",informativeText:error.localizedDescription,style:.warning) }
                }
            }
        }
    }
}
