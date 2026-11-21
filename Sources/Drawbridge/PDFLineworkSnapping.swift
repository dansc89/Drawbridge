import AppKit
import PDFKit

/// A bounded spatial index of painted PDF paths, built once away from pointer events.
struct PDFLineworkIndex: Sendable {
    struct Segment: Sendable { let a: CGPoint; let b: CGPoint; var source: [Int]? = nil }
    struct NativeSelection: Sendable { let path: [Int]; let bounds: CGRect; let segments: [Segment]; let segmentCount: Int }
    let segments: [Segment]
    private let cells: [String: [Int]]
    private let paths: [[Int]: [Int]]
    private let cellSize: CGFloat = 36

    init(segments: [Segment]) {
        self.segments = segments
        var cells = [String: [Int]]()
        var references = 0
        for (index, line) in segments.enumerated() {
            guard [line.a.x,line.a.y,line.b.x,line.b.y].allSatisfy({ $0.isFinite && abs($0) < 1e7 }) else { continue }
            var x = Int(floor(line.a.x / cellSize)), y = Int(floor(line.a.y / cellSize))
            let endX = Int(floor(line.b.x / cellSize)), endY = Int(floor(line.b.y / cellSize))
            let dx = line.b.x-line.a.x, dy = line.b.y-line.a.y
            let stepX = dx < 0 ? -1 : 1, stepY = dy < 0 ? -1 : 1
            let deltaX = dx == 0 ? CGFloat.infinity : cellSize / abs(dx)
            let deltaY = dy == 0 ? CGFloat.infinity : cellSize / abs(dy)
            var nextX = dx == 0 ? CGFloat.infinity : (CGFloat(x + (stepX > 0 ? 1 : 0))*cellSize-line.a.x)/dx
            var nextY = dy == 0 ? CGFloat.infinity : (CGFloat(y + (stepY > 0 ? 1 : 0))*cellSize-line.a.y)/dy
            // Visit cells crossed by the segment, including long diagonal walls.
            // A bounding-box fill wastes space on cells containing no linework.
            for _ in 0..<4096 {
                guard references < 4_000_000 else { break }
                cells["\(x),\(y)", default: []].append(index)
                references += 1
                if x == endX && y == endY { break }
                if nextX < nextY { x += stepX; nextX += deltaX }
                else { y += stepY; nextY += deltaY }
            }
        }
        self.cells = cells
        var paths: [[Int]: [Int]] = [:]
        for (index, segment) in segments.enumerated() { if let source = segment.source { paths[source, default: []].append(index) } }
        self.paths = paths
    }
    func nativeSelection(at point: CGPoint, tolerance: CGFloat) -> NativeSelection? {
        guard point.x.isFinite, point.y.isFinite, tolerance.isFinite, tolerance > 0 else { return nil }
        let radius = min(tolerance, cellSize * 2)
        var nearby = Set<Int>(), best: [Int]?, distance = radius
        for y in Int(floor((point.y-radius)/cellSize))...Int(floor((point.y+radius)/cellSize)) {
            for x in Int(floor((point.x-radius)/cellSize))...Int(floor((point.x+radius)/cellSize)) { nearby.formUnion(cells["\(x),\(y)"] ?? []) }
        }
        for index in nearby.sorted() {
            let line = segments[index]
            guard let source = line.source else { continue }
            let dx = line.b.x-line.a.x, dy = line.b.y-line.a.y, length = dx*dx+dy*dy
            let t = length == 0 ? 0 : min(1, max(0, ((point.x-line.a.x)*dx+(point.y-line.a.y)*dy)/length))
            let d = hypot(point.x-(line.a.x+t*dx),point.y-(line.a.y+t*dy))
            if d < distance { distance = d; best = source }
        }
        guard let best, let ids = paths[best], let first = ids.first else { return nil }
        var minX = segments[first].a.x, maxX = minX, minY = segments[first].a.y, maxY = minY
        for index in ids { for p in [segments[index].a, segments[index].b] { minX = min(minX,p.x); maxX = max(maxX,p.x); minY = min(minY,p.y); maxY = max(maxY,p.y) } }
        return .init(path: best, bounds: CGRect(x:minX,y:minY,width:maxX-minX,height:maxY-minY), segments: ids.prefix(2000).map { segments[$0] }, segmentCount: ids.count)
    }

