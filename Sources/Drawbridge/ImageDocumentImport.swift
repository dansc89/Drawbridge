import AppKit
import PDFKit
import ImageIO
import CoreImage
import CryptoKit
import UniformTypeIdentifiers

/// Images become ordinary, independently editable PDFs. Never bind PDF writers to a raster URL.
@MainActor enum ImageDocumentImport {
    static var openContentTypes: [UTType] {
        [.pdf, .image] + (CGImageSourceCopyTypeIdentifiers() as! [String]).compactMap(UTType.init)
    }

    static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf" || UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true
    }

    static func canOpen(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if isPDF(url) { return true }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 { return true }
        // AppKit supplies additional installed decoders, including SVG on supported systems.
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return false }
        return NSImage(contentsOf: url)?.isValid == true
    }

    static func droppedURL(from pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.first(where: canOpen)
    }

    static func pdfURL(for original: URL) throws -> URL {
        let original = original.standardizedFileURL.resolvingSymlinksInPath()
        let bytes = try Data(contentsOf: original)
        var key = Data(original.path.utf8); key.append(bytes)
        let digest = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        let folder = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Drawbridge/ImageDocuments/\(digest)", isDirectory: true)
        let output = folder.appendingPathComponent(original.lastPathComponent + ".pdf")
        // A stable backing identity also preserves edits when the image is dropped again.
        if FileManager.default.fileExists(atPath: output.path), PDFDocument(url: output) != nil { return output }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw CocoaError(.fileReadCorruptFile) }
        if let source = CGImageSourceCreateWithData(bytes as CFData, nil) {
            let count = CGImageSourceGetType(source).map { UTType($0 as String)?.conforms(to: .tiff) == true } == true ? CGImageSourceGetCount(source) : 1
            let renderer = CIContext(options: [.cacheIntermediates: false])
            for index in 0..<count {
                guard let decoded = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw CocoaError(.fileReadCorruptFile) }
                let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
                let oriented = CIImage(cgImage: decoded).oriented(forExifOrientation: orientation)
                guard let image = renderer.createCGImage(oriented, from: oriented.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw CocoaError(.fileReadCorruptFile) }
                var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                let mediaBox = withUnsafeBytes(of: &box) { Data($0) }
                context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
                context.draw(image, in: box)
                context.endPDFPage()
            }
            context.closePDF()
        } else {
            context.closePDF()
            guard let image = NSImage(contentsOf: original), let page = PDFPage(image: image) else { throw CocoaError(.fileReadCorruptFile) }
            let document = PDFDocument(); document.insert(page, at: 0)
            guard let fallback = document.dataRepresentation() else { throw CocoaError(.fileReadCorruptFile) }
            data.setData(fallback)
        }
        guard let check = PDFDocument(data: data as Data), check.pageCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (data as Data).write(to: output, options: .atomic)
        return output
    }
}
