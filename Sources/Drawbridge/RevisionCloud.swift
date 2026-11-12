import CoreGraphics
import Foundation

enum RevisionCloud {
    static func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard points.count >= 3, let first = points.first else { return path }
        let edges = zip(points, points.dropFirst() + [first])
        let area = edges.reduce(CGFloat.zero) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }
        let winding: CGFloat = area < 0 ? -1 : 1
        path.move(to: first)
        for (start, end) in edges {
            let dx = end.x - start.x, dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length.isFinite, length > 0 else { continue }
            let count = Int(min(256, max(1, ceil(length / 16))))
            let step = CGPoint(x: dx / CGFloat(count), y: dy / CGFloat(count))
            let bulgeScale = min(0.42, 6.72 * CGFloat(count) / length)
            let bulge = CGPoint(x: winding * step.y * bulgeScale, y: -winding * step.x * bulgeScale)
            for index in 0..<count {
                let a = CGPoint(x: start.x + CGFloat(index) * step.x, y: start.y + CGFloat(index) * step.y)
                let b = index == count - 1 ? end : CGPoint(x: a.x + step.x, y: a.y + step.y)
                path.addCurve(to: b,
                              control1: CGPoint(x: a.x + bulge.x, y: a.y + bulge.y),
                              control2: CGPoint(x: b.x + bulge.x, y: b.y + bulge.y))
            }
        }
        path.closeSubpath()
        return path
    }

    static func pdfPath(_ points: [CGPoint]) -> String {
        var commands: [String] = []
        path(points).applyWithBlock { pointer in
            let element = pointer.pointee
            func coordinates(_ index: Int) -> String {
                let point = element.points[index]
                return String(format: "%.6f %.6f", locale: Locale(identifier: "en_US_POSIX"), Double(point.x), Double(point.y))
            }
            switch element.type {
            case .moveToPoint: commands.append(coordinates(0) + " m")
            case .addCurveToPoint: commands.append(coordinates(0) + " " + coordinates(1) + " " + coordinates(2) + " c")
            case .closeSubpath: commands.append("h")
            default: break
            }
        }
        return commands.joined(separator: " ")
    }
}

extension CGPath {
    func mappedCloud(_ transform: (CGPoint) -> CGPoint) -> CGPath {
        let path = CGMutablePath()
        applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint: path.move(to: transform(element.points[0]))
            case .addCurveToPoint:
                path.addCurve(to: transform(element.points[2]), control1: transform(element.points[0]), control2: transform(element.points[1]))
            case .closeSubpath: path.closeSubpath()
            default: break
            }
        }
        return path
    }
}