    func nearest(to point: CGPoint, tolerance: CGFloat, endpoints: Bool, midpoints: Bool, intersections: Bool) -> CGPoint? {
        guard tolerance.isFinite, tolerance > 0 else { return nil }
        let radius = min(tolerance, cellSize * 2)
        var ids = Set<Int>()
        for y in Int(floor((point.y-radius)/cellSize))...Int(floor((point.y+radius)/cellSize)) {
            for x in Int(floor((point.x-radius)/cellSize))...Int(floor((point.x+radius)/cellSize)) {
                ids.formUnion(cells["\(x),\(y)"] ?? [])
            }
        }
        var best: CGPoint?
        var distance = radius
        func consider(_ candidate: CGPoint) {
            let d = hypot(candidate.x-point.x, candidate.y-point.y)
            if d < distance { best = candidate; distance = d }
        }
        let nearby = ids.sorted().map { segments[$0] }
        for line in nearby {
            if endpoints { consider(line.a); consider(line.b) }
            if midpoints { consider(CGPoint(x: (line.a.x+line.b.x)/2, y: (line.a.y+line.b.y)/2)) }
        }
        if intersections {
            // Limit pair work to segments actually within the cursor's neighborhood.
            let candidates = nearby.filter { line in
                let dx = line.b.x-line.a.x, dy = line.b.y-line.a.y
                let length = dx*dx+dy*dy
                guard length > 0 else { return false }
                let t = max(0, min(1, ((point.x-line.a.x)*dx+(point.y-line.a.y)*dy)/length))
                return hypot(line.a.x+t*dx-point.x, line.a.y+t*dy-point.y) <= radius
            }.prefix(80)
            let lines = Array(candidates)
            for i in lines.indices { for j in lines.indices where j > i {
                let a = lines[i], b = lines[j]
                let dx = a.b.x-a.a.x, dy = a.b.y-a.a.y
                let ex = b.b.x-b.a.x, ey = b.b.y-b.a.y
                let cross = dx*ey-dy*ex
                guard abs(cross) > 1e-10 else { continue }
                let x = b.a.x-a.a.x, y = b.a.y-a.a.y
                let t = (x*ey-y*ex)/cross, u = (x*dy-y*dx)/cross
                if (0...1).contains(t), (0...1).contains(u) { consider(CGPoint(x: a.a.x+t*dx, y: a.a.y+t*dy)) }
            } }
        }
        return best
    }
}

