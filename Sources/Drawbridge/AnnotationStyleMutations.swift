import Foundation
import PDFKit

enum AnnotationStyleMutations {
    static func assignLineWidth(_ lineWidth: CGFloat, to annotation: PDFAnnotation, syncInkPaths: Bool = true) {
        let normalized = max(0.0, lineWidth)
        let border = annotation.border ?? PDFBorder()
        border.lineWidth = normalized
        annotation.border = border
        guard syncInkPaths else { return }
        let annotationType = (annotation.type ?? "").lowercased()
        if annotationType.contains("ink"),
           let paths = annotation.paths {
            for path in paths {
                path.lineWidth = normalized
            }
        }
    }
}
