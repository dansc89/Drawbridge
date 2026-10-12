import Foundation
import PDFKit

/// Whole-sheet calibration uses the PDF viewport/rectilinear measurement model.
/// Named or regional viewports belong to drawing details and are never replaced.
enum PDFPageScaleMetadata {
    static func resolved(_ value: Any?, objects: [String: Any]) -> Any? {
        guard let ref = value as? String, ref.hasSuffix(" R") else { return value }
        return (objects["obj:" + ref] as? [String: Any])?["value"]
    }
    static func dictionary(_ value: Any?, objects: [String: Any]) -> [String: Any] {
        resolved(value, objects: objects) as? [String: Any] ?? [:]
    }
    static func entries(_ page: [String: Any], objects: [String: Any]) -> [Any] {
        let value = resolved(page["/VP"], objects: objects)
        if let array = value as? [Any] { return array }
        return value is [String: Any] ? [page["/VP"]!] : []
    }
    static func effectivePage(_ page: [String: Any], objects: [String: Any]) -> [String: Any] {
        var result = page, parent = dictionary(page["/Parent"], objects: objects)
        for _ in 0..<32 {
            for key in ["/MediaBox", "/CropBox"] where result[key] == nil {
                result[key] = resolved(parent[key], objects: objects)
            }
            if parent.isEmpty { break }
            parent = dictionary(parent["/Parent"], objects: objects)
        }
        for key in ["/MediaBox", "/CropBox"] { result[key] = resolved(result[key], objects: objects) }
        return result
    }
    static func wholePage(_ viewport: [String: Any], page: [String: Any]) -> Bool {
        guard viewport["/Name"] == nil,
              let box = viewport["/BBox"] as? [NSNumber], box.count == 4 else { return false }
        return ["/MediaBox", "/CropBox"].contains { key in
            guard let bounds = page[key] as? [NSNumber], bounds.count == 4 else { return false }
            return zip(box, bounds).allSatisfy { abs($0.doubleValue - $1.doubleValue) < 0.01 }
        }
    }
    static func conversion(_ array: Any?, objects: [String: Any]) -> (Double, String)? {
        guard let array = resolved(array, objects: objects) as? [Any], let first = array.first else { return nil }
        let format = dictionary(first, objects: objects)
        guard let c = (format["/C"] as? NSNumber)?.doubleValue, c.isFinite, c > 0,
              let text = format["/U"] as? String else { return nil }
        let unit = text.hasPrefix("u:") ? String(text.dropFirst(2)) : text
        switch unit.lowercased().trimmingCharacters(in: .whitespaces) {
        case "'", "ft", "feet", "foot": return (c, "ft")
        case "\"", "in", "inches", "inch": return (c / 12, "ft")
        case "m", "meter", "meters", "metre", "metres": return (c, "m")
        case "cm": return (c / 100, "m")
        case "mm": return (c / 1000, "m")
        default: return nil
        }
    }
    static func scale(_ measure: [String: Any], objects: [String: Any]) -> DrawingScale? {
        guard (measure["/Subtype"] as? String ?? "/RL") == "/RL",
              let x = conversion(measure["/X"], objects: objects) else { return nil }
        if let yValue = measure["/Y"] {
            guard let y = conversion(yValue, objects: objects), x.1 == y.1,
                  abs(x.0 - y.0) <= max(x.0, y.0) * 1e-6 else { return nil }
            if let cyx = (measure["/CYX"] as? NSNumber)?.doubleValue {
                let xFormat = (resolved(measure["/X"], objects: objects) as? [Any])?.first
                let yFormat = (resolved(yValue, objects: objects) as? [Any])?.first
                guard let rawX = (dictionary(xFormat, objects: objects)["/C"] as? NSNumber)?.doubleValue,
                      let rawY = (dictionary(yFormat, objects: objects)["/C"] as? NSNumber)?.doubleValue else { return nil }
                let expected = (y.0 / rawY) / (x.0 / rawX)
                guard cyx.isFinite, abs(cyx - expected) <= expected * 1e-6 else { return nil }
            }
        }
        let ratio = (measure["/R"] as? String).map { $0.hasPrefix("u:") ? String($0.dropFirst(2)) : $0 }
        let value = DrawingScale(unitsPerPoint: x.0, unit: x.1,
                                 name: ratio ?? String(format: "1 PDF point = %.8g %@", x.0, x.1))
        return value.isValid ? value : nil
    }
    static func scale(page: [String: Any], objects: [String: Any]) -> DrawingScale? {
        let viewports = entries(page, objects: objects).map { dictionary($0, objects: objects) }.filter { wholePage($0, page: effectivePage(page, objects: objects)) }
        guard viewports.count == 1 else { return nil }
        return scale(dictionary(viewports[0]["/Measure"], objects: objects), objects: objects)
    }
    static func read(_ page: PDFPage) -> (present: Bool, scale: DrawingScale?) {
        guard let source = page.pageRef?.dictionary else { return (false, nil) }
        var array: CGPDFArrayRef?
        var single: CGPDFDictionaryRef?
        var viewports: [[String: Any]] = []
        if CGPDFDictionaryGetArray(source, "VP", &array), let array {
            guard CGPDFArrayGetCount(array) <= 4096 else { return (true, nil) }
            for index in 0..<CGPDFArrayGetCount(array) {
                var d: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(array, index, &d), let d { viewports.append(readDictionary(d, depth: 0)) }
            }
        } else if CGPDFDictionaryGetDictionary(source, "VP", &single), let single {
            viewports = [readDictionary(single, depth: 0)]
        }
        let bounds = page.bounds(for: .mediaBox), crop = page.bounds(for: .cropBox)
        let dictionary: [String: Any] = ["/MediaBox": [bounds.minX,bounds.minY,bounds.maxX,bounds.maxY],
                                         "/CropBox": [crop.minX,crop.minY,crop.maxX,crop.maxY], "/VP": viewports]
        let whole = viewports.filter { wholePage($0, page: dictionary) }
        return (!whole.isEmpty, scale(page: dictionary, objects: [:]))
    }
    private static func readDictionary(_ source: CGPDFDictionaryRef, depth: Int) -> [String: Any] {
        guard depth < 8 else { return [:] }
        var result: [String: Any] = [:]
        for key in ["Type", "Subtype", "Name", "R", "U"] {
            var string: CGPDFStringRef?; var name: UnsafePointer<CChar>?
            if CGPDFDictionaryGetString(source, key, &string), let string, let text = CGPDFStringCopyTextString(string) { result["/" + key] = "u:" + (text as String) }
            else if CGPDFDictionaryGetName(source, key, &name), let name { result["/" + key] = "/" + String(cString: name) }
        }
        for key in ["C", "CYX"] {
            var value: CGPDFReal = 0
            if CGPDFDictionaryGetNumber(source, key, &value) { result["/" + key] = value }
        }
        var measure: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(source, "Measure", &measure), let measure { result["/Measure"] = readDictionary(measure, depth: depth + 1) }
        for key in ["BBox", "X", "Y"] {
            var array: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(source, key, &array), let array, CGPDFArrayGetCount(array) < 64 else { continue }
            var values: [Any] = []
            for i in 0..<CGPDFArrayGetCount(array) {
                var number: CGPDFReal = 0; var dictionary: CGPDFDictionaryRef?
                if CGPDFArrayGetNumber(array, i, &number) { values.append(number) }
                else if CGPDFArrayGetDictionary(array, i, &dictionary), let dictionary { values.append(readDictionary(dictionary, depth: depth + 1)) }
            }
            result["/" + key] = values
        }
        return result
    }

