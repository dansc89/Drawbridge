import Foundation

/// Literal PDFs, independent of PDFKit serialization/recovery. UTF-16BE titles
/// retain whitespace, destinationless groups, URI actions and hierarchy exactly.
enum BookmarkIndexFixtures {
    struct Item: Sendable {
        var title: String
        var children: [Item] = []
        var action = ""
    }
    static let items = [
        Item(title: "GENERAL NOTES", children: [
            Item(title: "  A101\t FLOOR\n PLAN  ", action: "/Dest [3 0 R /Fit]"),
            Item(title: "Group", children: [Item(title: "A102\u{A0}Detail, \"East\"", action: "/A << /S /GoTo /D [3 0 R /Fit] >>")]),
            Item(title: " \t", children: [Item(title: "a103 café", action: "/A << /S /URI /URI (https://example.invalid/) >>")])
        ]),
        Item(title: "A101 Plan"), Item(title: "A101 Plan"),
        Item(title: "\u{FEFF}B200\u{2000}\u{2028}Schedule\u{3000}"),
        Item(title: "É101 café"), Item(title: "A101 - FLOOR PLAN"),
        Item(title: "A101\u{85}Plan"), Item(title: "A101\u{200B}Plan"),
        Item(title: "No destination")
    ]
    static func pdf(_ roots: [Item]) -> Data {
        var objects = ["<< /Type /Catalog /Pages 2 0 R /Outlines 4 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>", ""]
        func build(_ items: [Item], parent: Int) -> [Int] {
            let ids = items.map { _ -> Int in objects.append(""); return objects.count }
            for (i, item) in items.enumerated() {
                let id = ids[i], children = build(item.children, parent: id)
                let title = "FEFF" + item.title.utf16.map { String(format: "%04X", $0) }.joined()
                var fields = "/Title <\(title)> /Parent \(parent) 0 R \(item.action)"
                if i > 0 { fields += " /Prev \(ids[i-1]) 0 R" }
                if i + 1 < ids.count { fields += " /Next \(ids[i+1]) 0 R" }
                if let first = children.first, let last = children.last { fields += " /First \(first) 0 R /Last \(last) 0 R /Count \(children.count)" }
                objects[id-1] = "<< \(fields) >>"
            }
            return ids
        }
        let ids = build(roots, parent: 4)
        objects[3] = ids.isEmpty ? "<< /Type /Outlines /Count 0 >>" : "<< /Type /Outlines /First \(ids.first!) 0 R /Last \(ids.last!) 0 R /Count \(ids.count) >>"
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (i, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(i+1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count+1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }
}
