import Foundation
import PDFKit

/// Updates navigation objects with qpdf instead of asking PDFKit to re-encode every page.
/// qpdf keeps page streams intact; PDFKit remains the fallback if link annotations changed.
enum PDFTKBookmarkWriter {
    private static let generatedLinkMarker = "DrawbridgeAutoSheetLink"

    static func writeNavigation(in document: PDFDocument, to destinationURL: URL, pageLabels: [Int: String]) -> Bool {
        let sourceURL = document.documentURL ?? destinationURL
        guard sourceURL.isFileURL,
              FileManager.default.fileExists(atPath: sourceURL.path),
              let executable = executableURL(),
              let sourceDocument = PDFDocument(url: sourceURL),
              generatedLinkCount(in: sourceDocument) == generatedLinkCount(in: document) else {
            return false
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
                return false
            }
            try JSONSerialization.data(withJSONObject: json).write(to: jsonURL, options: .atomic)
            guard run(executable, arguments: [sourceURL.path, "--update-from-json=\(jsonURL.path)", outputURL.path]),
                  FileManager.default.fileExists(atPath: outputURL.path) else {
                return false
            }
            try MainViewController.commitStagedSave(from: outputURL, to: destinationURL)
            return outlineMatches(document, writtenURL: destinationURL)
        } catch {
            return false
        }
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
            return process.terminationStatus == 0
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
              let maxObjectID = qpdf[0]["maxobjectid"] as? Int else {
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

    private static func generatedLinkCount(in document: PDFDocument) -> Int {
        (0..<document.pageCount).reduce(0) { count, index in
            guard let page = document.page(at: index) else { return count }
            return count + page.annotations.reduce(into: 0) { total, annotation in
                if (annotation.userName?.contains(generatedLinkMarker) ?? false) || (annotation.contents?.contains(generatedLinkMarker) ?? false) {
                    total += 1
                }
            }
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
