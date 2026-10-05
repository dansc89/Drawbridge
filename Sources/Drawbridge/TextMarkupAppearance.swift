import AppKit
import CoreText

/// Text appearances use vector glyph outlines, including fallback fonts. This avoids
/// font substitution in other viewers without rasterizing or touching the page.
enum TextMarkupAppearance {
    static func drawing(_ record: RectangleMarkupRecord) -> String {
        let font = CTFontCreateWithName("Helvetica" as CFString, record.fontSize, nil)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        let text = NSAttributedString(string: record.text, attributes: [.font:font, .paragraphStyle:paragraph])
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let area = CGRect(x:3,y:3,width:max(1,record.bounds.width-6),height:max(1,record.bounds.height-6))
        let frame = CTFramesetterCreateFrame(framesetter,CFRange(location:0,length:0),CGPath(rect:area,transform:nil),nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating:.zero,count:lines.count)
        CTFrameGetLineOrigins(frame,CFRange(location:0,length:0),&origins)
        var commands = "q 0 0 \(record.bounds.width) \(record.bounds.height) re W n \(record.red) \(record.green) \(record.blue) rg\n"
        for (index,line) in lines.enumerated() {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                var glyphs = [CGGlyph](repeating:0,count:count), positions = [CGPoint](repeating:.zero,count:count)
                CTRunGetGlyphs(run,CFRange(location:0,length:0),&glyphs)
                CTRunGetPositions(run,CFRange(location:0,length:0),&positions)
                for n in 0..<count {
                    var transform = CGAffineTransform(translationX:origins[index].x+positions[n].x,y:origins[index].y+positions[n].y)
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
