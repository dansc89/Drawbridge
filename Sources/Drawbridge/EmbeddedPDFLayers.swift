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

    static func visibility(_ group: CGPDFDictionaryRef, properties: CGPDFDictionaryRef) -> Bool? {
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

    static func snapshotMembership(on page: PDFPage) -> [String: Bool?] {
        guard let root = page.document?.documentRef?.catalog, let rawPage = page.pageRef?.dictionary else { return [:] }
        var properties: CGPDFDictionaryRef?
        var annotations: CGPDFArrayRef?
        guard CGPDFDictionaryGetDictionary(root, "OCProperties", &properties), let properties,
              CGPDFDictionaryGetArray(rawPage, "Annots", &annotations), let annotations else { return [:] }
        var memberships: [String: Bool?] = [:]
        for index in 0..<CGPDFArrayGetCount(annotations) {
            var annotation: CGPDFDictionaryRef?
            var group: CGPDFDictionaryRef?
            var subtype: UnsafePointer<CChar>?
            var type: UnsafePointer<CChar>?
            var identity: CGPDFStringRef?
            var owned: CGPDFObjectRef?
            guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation,
                  CGPDFDictionaryGetName(annotation, "Subtype", &subtype), let subtype, String(cString: subtype) == "Stamp",
                  CGPDFDictionaryGetDictionary(annotation, "OC", &group), let group,
                  !CGPDFDictionaryGetObject(group, "DrawbridgeLayerID", &owned),
                  CGPDFDictionaryGetString(annotation, "NM", &identity), let identity,
                  let name = CGPDFStringCopyTextString(identity) else { continue }
            let isGroup = CGPDFDictionaryGetName(group, "Type", &type) && type.map { String(cString: $0) == "OCG" } == true
            memberships.updateValue(isGroup ? visibility(group, properties: properties) : nil, forKey: name as String)
        }
        return memberships
    }

    /// Plain native OCG membership of original annotations, without modifying
    /// their PDF dictionaries or treating native groups as Drawbridge layers.
    static func annotationMembership(on page: PDFPage) -> [(slot: Int, layer: Int, display: Bool, printFlag: Bool)] {
        guard let root = page.document?.documentRef?.catalog, let raw = page.pageRef?.dictionary else { return [] }
        var properties: CGPDFDictionaryRef?, groups: CGPDFArrayRef?, annotations: CGPDFArrayRef?
        guard CGPDFDictionaryGetDictionary(root, "OCProperties", &properties), let properties,
              CGPDFDictionaryGetArray(properties, "OCGs", &groups), let groups,
              CGPDFDictionaryGetArray(raw, "Annots", &annotations), let annotations,
              CGPDFArrayGetCount(annotations) == page.annotations.count else { return [] }
        var native: [CGPDFDictionaryRef] = []
        for index in 0..<CGPDFArrayGetCount(groups) {
            var group: CGPDFDictionaryRef?, owned: CGPDFObjectRef?, type: UnsafePointer<CChar>?
            guard CGPDFArrayGetDictionary(groups,index,&group), let group,
                  CGPDFDictionaryGetName(group,"Type",&type), type.map({ String(cString:$0) }) == "OCG",
                  !CGPDFDictionaryGetObject(group,"DrawbridgeLayerID",&owned), !native.contains(group) else { continue }
            native.append(group)
        }
        return (0..<CGPDFArrayGetCount(annotations)).compactMap { slot in
            var annotation: CGPDFDictionaryRef?, group: CGPDFDictionaryRef?, subtype: UnsafePointer<CChar>?
            guard CGPDFArrayGetDictionary(annotations,slot,&annotation), let annotation,
                  CGPDFDictionaryGetDictionary(annotation,"OC",&group), let group, let layer = native.firstIndex(of:group),
                  CGPDFDictionaryGetName(annotation,"Subtype",&subtype), let subtype,
                  page.annotations[slot].type == String(cString:subtype) else { return nil }
            var flags: CGPDFInteger = 0; CGPDFDictionaryGetInteger(annotation,"F",&flags)
            return (slot,layer,flags & 35 == 0,flags & 4 != 0)
        }
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
