import AppKit
import PDFKit

/// Portable, annotation-only PDF data. This is not an object archive and never
/// changes ownership or the preservation contract of the original annotation.
struct CopiedMarkupPayload: Codable, Equatable, Sendable {
    static let key = PDFAnnotationKey(rawValue: "DrawbridgeCopiedMarkup")
    let metadata: Data
    let appearance: Data
    let richText: Data?
    // Only native annotation styling/content is imported. Never actions, links,
    // page references, replies, ownership IDs, or arbitrary third-party keys.
    static let fields: Set<String> = ["/Contents", "/T", "/Subj", "/DA", "/DS", "/RC", "/Q", "/C", "/IC", "/CA", "/BS", "/Border", "/BE", "/RD", "/Rotate", "/IT", "/LE", "/DrawbridgeTextBoxAppearance", "/DrawbridgeStrokeOpacity", "/DrawbridgeFillOpacity"]
    // Copied FreeText is a new owned annotation, unlike a patch to an original.
    // Persist its inert editable layout as well as the frozen appearance. Keep
    // this explicit: neither actions nor source ownership/page links may cross.
    static let textPersistenceFields: Set<String> = ["/Contents", "/RC", "/DS", "/DA", "/Q", "/Rotate", "/RD", "/C", "/IC", "/BS", "/Border", "/CA", "/DrawbridgeTextBoxAppearance", "/DrawbridgeStrokeOpacity", "/DrawbridgeFillOpacity"]
    var isValid: Bool {
        !metadata.isEmpty && metadata.count < 32 * 1024 * 1024 && !appearance.isEmpty && appearance.count < 32 * 1024 * 1024 && (richText?.count ?? 0) < 8 * 1024 * 1024
    }
    static func read(_ annotation: PDFAnnotation) -> Self? {
        guard let raw = annotation.value(forAnnotationKey: key) as? String, let data = raw.data(using: .utf8), data.count < 64 * 1024 * 1024,
              let result = try? JSONDecoder().decode(Self.self, from: data), result.isValid else { return nil }
        return result
    }
    func install(on annotation: PDFAnnotation) {
        if let data = try? JSONEncoder().encode(self), let raw = String(data: data, encoding: .utf8) { annotation.setValue(raw, forAnnotationKey: Self.key) }
    }
    @MainActor static func capture(_ annotation: PDFAnnotation) -> Self? {
        guard let clone = annotation.copy() as? PDFAnnotation else { return nil }
        clone.removeValue(forAnnotationKey: key)
        let frozen = ImportedTextContent.freeze(clone, fields: [])
        let rich: Data?
        if annotation.type == "FreeText" {
            let text = ImportedTextContent.read(annotation)
            rich = try? text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        } else { rich = nil }
        let value = Self(metadata: frozen.metadata, appearance: frozen.appearance, richText: rich)
        return value.isValid ? value : nil
    }
    @MainActor func annotation(bounds: CGRect) -> PDFAnnotation? {
        guard isValid, let document = PDFDocument(data: metadata), document.pageCount == 1,
              let page = document.page(at: 0), page.annotations.count == 1, let source = page.annotations.first else { return nil }
        let rich = richText.flatMap { try? NSAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) }
        let copy: PDFAnnotation
        if source.type == "FreeText" { copy = ImportedTextAnnotation(source: source, richText: rich ?? ImportedTextContent.read(source)) }
        else { guard let cloned = source.copy() as? PDFAnnotation else { return nil }; copy = cloned }
        // Keep only inert markup dictionary fields from the annotation-only PDF.
        for raw in copy.annotationKeyValues.keys {
            let key = (raw as? String) ?? String(describing: raw)
            if !Self.fields.contains(key) && !["/Type", "/Subtype", "/Rect", "/AP", "/L"].contains(key) { copy.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: key)) }
        }
        copy.bounds = bounds
        copy.isReadOnly = false
        install(on: copy)
        return copy
    }
}
