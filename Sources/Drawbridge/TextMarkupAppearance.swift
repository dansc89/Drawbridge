import AppKit
import CoreText

/// Text appearances use vector glyph outlines, including fallback fonts. This avoids
/// font substitution in other viewers without rasterizing or touching the page.
enum TextMarkupAppearance {
    static func frame(_ text: NSAttributedString, size: CGSize) -> CTFrame {
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let textWidth = max(1, size.width - 6)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude), nil)
        let height = max(ceil(suggested.height) + 1, size.height - 6)
        let area = CGRect(x: 3, y: size.height - 3 - height, width: textWidth, height: height)
        return CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: area, transform: nil), nil)
    }
    static func drawing(_ record: RectangleMarkupRecord) -> String {
        // PDFKit displays free text upright on rotated sheets. Store the same
        // orientation in the vector appearance used by other PDF readers.
        if record.textRotation != 0 {
            var upright = record
            upright.textRotation = 0
            let w = record.bounds.width, h = record.bounds.height
            if record.textRotation == 90 || record.textRotation == 270 {
                upright.bounds.size = CGSize(width: h, height: w)
            }
            let matrix: String
            switch record.textRotation {
            case 90: matrix = "0 1 -1 0 \(w) 0"
            case 180: matrix = "-1 0 0 -1 \(w) \(h)"
            case 270: matrix = "0 -1 1 0 0 \(h)"
            default: matrix = "1 0 0 1 0 0"
            }
            return "q \(matrix) cm\n" + drawing(upright) + "Q\n"
        }
        let style = record.textBoxAppearance ?? TextBoxAppearance()
        let text = style.attributed(record.text, size: record.fontSize, color: .black, alignment: .left)
        let frame = frame(text, size: record.bounds.size)
        let area = CTFrameGetPath(frame).boundingBox
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating:.zero,count:lines.count)
        CTFrameGetLineOrigins(frame,CFRange(location:0,length:0),&origins)
        var commands = "q 0 0 \(record.bounds.width) \(record.bounds.height) re W n\n"
        if let fill = style.fill {
            commands += "q /TextFillGS gs \(fill[0]) \(fill[1]) \(fill[2]) rg 0 0 \(record.bounds.width) \(record.bounds.height) re f Q\n"
        }
        if style.borderWidth > 0 {
            let inset = style.borderWidth / 2
            let dash = (MarkupLinePattern(rawValue: style.borderPattern) ?? .solid).dash(width: style.borderWidth).map { String($0) }.joined(separator: " ")
            commands += "q /TextBorderGS gs \(style.borderColor[0]) \(style.borderColor[1]) \(style.borderColor[2]) RG \(style.borderWidth) w [\(dash)] 0 d \(inset) \(inset) \(record.bounds.width-style.borderWidth) \(record.bounds.height-style.borderWidth) re S Q\n"
        }
        commands += "/TextInkGS gs \(record.red) \(record.green) \(record.blue) rg\n"
        for (index,line) in lines.enumerated() {
            if style.underline {
                let font = style.font(size: record.fontSize) as CTFont
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                commands += "\(area.minX+origins[index].x) \(area.minY+origins[index].y+CTFontGetUnderlinePosition(font)) \(width) \(max(0.5,CTFontGetUnderlineThickness(font))) re f\n"
            }
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                var glyphs = [CGGlyph](repeating:0,count:count), positions = [CGPoint](repeating:.zero,count:count)
                CTRunGetGlyphs(run,CFRange(location:0,length:0),&glyphs)
                CTRunGetPositions(run,CFRange(location:0,length:0),&positions)
                for n in 0..<count {
                    var transform = CGAffineTransform(translationX:area.minX+origins[index].x+positions[n].x,
                                                      y:area.minY+origins[index].y+positions[n].y)
                    guard let path = CTFontCreatePathForGlyph(runFont,glyphs[n],&transform) else { continue }
                    var current = CGPoint.zero, beginning = CGPoint.zero
                    path.applyWithBlock { element in
                        let e = element.pointee, p = e.points
                        switch e.type {
                        case .moveToPoint: current = p[0]; beginning = current; commands += "\(p[0].x) \(p[0].y) m\n"
                        case .addLineToPoint: current = p[0]; commands += "\(p[0].x) \(p[0].y) l\n"
                        case .addCurveToPoint: current = p[2]; commands += "\(p[0].x) \(p[0].y) \(p[1].x) \(p[1].y) \(p[2].x) \(p[2].y) c\n"
                        case .closeSubpath: current = beginning; commands += "h\n"
                        case .addQuadCurveToPoint:
                            let a = CGPoint(x:current.x+(p[0].x-current.x)*2/3,y:current.y+(p[0].y-current.y)*2/3)
                            let b = CGPoint(x:p[1].x+(p[0].x-p[1].x)*2/3,y:p[1].y+(p[0].y-p[1].y)*2/3)
                            commands += "\(a.x) \(a.y) \(b.x) \(b.y) \(p[1].x) \(p[1].y) c\n"; current = p[1]
                        @unknown default: break
                        }
                    }
                    commands += "f\n"
                }
            }
        }
        return commands + "Q\n"
    }
}
