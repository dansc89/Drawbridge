/// Shared presentation/admission policy for menu, toolbar and direct shortcuts.
/// Calibration and measurements are available on editable Review sheets.
struct ReviewMeasurementCapability {
    let isReview: Bool
    let editable: Bool
    let hasPage: Bool
    let supportedPage: Bool
    let hasScale: Bool
    var canMeasure: Bool { editable && hasPage && supportedPage }
    var canSetScale: Bool { editable && hasPage && supportedPage }
    var measurementReason: String? {
        if !supportedPage { return "This sheet uses unsupported page units." }
        if !editable { return "Measurements require editing access." }
        if !hasPage { return "Open a PDF sheet to measure." }
        return nil
    }
    var scaleReason: String? {
        nil
    }
}
