import Foundation

/// Adds annotation OCGs without modifying any existing drawing streams or OCG objects.
enum PDFMarkupLayersPatch {
    static func install(catalogText: String?, objects: inout [String: Any], next: inout Int) throws -> [String: String] {
        guard let catalogText else { return [:] }
        guard let data = catalogText.data(using: .utf8), let model = try? JSONDecoder().decode(MarkupLayerCatalog.self, from: data), model.isValid,
              let root = (objects["trailer"] as? [String: Any])?["value"] as? [String: Any], let ref = root["/Root"] as? String,
              var rootObject = objects["obj:" + ref] as? [String: Any], var catalog = rootObject["value"] as? [String: Any] else { throw CocoaError(.fileWriteUnknown) }
        func dictionary(_ value: Any?) -> [String: Any] {
            if let ref = value as? String { return (objects["obj:" + ref] as? [String: Any])?["value"] as? [String: Any] ?? [:] }
            return value as? [String: Any] ?? [:]
        }
        var props = dictionary(catalog["/OCProperties"])
        let groups = props["/OCGs"] as? [String] ?? []
        let owned = Set(groups.filter { dictionary($0)["/DrawbridgeLayerID"] != nil })
        // Old group objects remain untouched and available for other configurations.
        var mapping: [String: String] = [:]
        for layer in model.layers {
            let group = "\(next) 0 R"; next += 1
            objects["obj:" + group] = ["value": ["/Type": "/OCG", "/Name": "u:" + layer.name, "/DrawbridgeLayerID": "u:" + layer.id,
                "/Usage": ["/View": ["/ViewState": layer.visible ? "/ON" : "/OFF"], "/Print": ["/PrintState": layer.visible ? "/ON" : "/OFF"]]]]
            mapping[layer.id] = group
        }
        func removeOwned(_ value: Any) -> Any {
            guard let array = value as? [Any] else { return value }
            return array.compactMap { item -> Any? in
                if let ref = item as? String, owned.contains(ref) { return nil }
                return removeOwned(item)
            }
        }
        let newGroups = model.layers.compactMap { mapping[$0.id] }
        props["/OCGs"] = groups.filter { !owned.contains($0) } + newGroups
        var defaults = dictionary(props["/D"])
        for key in ["/ON", "/OFF", "/Order", "/Locked", "/RBGroups"] {
            if let old = defaults[key] { defaults[key] = removeOwned(old) }
        }
        defaults["/ON"] = (defaults["/ON"] as? [String] ?? []) + model.layers.filter(\.visible).compactMap { mapping[$0.id] }
        defaults["/OFF"] = (defaults["/OFF"] as? [String] ?? []) + model.layers.filter { !$0.visible }.compactMap { mapping[$0.id] }
        defaults["/Order"] = (defaults["/Order"] as? [Any] ?? []) + newGroups
        props["/D"] = defaults; catalog["/OCProperties"] = props
        rootObject["value"] = catalog; objects["obj:" + ref] = rootObject
        return mapping
    }
    /// Verify that only Drawbridge-owned group references were replaced. Foreign
    /// layer definitions/configurations remain byte-for-byte equivalent objects.
    static func preservesForeignLayers(before: [String: Any], after: [String: Any], root: String) -> Bool {
        func dict(_ value: Any?, _ objects: [String: Any]) -> [String: Any] {
            if let ref = value as? String { return (objects["obj:" + ref] as? [String: Any])?["value"] as? [String: Any] ?? [:] }
            return value as? [String: Any] ?? [:]
        }
        let a = dict(dict(root, before)["/OCProperties"], before)
        let b = dict(dict(root, after)["/OCProperties"], after)
        func clean(_ props: [String: Any], _ objects: [String: Any]) -> [String: Any] {
            let groups = props["/OCGs"] as? [String] ?? []
            let owned = Set(groups.filter { dict($0, objects)["/DrawbridgeLayerID"] != nil })
            func filter(_ value: Any) -> Any {
                guard let array = value as? [Any] else { return value }
                return array.compactMap { item -> Any? in
                    if let ref = item as? String, owned.contains(ref) { return nil }
                    return filter(item)
                }
            }
            var result = props
            result["/OCGs"] = groups.filter { !owned.contains($0) }
            var d = dict(result["/D"], objects)
            for key in ["/ON", "/OFF", "/Order", "/Locked", "/RBGroups"] {
                if let value = d[key] { d[key] = filter(value) }
                if (d[key] as? [Any])?.isEmpty == true { d.removeValue(forKey: key) }
            }
            if d.isEmpty { result.removeValue(forKey: "/D") } else { result["/D"] = d }
            if (result["/OCGs"] as? [String])?.isEmpty == true { result.removeValue(forKey: "/OCGs") }
            return result
        }
        return NSDictionary(dictionary: clean(a, before)).isEqual(to: clean(b, after))
    }
    static func references(_ objects: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        guard let trailer = (objects["trailer"] as? [String: Any])?["value"] as? [String: Any], let root = trailer["/Root"] as? String,
              let catalog = (objects["obj:" + root] as? [String: Any])?["value"] as? [String: Any] else { return result }
        let props: [String: Any]
        if let ref = catalog["/OCProperties"] as? String { props = (objects["obj:" + ref] as? [String: Any])?["value"] as? [String: Any] ?? [:] }
        else { props = catalog["/OCProperties"] as? [String: Any] ?? [:] }
        for ref in props["/OCGs"] as? [String] ?? [] {
            if let dict = (objects["obj:" + ref] as? [String: Any])?["value"] as? [String: Any], let id = dict["/DrawbridgeLayerID"] as? String, id.hasPrefix("u:") { result[String(id.dropFirst(2))] = ref }
        }
        return result
    }
}
