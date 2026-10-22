import AppKit
import PDFKit

/// PDFKit exposes local quad points; the PDF writer emits absolute page points.
enum HighlightGeometry {
    static func update(_ annotation: PDFAnnotation) {
        let w = annotation.bounds.width, h = annotation.bounds.height
        annotation.quadrilateralPoints = [CGPoint(x: 0, y: h), CGPoint(x: w, y: h), .zero, CGPoint(x: w, y: 0)].map { NSValue(point: $0) }
    }
    static func pdfPoints(_ bounds: CGRect) -> [Double] {
        [bounds.minX, bounds.maxY, bounds.maxX, bounds.maxY, bounds.minX, bounds.minY, bounds.maxX, bounds.minY].map(Double.init)
    }
}
