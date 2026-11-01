import PDFKit

/// Native page-content optional-content groups are not Drawbridge markup layers.
/// Mutation uses a staged native PDF graph, not a PDFKit state setter.
/// In particular, never use their names as annotation membership IDs or persist
/// them into DrawbridgeLayerCatalog. Duplicate names are legal in a PDF.
enum EmbeddedPDFLayers {
    struct Layer: Equatable {
        /// Registry slot, scoped to this document generation; not a persistent ID.
        let registryIndex: Int
        let name: String
        /// Nil means the effective state depends on an unsupported configuration.
        var visible: Bool? = nil
    }

    private static func visibility(_ group: CGPDFDictionaryRef, properties: CGPDFDictionaryRef) -> Bool? {
        var config: CGPDFDictionaryRef?
        var value: CGPDFObjectRef?
        guard CGPDFDictionaryGetDictionary(properties, "D", &config), let config,
              !CGPDFDictionaryGetObject(properties, "Configs", &value),
              !CGPDFDictionaryGetObject(config, "AS", &value) else { return nil }
        if CGPDFDictionaryGetObject(group, "Usage", &value) {
            var usage: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(group, "Usage", &usage), let usage else { return nil }
            // CreatorInfo is metadata, not an automatic visibility predicate.
            if CGPDFDictionaryGetCount(usage) > 0 {
                guard CGPDFDictionaryGetCount(usage) == 1, CGPDFDictionaryGetObject(usage, "CreatorInfo", &value) else { return nil }
            }
        }
        var radio: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(config, "RBGroups", &radio), let radio, CGPDFArrayGetCount(radio) > 0 { return nil }
        var base: UnsafePointer<CChar>?
        var visible = true
        if CGPDFDictionaryGetName(config, "BaseState", &base), let base {
            switch String(cString: base) { case "ON": visible = true; case "OFF": visible = false; default: return nil }
        }
        func contains(_ key: String) -> Bool? {
            var object: CGPDFObjectRef?
            guard CGPDFDictionaryGetObject(config, key, &object) else { return false }
            var array: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(config, key, &array), let array else { return nil }
            for index in 0..<CGPDFArrayGetCount(array) {
                var entry: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(array, index, &entry), let entry else { return nil }
                if entry == group { return true }
            }
            return false
        }
        guard let on = contains("ON"), let off = contains("OFF"), !(on && off) else { return nil }
        if on { visible = true }; if off { visible = false }
        return visible
    }

    static func read(_ document: PDFDocument?) -> [Layer] {
        guard let root = document?.documentRef?.catalog else { return [] }
        var properties: CGPDFDictionaryRef?
        var groups: CGPDFArrayRef?
        guard CGPDFDictionaryGetDictionary(root, "OCProperties", &properties), let properties,
              CGPDFDictionaryGetArray(properties, "OCGs", &groups), let groups else { return [] }
        var result: [Layer] = []
        // A repeated reference is not another layer; identical names ARE.
        var seen = Set<CGPDFDictionaryRef>()
        for index in 0..<CGPDFArrayGetCount(groups) {
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(groups, index, &dictionary), let dictionary,
                  seen.insert(dictionary).inserted else { continue }
            var type: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Type", &type), let type,
                  String(cString: type) == "OCG" else { continue }
            var owned: CGPDFObjectRef?
            guard !CGPDFDictionaryGetObject(dictionary, "DrawbridgeLayerID", &owned) else { continue }
            var name: CGPDFStringRef?
            let title: String
            if CGPDFDictionaryGetString(dictionary, "Name", &name), let name,
               let text = CGPDFStringCopyTextString(name) { title = text as String }
            else { title = "Unnamed PDF layer" }
            result.append(Layer(registryIndex: index, name: title, visible: visibility(dictionary, properties: properties)))
        }
        return result
    }
}