final class PDFPathScanner {
    var matrix = CGAffineTransform.identity
    var stack = [CGAffineTransform]()
    var path = [PDFLineworkIndex.Segment]()
    var segments = [PDFLineworkIndex.Segment]()
    var current = CGPoint.zero
    var start = CGPoint.zero
    var optionalContent: CGPDFDictionaryRef?
    var markedVisibility = [Bool]()
    var visible: Bool { !markedVisibility.contains(false) }
    var depth = 0
    var operations = 0
    var selector: [Int] = []
    var paintOrdinal = 0
    func paint(close: Bool = false) {
        if close { line(start) }
        let id = selector + [paintOrdinal]; paintOrdinal += 1
        if visible { segments.append(contentsOf: path.prefix(max(0,500_000-segments.count)).map { .init(a:$0.a,b:$0.b,source:id) }) }
        path.removeAll(keepingCapacity: true)
    }
    let deadline = CFAbsoluteTimeGetCurrent() + 2
    func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
        operations += 1
        guard operations < 2_000_000, CFAbsoluteTimeGetCurrent() < deadline else { return nil }
        var result = [CGFloat](repeating: 0, count: count)
        for index in (0..<count).reversed() {
            var value: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &value), value.isFinite, abs(value) < 1e7 else { return nil }
            result[index] = value
        }
        return result
    }
    func line(_ point: CGPoint) {
        guard [point.x,point.y,current.x,current.y].allSatisfy({ $0.isFinite && abs($0) < 1e7 }) else { return }
        if path.count < 500_000 { path.append(.init(a: current, b: point)) }
        current = point
    }
    func scan(_ stream: CGPDFContentStreamRef) {
        guard depth < 12, segments.count < 500_000, CFAbsoluteTimeGetCurrent() < deadline,
              let table = CGPDFOperatorTableCreate() else { return }
        depth += 1
        defer { depth -= 1 }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let s = Unmanaged<PDFPathScanner>.fromOpaque(info!).takeUnretainedValue()
            if s.stack.count < 128 { s.stack.append(s.matrix) }
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let s = Unmanaged<PDFPathScanner>.fromOpaque(info!).takeUnretainedValue()
            if let value = s.stack.popLast() { s.matrix = value }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let s = Unmanaged<PDFPathScanner>.fromOpaque(info!).takeUnretainedValue()
            if let v = s.numbers(scanner, 6) { s.matrix = CGAffineTransform(a:v[0],b:v[1],c:v[2],d:v[3],tx:v[4],ty:v[5]).concatenating(s.matrix) }
        }
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            let s = Unmanaged<PDFPathScanner>.fromOpaque(info!).takeUnretainedValue()
            if let v = s.numbers(scanner, 2) { s.current = CGPoint(x:v[0],y:v[1]).applying(s.matrix); s.start = s.current }
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            let s = Unmanaged<PDFPathScanner>.fromOpaque(info!).takeUnretainedValue()
            if let v = s.numbers(scanner, 2) { s.line(CGPoint(x:v[0],y:v[1]).applying(s.matrix)) }
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            let s = Unmanaged<PDFPathScanner>.fromOpaque(info!).takeUnretainedValue()
            if let v = s.numbers(scanner, 4) {
                s.current = CGPoint(x:v[0],y:v[1]).applying(s.matrix); s.start = s.current
                for p in [CGPoint(x:v[0]+v[2],y:v[1]),CGPoint(x:v[0]+v[2],y:v[1]+v[3]),CGPoint(x:v[0],y:v[1]+v[3]),CGPoint(x:v[0],y:v[1])] { s.line(p.applying(s.matrix)) }
            }
        }
        for op in ["c", "v", "y"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                let s = Unmanaged<PDFPathScanner>.fromOpaque(info!).takeUnretainedValue()
                // Curves contribute endpoints, without inventing straight chords.
                var v: CGPDFReal = 0, u: CGPDFReal = 0
                if CGPDFScannerPopNumber(scanner, &v), CGPDFScannerPopNumber(scanner, &u) {
                    let p = CGPoint(x:u,y:v).applying(s.matrix)
                    s.path.append(.init(a:s.current,b:s.current)); s.path.append(.init(a:p,b:p)); s.current = p
                }
            }
        }
        CGPDFOperatorTableSetCallback(table, "h") { _, info in
            let s = Unmanaged<PDFPathScanner>.fromOpaque(info!).takeUnretainedValue(); s.line(s.start)
        }
        for op in ["S","f","F","f*","B","B*"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in
                let s = Unmanaged<PDFPathScanner>.fromOpaque(info!).takeUnretainedValue()
                s.paint()
            }
        }
        for op in ["s","b","b*"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in
                let s = Unmanaged<PDFPathScanner>.fromOpaque(info!).takeUnretainedValue()
                s.paint(close: true)
            }
        }
        CGPDFOperatorTableSetCallback(table, "BMC") { _, info in
            Unmanaged<PDFPathScanner>.fromOpaque(info!).takeUnretainedValue().markedVisibility.append(true)
        }
        CGPDFOperatorTableSetCallback(table, "BDC") { scanner, info in
            let s = Unmanaged<PDFPathScanner>.fromOpaque(info!).takeUnretainedValue()
            var object: CGPDFObjectRef?
            var tag: UnsafePointer<CChar>?
            guard CGPDFScannerPopObject(scanner,&object), CGPDFScannerPopName(scanner,&tag), let tag else { return }
            var isVisible = true
            if String(cString:tag) == "OC", let object {
                var name: UnsafePointer<CChar>?
                var group: CGPDFDictionaryRef?
                if CGPDFObjectGetValue(object,.name,&name), let name,
                   let resource = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner),"Properties",name) {
                    CGPDFObjectGetValue(resource,.dictionary,&group)
                } else { CGPDFObjectGetValue(object,.dictionary,&group) }
                isVisible = group.flatMap { group in s.optionalContent.flatMap { EmbeddedPDFLayers.visibility(group,properties:$0) } } == true
            }
            s.markedVisibility.append(isVisible)
        }
        CGPDFOperatorTableSetCallback(table, "EMC") { _, info in
            _ = Unmanaged<PDFPathScanner>.fromOpaque(info!).takeUnretainedValue().markedVisibility.popLast()
        }
        CGPDFOperatorTableSetCallback(table, "n") { _, info in Unmanaged<PDFPathScanner>.fromOpaque(info!).takeUnretainedValue().path.removeAll(keepingCapacity:true) }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let s = Unmanaged<PDFPathScanner>.fromOpaque(info!).takeUnretainedValue()
            let ordinal = s.paintOrdinal; s.paintOrdinal += 1
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let parent = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(parent, "XObject", name) else { return }
            var form: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &form), let form else { return }
            guard let dictionary = CGPDFStreamGetDictionary(form) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, String(cString:subtype) == "Form" else { return }
            var resources: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
            let content = CGPDFContentStreamCreateWithStream(form, resources ?? dictionary, parent)
            var group: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary,"OC",&group), let group,
               s.optionalContent.flatMap({ EmbeddedPDFLayers.visibility(group,properties:$0) }) != true { return }
            let saved = (s.matrix,s.stack,s.path,s.current,s.start,s.markedVisibility,s.selector,s.paintOrdinal)
            defer { (s.matrix,s.stack,s.path,s.current,s.start,s.markedVisibility,s.selector,s.paintOrdinal) = saved }
            var array: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
                var values = [CGFloat](repeating:0,count:6)
                for i in 0..<6 { CGPDFArrayGetNumber(array,i,&values[i]) }
                s.matrix = CGAffineTransform(a:values[0],b:values[1],c:values[2],d:values[3],tx:values[4],ty:values[5]).concatenating(s.matrix)
            }
            s.path = []; s.stack = []; s.selector.append(ordinal); s.paintOrdinal = 0; s.scan(content)
        }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
    }
    static func index(page: CGPDFPage) -> PDFLineworkIndex {
        let scanner = PDFPathScanner()
        if let root = page.document?.catalog {
            CGPDFDictionaryGetDictionary(root,"OCProperties",&scanner.optionalContent)
        }
        scanner.scan(CGPDFContentStreamCreateWithPage(page))
        return PDFLineworkIndex(segments: scanner.segments)
    }
}

