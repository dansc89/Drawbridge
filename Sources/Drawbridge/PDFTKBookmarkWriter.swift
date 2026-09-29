import Foundation
import PDFKit

/// Updates navigation objects and Drawbridge-generated links with qpdf instead of asking
/// PDFKit to re-encode every page. qpdf keeps page streams, fonts, and images intact.
enum PDFTKBookmarkWriter {
    private static let generatedLinkMarker = "DrawbridgeAutoSheetLink"
    private static let maximumNavigationGrowthRatio = 1.15
    private static let maximumNavigationGrowthBytes: Int64 = 5 * 1024 * 1024

    enum WriteResult: Equatable {
        case saved
        case unavailable
        case rejectedSizeGrowth
    }

    static func writeNavigation(
        in document: PDFDocument,
        sourceURL explicitSourceURL: URL? = nil,
        to destinationURL: URL,
        pageLabels: [Int: String]
    ) -> WriteResult {
        let sourceURL = explicitSourceURL ?? document.documentURL ?? destinationURL
        guard sourceURL.isFileURL,
              FileManager.default.fileExists(atPath: sourceURL.path),
              let executable = executableURL() else {
            return .unavailable
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DrawbridgeNavigationSave-\(UUID().uuidString)", isDirectory: true)
        let jsonURL = temporaryDirectory.appendingPathComponent("navigation.json")
        let outputURL = temporaryDirectory.appendingPathComponent(destinationURL.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            guard run(executable, arguments: ["--json=2", sourceURL.path, jsonURL.path]),
                  var json = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any],
                  updateNavigationJSON(&json, from: document, pageLabels: pageLabels),
                  JSONSerialization.isValidJSONObject(json) else {
                return .unavailable
            }
            try JSONSerialization.data(withJSONObject: json).write(to: jsonURL, options: .atomic)
            guard run(executable, arguments: [sourceURL.path, "--update-from-json=\(jsonURL.path)", outputURL.path]),
                  FileManager.default.fileExists(atPath: outputURL.path) else {
                return .unavailable
            }
            let sourceSize = try fileSize(at: sourceURL)
            let outputSize = try fileSize(at: outputURL)
            let allowedSize = max(
                sourceSize + maximumNavigationGrowthBytes,
                Int64(Double(sourceSize) * maximumNavigationGrowthRatio)
            )
            guard outputSize <= allowedSize else {
                return .rejectedSizeGrowth
            }
            try MainViewController.commitStagedSave(from: outputURL, to: destinationURL)
            return outlineMatches(document, writtenURL: destinationURL) ? .saved : .unavailable
        } catch {
            return .unavailable
        }
    }

    private static func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func executableURL() -> URL? {
        var candidates: [String] = []
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/qpdf").path)
        // Retained for development builds only. Release bundles ship qpdf inside Drawbridge.
        candidates += ["/opt/homebrew/bin/qpdf", "/usr/local/bin/qpdf", "/usr/bin/qpdf"]
        return candidates.lazy.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private static func run(_ executable: URL, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            // qpdf uses exit status 3 for recoverable input warnings. Architectural
            // exports often contain benign dangling xref entries; qpdf still produces
            // a valid JSON/PDF, and the caller independently verifies the output.
            return process.terminationStatus == 0 || process.terminationStatus == 3
        } catch {
            return false
        }
    }

