import Foundation
import PDFKit

/// A small, reversible layer edit of a painted path in the immutable PDF base.
/// Each selector component is a paint/Do ordinal, never a name or object number.
struct NativeDrawingAssignment: Codable, Equatable, Sendable {
    let path: [Int]
    let originalLayers: [Int]
    var fingerprint: String? = nil
    var isValid: Bool {
        (fingerprint == nil || (fingerprint!.count == 64 && fingerprint!.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })) &&
        (1...12).contains(path.count) && path.allSatisfy { (0..<1_000_000).contains($0) }
            && originalLayers.count <= 128 && originalLayers.allSatisfy { (0..<10000).contains($0) }
    }
    static let key = PDFAnnotationKey(rawValue: "DrawbridgeDrawingAssignment")
    static func read(_ annotation: PDFAnnotation) -> Self? {
        guard let text = annotation.value(forAnnotationKey: key) as? String, text.utf8.count <= 4096,
              let data = text.data(using: .utf8), let result = try? JSONDecoder().decode(Self.self, from: data), result.isValid else { return nil }
        return result
    }
    var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }
}