    /// Copy-on-write avoids changing shared viewport/measure objects on other pages.
    /// Returns the exact authorized /VP value for the writer's preservation check.
    static func install(scale: DrawingScale?, page: inout [String: Any], objects: inout [String: Any], next: inout Int) -> Any {
        let geometry = effectivePage(page, objects: objects)
        let existing = entries(page, objects: objects)
        let whole = existing.filter { wholePage(dictionary($0, objects: objects), page: geometry) }
        var retained = existing.filter { !wholePage(dictionary($0, objects: objects), page: geometry) }
        if let scale {
            var viewport = whole.first.map { dictionary($0, objects: objects) } ?? [:]
            let previous = dictionary(viewport["/Measure"], objects: objects)
            var measure: [String: Any] = ["/Type": "/Measure", "/Subtype": "/RL"]
            func format(_ unit: String, _ factor: Double, precision: Int = 100) -> [String: Any] {
                ["/Type": "/NumberFormat", "/U": "u:" + unit, "/C": factor, "/D": precision, "/FD": true, "/SS": "u:"]
            }
            if scale.unit == "ft" {
                measure["/R"] = "u:" + String(format: "%.12g in = 1 ft' in\"", 1 / (72 * scale.unitsPerPoint))
                var x = format("'", scale.unitsPerPoint, precision: 4); x["/F"] = "/F"
                measure["/X"] = [x]
                var feet = format("'", 1, precision: 4); feet["/F"] = "/F"; feet["/PS"] = "u:"; feet["/SS"] = "u:-"
                var inches = format("\"", 12, precision: 4); inches["/F"] = "/F"; inches["/PS"] = "u:"
                measure["/D"] = [feet, inches]
                measure["/A"] = [format("sf", 1)]
                measure["/V"] = [format("cu ft", 1)]
                measure["/TargetUnitConversion"] = 1.0 / 864
            } else {
                measure["/R"] = "u:" + String(format: "1 mm = %.12g mm", scale.unitsPerPoint * 72 / 0.0254)
                measure["/X"] = [format("mm", scale.unitsPerPoint * 1000)]
                measure["/D"] = [format("m", 0.001)]
                measure["/A"] = [format("sq m", 0.000001)]
                measure["/V"] = [format("cu m", 0.000000001)]
                measure["/TargetUnitConversion"] = 25.4 / 72
            }
            measure["/T"] = [format("°", 1)]
            // Retain the user's display precision when the base unit is unchanged.
            let priorX = (resolved(previous["/X"], objects: objects) as? [Any])?.first
            let priorUnit = (dictionary(priorX, objects: objects)["/U"] as? String ?? "").lowercased()
            let sameBaseUnit = scale.unit == "ft" ? ["u:'", "u:ft", "u:feet", "u:foot"].contains(priorUnit) : priorUnit == "u:mm"
            if sameBaseUnit {
                for key in ["/D", "/A", "/V", "/T"] { if let value = previous[key] { measure[key] = value } }
            }
            let measureRef = "\(next) 0 R"; next += 1
            objects["obj:" + measureRef] = ["value": measure]
            viewport["/Type"] = "/Viewport"; viewport["/Measure"] = measureRef
            viewport["/BBox"] = geometry["/MediaBox"]
            viewport["/NM"] = viewport["/NM"] ?? "u:" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let viewportRef = "\(next) 0 R"; next += 1
            objects["obj:" + viewportRef] = ["value": viewport]
            // Whole-sheet viewport goes first; specific detail viewports retain their order.
            retained.insert(viewportRef, at: 0)
        }
        if retained.isEmpty { page.removeValue(forKey: "/VP"); return NSNull() }
        page["/VP"] = retained
        return retained
    }
}