    private static func updateNavigationJSON(
        _ json: inout [String: Any],
        from document: PDFDocument,
        pageLabels: [Int: String]
    ) -> Bool {
        guard var qpdf = json["qpdf"] as? [[String: Any]], qpdf.count >= 2,
              var maxObjectID = qpdf[0]["maxobjectid"] as? Int else {
            return false
        }
        var objects = qpdf[1]
        guard
              let trailer = objects["trailer"] as? [String: Any],
              let trailerValue = trailer["value"] as? [String: Any],
              let catalogReference = trailerValue["/Root"] as? String,
              var catalogObject = objects["obj:\(catalogReference)"] as? [String: Any],
              var catalog = catalogObject["value"] as? [String: Any],
              let pages = json["pages"] as? [[String: Any]] else {
            return false
        }
        let pageReferences = pages.compactMap { $0["object"] as? String }
        guard pageReferences.count == document.pageCount else { return false }

        guard updateGeneratedSheetLinks(
            in: &objects,
            pageReferences: pageReferences,
            document: document,
            nextObjectID: &maxObjectID
        ) else {
            return false
        }

        var nextObjectID = maxObjectID + 1
        let outlineRootID = nextObjectID
        nextObjectID += 1
        let rootReference = "\(outlineRootID) 0 R"
        let nodes = navigationNodes(from: document.outlineRoot, document: document)
        var assignedNodes: [NavigationNode] = []
        assignObjectIDs(to: nodes, parentReference: rootReference, nextObjectID: &nextObjectID, assignedNodes: &assignedNodes)

        var rootObject: [String: Any] = ["/Type": "/Outlines"]
        if let first = nodes.first, let last = nodes.last {
            rootObject["/First"] = "\(first.objectID) 0 R"
            rootObject["/Last"] = "\(last.objectID) 0 R"
            rootObject["/Count"] = nodes.reduce(0) { $0 + $1.totalCount }
        }
        objects["obj:\(rootReference)"] = ["value": rootObject]
        for node in assignedNodes {
            var value: [String: Any] = ["/Title": "u:\(node.title)", "/Parent": node.parentReference]
            if let previous = node.previousReference { value["/Prev"] = previous }
            if let next = node.nextReference { value["/Next"] = next }
            if let pageIndex = node.pageIndex, pageIndex >= 0, pageIndex < pageReferences.count {
                value["/Dest"] = [pageReferences[pageIndex], "/Fit"]
            }
            if let first = node.children.first, let last = node.children.last {
                let childCount = node.children.reduce(0) { $0 + $1.totalCount }
                value["/First"] = "\(first.objectID) 0 R"
                value["/Last"] = "\(last.objectID) 0 R"
                value["/Count"] = node.isOpen ? childCount : -childCount
            }
            objects["obj:\(node.objectID) 0 R"] = ["value": value]
        }

        catalog["/Outlines"] = rootReference
        if !pageLabels.isEmpty {
            let labelsObjectID = nextObjectID
            var nums: [Any] = []
            for (index, label) in pageLabels.sorted(by: { $0.key < $1.key }) where index >= 0 && index < pageReferences.count {
                nums.append(index)
                nums.append(["/P": "u:\(label)"])
            }
            if !nums.isEmpty {
                objects["obj:\(labelsObjectID) 0 R"] = ["value": ["/Nums": nums]]
                catalog["/PageLabels"] = "\(labelsObjectID) 0 R"
            }
        }
        catalogObject["value"] = catalog
        objects["obj:\(catalogReference)"] = catalogObject
        qpdf[0]["maxobjectid"] = max(nextObjectID - 1, maxObjectID)
        qpdf[1] = objects
        json["qpdf"] = qpdf
        return true
    }

    private static func navigationNodes(from root: PDFOutline?, document: PDFDocument) -> [NavigationNode] {
        guard let root else { return [] }
        return (0..<root.numberOfChildren).compactMap { root.child(at: $0) }.map { outline in
            NavigationNode(
                title: outline.label ?? "Untitled",
                pageIndex: outline.destination?.page.map(document.index(for:)),
                isOpen: outline.isOpen,
                children: navigationNodes(from: outline, document: document)
            )
        }
    }

    private static func assignObjectIDs(
        to nodes: [NavigationNode],
        parentReference: String,
        nextObjectID: inout Int,
        assignedNodes: inout [NavigationNode]
    ) {
        // Allocate a whole sibling set before writing /Prev and /Next references.
        // A depth-first one-pass assignment leaves forward sibling references at 0 0 R.
        for node in nodes {
            node.objectID = nextObjectID
            nextObjectID += 1
        }
        for index in nodes.indices {
            let node = nodes[index]
            node.parentReference = parentReference
            node.previousReference = index > 0 ? "\(nodes[index - 1].objectID) 0 R" : nil
            node.nextReference = index + 1 < nodes.count ? "\(nodes[index + 1].objectID) 0 R" : nil
            assignedNodes.append(node)
            assignObjectIDs(to: node.children, parentReference: "\(node.objectID) 0 R", nextObjectID: &nextObjectID, assignedNodes: &assignedNodes)
        }
    }

    private static func outlineMatches(_ expected: PDFDocument, writtenURL: URL) -> Bool {
        guard let written = PDFDocument(url: writtenURL) else { return false }
        return written.pageCount == expected.pageCount
            && written.outlineRoot?.numberOfChildren == expected.outlineRoot?.numberOfChildren
    }

    private struct GeneratedLink {
        let marker: String
        let bounds: NSRect
        let destinationPageIndex: Int
    }