@MainActor final class PDFLineworkSnapping {
    private weak var page: PDFPage?
    private var index: PDFLineworkIndex?
    private var generation = UUID()
    private static let queue = DispatchQueue(label: "drawbridge.linework", qos: .userInitiated)
    func prepare(_ page: PDFPage) {
        guard self.page !== page else { return }
        self.page = page; index = nil; generation = UUID()
        let generation = generation
        guard let reference = page.pageRef else { return }
        Self.queue.async { [weak self] in
            let result = PDFPathScanner.index(page: reference)
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.index = result
            }
        }
    }
    func nativeSelection(_ point: CGPoint, on page: PDFPage, tolerance: CGFloat) async -> PDFLineworkIndex.NativeSelection? {
        prepare(page)
        let currentGeneration = generation
        for _ in 0..<125 {
            guard !Task.isCancelled, generation == currentGeneration else { return nil }
            if let index { return index.nativeSelection(at: point, tolerance: tolerance) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
    func nearest(_ point: CGPoint, on page: PDFPage, tolerance: CGFloat, endpoints: Bool, midpoints: Bool, intersections: Bool) -> CGPoint? {
        prepare(page)
        return index?.nearest(to: point, tolerance: tolerance, endpoints: endpoints, midpoints: midpoints, intersections: intersections)
    }
}
