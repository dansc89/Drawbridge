/// Shared presentation/admission policy for menu, toolbar and direct shortcuts.
/// Review can use existing immutable base-PDF scale, but cannot author shared scale.
struct ReviewMeasurementCapability {
    let isReview: Bool
    let editable: Bool
    let hasPage: Bool
    let supportedPage: Bool
    let hasScale: Bool
    var canMeasure: Bool { editable && hasPage && supportedPage && (!isReview || hasScale) }
    var canSetScale: Bool { editable && hasPage && !isReview }
    var measurementReason: String? {
        if isReview && !hasScale { return "This Review sheet has no scale; set scale in a local PDF before uploading." }
        if !supportedPage { return "This sheet uses unsupported page units." }
        if !editable { return "Measurements require editing access." }
        if !hasPage { return "Open a PDF sheet to measure." }
        return nil
    }
    var scaleReason: String? {
        isReview ? "Drawing scale is read-only in Review. Set scale in a local PDF before uploading." : nil
    }
}