    /// qpdf can replace just the /Annots entries created by Drawbridge. This keeps
    /// drawing streams, fonts, and images byte-for-byte out of the save path.
    private static func updateGeneratedSheetLinks(
        in objects: inout [String: Any],
        pageReferences: [String],
        document: PDFDocument,
        nextObjectID: inout Int
    ) -> Bool {
        let linksByPage = generatedLinksByPage(in: document)
        for (pageIndex, pageReference) in pageReferences.enumerated() {
            guard var pageObject = objects["obj:\(pageReference)"] as? [String: Any],
                  var pageValue = pageObject["value"] as? [String: Any] else {
                return false
            }
            let desiredLinks = linksByPage[pageIndex] ?? []
            var annotations = annotationReferences(from: pageValue["/Annots"], objects: objects)
            let reusableRefs = annotations.filter { isGeneratedLinkReference($0, objects: objects) }
            annotations.removeAll { isGeneratedLinkReference($0, objects: objects) }

            for (index, link) in desiredLinks.enumerated() {
                let reference: String
                if index < reusableRefs.count {
                    reference = reusableRefs[index]
                } else {
                    reference = "\(nextObjectID) 0 R"
                    nextObjectID += 1
                }
                objects["obj:\(reference)"] = [
                    "value": generatedLinkObject(link, pageReferences: pageReferences)
                ]
                annotations.append(reference)
            }

            if annotations.isEmpty {
                pageValue.removeValue(forKey: "/Annots")
            } else if let annotsReference = pageValue["/Annots"] as? String,
                      var annotsObject = objects["obj:\(annotsReference)"] as? [String: Any],
                      annotsObject["value"] is [Any] {
                annotsObject["value"] = annotations
                objects["obj:\(annotsReference)"] = annotsObject
            } else {
                pageValue["/Annots"] = annotations
            }
            pageObject["value"] = pageValue
            objects["obj:\(pageReference)"] = pageObject
        }
        return true
    }

    private static func generatedLinksByPage(in document: PDFDocument) -> [Int: [GeneratedLink]] {
        var result: [Int: [GeneratedLink]] = [:]
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let links = page.annotations.compactMap { annotation -> GeneratedLink? in
                guard let marker = generatedLinkMarker(in: annotation),
                      let destinationPage = (annotation.action as? PDFActionGoTo)?.destination.page else {
                    return nil
                }
                let destinationIndex = document.index(for: destinationPage)
                guard destinationIndex >= 0, destinationIndex < document.pageCount,
                      annotation.bounds.width > 0, annotation.bounds.height > 0 else {
                    return nil
                }
                return GeneratedLink(marker: marker, bounds: annotation.bounds, destinationPageIndex: destinationIndex)
            }
            if !links.isEmpty { result[pageIndex] = links }
        }
        return result
    }

    private static func generatedLinkMarker(in annotation: PDFAnnotation) -> String? {
        [annotation.contents, annotation.userName].compactMap { $0 }.first {
            $0.contains(generatedLinkMarker)
        }
    }

    private static func generatedLinkObject(_ link: GeneratedLink, pageReferences: [String]) -> [String: Any] {
        let rect = link.bounds.standardized
        return [
            "/Type": "/Annot",
            "/Subtype": "/Link",
            "/Rect": [rect.minX, rect.minY, rect.maxX, rect.maxY],
            "/Border": [0, 0, 0],
            "/Contents": "u:\(link.marker)",
            "/F": 4,
            "/A": ["/S": "/GoTo", "/D": [pageReferences[link.destinationPageIndex], "/Fit"]]
        ]
    }

    private static func annotationReferences(from rawValue: Any?, objects: [String: Any]) -> [String] {
        if let reference = rawValue as? String,
           let annotationObject = objects["obj:\(reference)"] as? [String: Any],
           let values = annotationObject["value"] as? [Any] {
            return values.compactMap { $0 as? String }
        }
        return (rawValue as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func isGeneratedLinkReference(_ reference: String, objects: [String: Any]) -> Bool {
        guard let annotationObject = objects["obj:\(reference)"] as? [String: Any],
              let value = annotationObject["value"] as? [String: Any] else {
            return false
        }
        return [value["/Contents"], value["/T"]].compactMap { $0 as? String }.contains {
            $0.contains(generatedLinkMarker)
        }
    }

    private final class NavigationNode {
        let title: String
        let pageIndex: Int?
        let isOpen: Bool
        let children: [NavigationNode]
        var objectID = 0
        var parentReference = ""
        var previousReference: String?
        var nextReference: String?
        var totalCount: Int { 1 + children.reduce(0) { $0 + $1.totalCount } }

        init(title: String, pageIndex: Int?, isOpen: Bool, children: [NavigationNode]) {
            self.title = title
            self.pageIndex = pageIndex
            self.isOpen = isOpen
            self.children = children
        }
    }
}
