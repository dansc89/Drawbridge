import CoreGraphics
import Foundation

enum MeasurementParsing {
    static func baseUnitsPerPoint(for unit: String) -> CGFloat {
        switch unit {
        case "in":
            return 1.0 / 72.0
        case "ft":
            return 1.0 / 864.0
        case "m":
            return 0.0003527777778
        default:
            return 1.0
        }
    }

    static func parseFractionOrDecimal(_ raw: String) -> Double? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty { return nil }
        if let value = Double(token) {
            return value
        }
        let pieces = token.split(separator: "/")
        guard pieces.count == 2,
              let numerator = Double(pieces[0]),
              let denominator = Double(pieces[1]),
              denominator != 0 else {
            return nil
        }
        return numerator / denominator
    }

    static func parseArchitecturalInches(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let decimal = Double(value) {
            return decimal
        }

        let parts = value.split(separator: " ")
        if parts.count == 2,
           let whole = Double(parts[0]),
           let fraction = parseFractionOrDecimal(String(parts[1])) {
            return whole + fraction
        }
        return parseFractionOrDecimal(value)
    }

    static func parseLength(_ raw: String, unit: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let normalized = text.replacingOccurrences(of: " ", with: "")
        let parseImperialInches: (String) -> Double? = { token in
            if token.isEmpty { return 0 }
            if token.contains("-") {
                let components = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                let whole = parseFractionOrDecimal(String(components.first ?? "")) ?? 0
                let frac = parseFractionOrDecimal(String(components.count > 1 ? components[1] : "")) ?? 0
                return whole + frac
            }
            return parseFractionOrDecimal(token)
        }

        func convertFeetTotal(_ feetTotal: Double, to targetUnit: String) -> Double {
            switch targetUnit {
            case "ft":
                return feetTotal
            case "in":
                return feetTotal * 12.0
            case "m":
                return feetTotal * 0.3048
            default:
                return feetTotal * 864.0
            }
        }

        if normalized.contains("'") || normalized.contains("\"") {
            var feetValue = 0.0
            var inchesValue = 0.0
            if normalized.contains("'") {
                let feetPart = normalized.split(separator: "'", maxSplits: 1, omittingEmptySubsequences: false)
                feetValue = parseFractionOrDecimal(String(feetPart.first ?? "")) ?? 0
                if feetPart.count > 1 {
                    let afterFeet = String(feetPart[1]).replacingOccurrences(of: "\"", with: "")
                    inchesValue = parseImperialInches(afterFeet) ?? 0
                }
            } else {
                let inchesToken = normalized.replacingOccurrences(of: "\"", with: "")
                inchesValue = parseImperialInches(inchesToken) ?? 0
            }
            return convertFeetTotal(feetValue + (inchesValue / 12.0), to: unit)
        }

        if normalized.contains("-") {
            let components = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if components.count == 2,
               let feet = parseFractionOrDecimal(String(components[0])),
               let inches = parseFractionOrDecimal(String(components[1])) {
                return convertFeetTotal(feet + (inches / 12.0), to: unit)
            }
        }

        return parseFractionOrDecimal(normalized)
    }
}
