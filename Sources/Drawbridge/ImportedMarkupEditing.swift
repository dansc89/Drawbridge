import AppKit
import PDFKit
import CoreText

/// A frozen, small, annotation-only payload. Never serialize the drawing set to
/// transport an edit. Original foreign dictionaries are patched, not replaced.
struct ImportedMarkupEdit: Sendable {
    let metadata: Data
    let appearance: Data
    let fields: Set<String>
    static let allowedFields: Set<String> = ["/Contents", "/RC", "/DS", "/DA", "/DR", "/C", "/IC", "/BS", "/Border", "/CA", "/DrawbridgeStrokeOpacity", "/DrawbridgeFillOpacity"]
}

/// Rich text recovered from the foreign appearance keeps mixed fonts (including
/// bold headings) even when its creator omitted the optional /RC rich text field.
final class ImportedTextAnnotation: PDFAnnotation {
    let richText: NSAttributedString
    let originalBorder: ImportedTextBorder.Style?
    let textInsets: NSEdgeInsets
    let textRotation: Int
    let calloutOrigin:CGPoint
    init(source: PDFAnnotation, richText: NSAttributedString, sourceText: NSAttributedString? = nil, geometryOrigin:CGPoint? = nil) {
        self.richText = NSAttributedString(attributedString: richText)
        calloutOrigin=(source as? ImportedTextAnnotation)?.calloutOrigin ?? geometryOrigin ?? source.bounds.origin
        textRotation=((source.value(forAnnotationKey:PDFAnnotationKey(rawValue:"/Rotate")) as? NSNumber)?.intValue ?? 0) % 360
        textInsets=(source as? ImportedTextAnnotation)?.textInsets ?? ImportedTextContent.insets(source,rich:sourceText ?? richText,rotation:textRotation)
        if let old=source as? ImportedTextAnnotation { originalBorder=old.originalBorder }
        else if let style=ImportedTextContent.appearance(source).flatMap(ImportedTextBorder.read) {
            // PDFKit can omit FreeText dash operators when drawing an imported
            // appearance. Retain its standard border dictionary as a fallback.
            let dash=ImportedTextBorder.standardDash(source)
            originalBorder=ImportedTextBorder.Style(color:style.color,width:style.width,dash:style.dash.isEmpty ? dash:style.dash,phase:style.phase)
        } else {originalBorder=nil}
        let values = Dictionary(uniqueKeysWithValues: source.annotationKeyValues.compactMap { key,value -> (String,Any)? in
            guard let key = key as? String else { return nil }; return (key,value)
        })
        super.init(bounds:source.bounds, forType:.freeText, withProperties:values)
        contents=richText.string; font=source.font; fontColor=source.fontColor
        color=source.color; interiorColor=source.interiorColor; border=source.border?.copy() as? PDFBorder
        alignment=source.alignment
        removeAllAppearanceStreams()
    }
    override func copy(with zone: NSZone? = nil) -> Any { ImportedTextAnnotation(source:self,richText:richText) }
    required init?(coder:NSCoder) { fatalError("Imported editing annotations are frozen before serialization") }
    override func draw(with box:PDFDisplayBox,in context:CGContext) {
        guard shouldDisplay else { return }
        // Let PDFKit render the original box/border and callout geometry, then
        // draw the edited runs using vector glyphs instead of flattening text.
        context.saveGState();defer{context.restoreGState()}
        let alpha=MarkupStyle.strokeOpacity(self)
        context.setAlpha(alpha)
        let background=PDFAnnotation(bounds:bounds,forType:.freeText,withProperties:annotationKeyValues.reduce(into:[String:Any]()){ if let key=$1.key as? String { $0[key]=$1.value } })
        background.contents="";background.bounds=ImportedTextContent.textBox(self)
        for key in ["/RC","/RD","/CL","/Rotate"] {background.removeValue(forAnnotationKey:PDFAnnotationKey(rawValue:key))}
        background.font=font;background.fontColor=fontColor;background.color=color.withAlphaComponent(1)
        let noBorder=PDFBorder();noBorder.lineWidth=0;background.border=noBorder
        background.interiorColor=interiorColor;background.removeAllAppearanceStreams()
        background.draw(with:box,in:context)
        context.textMatrix = .identity
        if let style=originalBorder,style.width>0 {
            context.setStrokeColor(style.color.cgColor);context.setLineWidth(style.width)
            context.setLineDash(phase:style.phase,lengths:style.dash)
            let physical=ImportedTextContent.textBox(self)
            context.stroke(physical.insetBy(dx:style.width/2,dy:style.width/2))
            if let values=value(forAnnotationKey:PDFAnnotationKey(rawValue:"/CL")) as? [NSNumber],[4,6].contains(values.count),values.allSatisfy({$0.doubleValue.isFinite}) {
                let offset=CGPoint(x:bounds.minX-calloutOrigin.x,y:bounds.minY-calloutOrigin.y)
                let points=stride(from:0,to:values.count,by:2).map{CGPoint(x:values[$0].doubleValue+offset.x,y:values[$0+1].doubleValue+offset.y)}
                for i in 0..<(points.count-1) {
                    let a=points[i],b=points[i+1],padding=max(12,style.width*6)
                    let box=CGRect(x:min(a.x,b.x)-padding,y:min(a.y,b.y)-padding,width:abs(a.x-b.x)+padding*2,height:abs(a.y-b.y)+padding*2)
                    let line=PDFAnnotation(bounds:box,forType:.line,withProperties:nil)
                    line.startPoint=CGPoint(x:a.x-box.minX,y:a.y-box.minY);line.endPoint=CGPoint(x:b.x-box.minX,y:b.y-box.minY)
                    line.color=style.color;let border=PDFBorder();border.lineWidth=style.width;border.style=style.dash.isEmpty ? .solid:.dashed;border.dashPattern=style.dash.map{NSNumber(value:Double($0))};line.border=border
                    if i==0 {
                        let ending=value(forAnnotationKey:PDFAnnotationKey(rawValue:"/LE")) as? String ?? ""
                        switch ending.replacingOccurrences(of:"/",with:"") {
                        case "OpenArrow":line.startLineStyle = .openArrow
                        case "ClosedArrow":line.startLineStyle = .closedArrow
                        case "Circle":line.startLineStyle = .circle
                        case "Square":line.startLineStyle = .square
                        case "Diamond":line.startLineStyle = .diamond
                        default:break
                        }
                    }
                    line.draw(with: .mediaBox,in:context)
                }
            }
        }
        context.clip(to:bounds)
        context.translateBy(x:bounds.minX,y:bounds.minY)
        let transform=ImportedTextContent.rotationTransform(textRotation,size:bounds.size)
        context.concatenate(transform)
        let size=(abs(textRotation)%180 == 90) ? CGSize(width:bounds.height,height:bounds.width):bounds.size
        let rect=CGRect(x:textInsets.left,y:textInsets.bottom,width:max(1,size.width-textInsets.left-textInsets.right),height:max(1,size.height-textInsets.top-textInsets.bottom))
        context.clip(to:rect)
        let framesetter=CTFramesetterCreateWithAttributedString(richText)
        let suggested=CTFramesetterSuggestFrameSizeWithConstraints(framesetter,CFRange(location:0,length:0),nil,CGSize(width:max(1,rect.width),height:CGFloat.greatestFiniteMagnitude),nil)
        let area=CGRect(x:rect.minX,y:rect.maxY-max(rect.height,ceil(suggested.height)+2),width:max(1,rect.width),height:max(rect.height,ceil(suggested.height)+2))
        let frame=CTFramesetterCreateFrame(framesetter,CFRange(location:0,length:0),CGPath(rect:area,transform:nil),nil)
        CTFrameDraw(frame,context)
    }
}

@MainActor enum ImportedTextContent {
    static func read(_ annotation:PDFAnnotation)->NSAttributedString {
        if let custom=annotation as? ImportedTextAnnotation { return custom.richText }
        let contents=annotation.contents ?? ""
        let fallbackStyle=NSMutableParagraphStyle();fallbackStyle.alignment=annotation.alignment
        let fallback=NSAttributedString(string:contents,attributes:[.font:annotation.font ?? NSFont.systemFont(ofSize:13),.foregroundColor:annotation.fontColor ?? .black,.paragraphStyle:fallbackStyle])
        guard !contents.isEmpty, let data=appearance(annotation), let page=PDFDocument(data:data)?.page(at:0), let extracted=page.attributedString else{return fallback}
        // Appearance extraction adds layout line breaks. Align visible characters
        // to /Contents and retain the source's paragraph breaks, never OCR text.
        let source=extracted.string as NSString, target=contents as NSString
        let result=NSMutableAttributedString(attributedString:fallback);var j=0
        var mapping:[Int:Int]=[:]
        let white=CharacterSet.whitespacesAndNewlines
        for i in 0..<target.length {
            guard let scalar=UnicodeScalar(target.character(at:i)) else {return fallback}
            if white.contains(scalar) {continue}
            while j<source.length, let c=UnicodeScalar(source.character(at:j)),white.contains(c){j+=1}
            guard j<source.length,target.character(at:i)==source.character(at:j) else{return fallback}
            mapping[i]=j
            let attrs=extracted.attributes(at:j,effectiveRange:nil)
            if let font=attrs[.font] {result.addAttribute(.font,value:font,range:NSRange(location:i,length:1))}
            if let color=attrs[.foregroundColor] {result.addAttribute(.foregroundColor,value:color,range:NSRange(location:i,length:1))}
            j+=1
        }
        var start=0
        while start<target.length {
            let range=target.paragraphRange(for:NSRange(location:start,length:0))
            let style=NSMutableParagraphStyle();style.alignment=annotation.alignment;style.lineBreakMode = .byWordWrapping
            let font=result.attribute(.font,at:range.location,effectiveRange:nil) as? NSFont ?? annotation.font ?? NSFont.systemFont(ofSize:13)
            style.minimumLineHeight=font.pointSize*1.23
            if NSMaxRange(range)<target.length {
                let last=(range.location..<NSMaxRange(range)).reversed().first{mapping[$0] != nil}
                let next=(NSMaxRange(range)..<target.length).first{mapping[$0] != nil}
                if let last,let next,let a=page.selection(for:NSRange(location:mapping[last]!,length:1)),let b=page.selection(for:NSRange(location:mapping[next]!,length:1)) {
                    let rotation=(annotation.value(forAnnotationKey:PDFAnnotationKey(rawValue:"/Rotate")) as? NSNumber)?.intValue ?? 0
                    let inverse=rotationTransform(rotation,size:annotation.bounds.size).inverted()
                    style.paragraphSpacing=max(0,a.bounds(for:page).applying(inverse).minY-b.bounds(for:page).applying(inverse).minY-style.minimumLineHeight)
                }
            }
            result.addAttribute(.paragraphStyle,value:style,range:range);start=NSMaxRange(range)
        }
        return result
    }
    nonisolated static func rotationTransform(_ angle:Int,size:CGSize)->CGAffineTransform {
        switch (angle % 360 + 360) % 360 {
        case 90:return CGAffineTransform(translationX:size.width,y:0).rotated(by:.pi/2)
        case 180:return CGAffineTransform(translationX:size.width,y:size.height).rotated(by:.pi)
        case 270:return CGAffineTransform(translationX:0,y:size.height).rotated(by:3 * .pi/2)
        default:return .identity
        }
    }
    nonisolated static func textBox(_ annotation:PDFAnnotation)->CGRect {
        let bounds=annotation.bounds
        guard let rd=annotation.value(forAnnotationKey:PDFAnnotationKey(rawValue:"/RD")) as? [NSNumber],rd.count==4,rd.allSatisfy({$0.doubleValue.isFinite && $0.doubleValue>=0}) else{return bounds}
        let rect=CGRect(x:bounds.minX+rd[0].doubleValue,y:bounds.minY+rd[3].doubleValue,width:bounds.width-rd[0].doubleValue-rd[2].doubleValue,height:bounds.height-rd[1].doubleValue-rd[3].doubleValue)
        return rect.width>0 && rect.height>0 ? rect:bounds
    }
    nonisolated static func insets(_ annotation:PDFAnnotation,rich:NSAttributedString,rotation:Int)->NSEdgeInsets {
        if annotation.value(forAnnotationKey:PDFAnnotationKey(rawValue:"/RD")) != nil {
            let physical=textBox(annotation).offsetBy(dx:-annotation.bounds.minX,dy:-annotation.bounds.minY)
            let logical=physical.applying(rotationTransform(rotation,size:annotation.bounds.size).inverted())
            let size=abs(rotation)%180==90 ? CGSize(width:annotation.bounds.height,height:annotation.bounds.width):annotation.bounds.size
            return NSEdgeInsets(top:max(0,size.height-logical.maxY),left:max(0,logical.minX),bottom:max(0,logical.minY),right:max(0,size.width-logical.maxX))
        }
        guard rich.length>0,let data=appearance(annotation),let page=PDFDocument(data:data)?.page(at:0),let selection=page.selection(for:NSRange(location:0,length:1)) else{return .init()}
        let size=abs(rotation)%180==90 ? CGSize(width:annotation.bounds.height,height:annotation.bounds.width):annotation.bounds.size
        let glyph=selection.bounds(for:page).applying(rotationTransform(rotation,size:annotation.bounds.size).inverted())
        let font=rich.attribute(.font,at:0,effectiveRange:nil) as? NSFont ?? annotation.font ?? NSFont.systemFont(ofSize:13)
        let frame=CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(rich),CFRange(location:0,length:0),CGPath(rect:CGRect(origin:.zero,size:size),transform:nil),nil)
        var origin=CGPoint.zero
        guard CFArrayGetCount(CTFrameGetLines(frame))>0 else{return .init()}
        CTFrameGetLineOrigins(frame,CFRange(location:0,length:1),&origin)
        let top=max(0,origin.y-(glyph.minY-font.descender))
        let left=annotation.alignment == .left ? max(0,glyph.minX):0
        return NSEdgeInsets(top:top,left:left,bottom:0,right:left)
    }
    static func scaled(_ source:NSAttributedString,factor:CGFloat)->NSAttributedString {
        let rich=NSMutableAttributedString(attributedString:source)
        source.enumerateAttributes(in:NSRange(location:0,length:source.length)){attrs,range,_ in
            if let font=attrs[.font] as? NSFont {rich.addAttribute(.font,value:NSFont(descriptor:font.fontDescriptor,size:font.pointSize*factor) ?? font,range:range)}
            if let old=attrs[.paragraphStyle] as? NSParagraphStyle,let style=old.mutableCopy() as? NSMutableParagraphStyle {
                style.minimumLineHeight *= factor;style.maximumLineHeight *= factor;style.paragraphSpacing *= factor;style.lineSpacing *= factor
                rich.addAttribute(.paragraphStyle,value:style,range:range)
            }
        }
        return rich
    }
    static func replacing(_ source:NSAttributedString,with text:String)->NSAttributedString {
        let result=NSMutableAttributedString(attributedString:source)
        let before=Array(source.string),after=Array(text);var prefix=0,suffix=0
        while prefix<min(before.count,after.count),before[prefix]==after[prefix]{prefix+=1}
        while suffix<min(before.count,after.count)-prefix,before[before.count-1-suffix]==after[after.count-1-suffix]{suffix+=1}
        let start=String(before.prefix(prefix)).utf16.count
        let end=String(before.suffix(suffix)).utf16.count
        result.replaceCharacters(in:NSRange(location:start,length:source.length-start-end),with:String(after.dropFirst(prefix).dropLast(suffix)))
        return result
    }
    nonisolated static func appearance(_ annotation:PDFAnnotation)->Data? {
        let data=NSMutableData();var box=CGRect(origin:.zero,size:annotation.bounds.size)
        guard box.width>0,box.height>0,let consumer=CGDataConsumer(data:data),let ctx=CGContext(consumer:consumer,mediaBox:&box,nil) else{return nil}
        ctx.beginPDFPage(nil);ctx.translateBy(x:-annotation.bounds.minX,y:-annotation.bounds.minY)
        let previous=NSGraphicsContext.current;NSGraphicsContext.current=NSGraphicsContext(cgContext:ctx,flipped:false)
        let highlighted=annotation.isHighlighted;annotation.isHighlighted=false
        annotation.draw(with:.mediaBox,in:ctx);annotation.isHighlighted=highlighted;NSGraphicsContext.current=previous
        ctx.endPDFPage();ctx.closePDF();return data as Data
    }
    static func xhtml(_ content:NSAttributedString)->String {
        func escape(_ text:String)->String {text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")}
        var result="<body xmlns=\"http://www.w3.org/1999/xhtml\"><p style=\"white-space:pre-wrap\">"
        content.enumerateAttributes(in:NSRange(location:0,length:content.length)){attrs,range,_ in
            let font=attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize:13)
            let rgb=(attrs[.foregroundColor] as? NSColor ?? .black).usingColorSpace(.deviceRGB) ?? .black
            let traits=NSFontManager.shared.traits(of:font)
            let color=String(format:"#%02x%02x%02x",Int(rgb.redComponent*255),Int(rgb.greenComponent*255),Int(rgb.blueComponent*255))
            let css="font-family:\(font.familyName ?? "Helvetica");font-size:\(font.pointSize)pt;color:\(color);font-weight:\(traits.contains(.boldFontMask) ? "bold":"normal");font-style:\(traits.contains(.italicFontMask) ? "italic":"normal")"
            result += "<span style=\""+escape(css)+"\">"+escape((content.string as NSString).substring(with:range)).replacingOccurrences(of:"\n",with:"<br/>")+"</span>"
        }
        return result+"</p></body>"
    }
    static func freeze(_ annotation:PDFAnnotation,fields:Set<String>)->ImportedMarkupEdit {
        let doc=PDFDocument(),page=PDFPage();page.setBounds(CGRect(origin:.zero,size:CGSize(width:max(1,annotation.bounds.maxX+100),height:max(1,annotation.bounds.maxY+100))),for:.mediaBox);doc.insert(page,at:0)
        // Use an ordinary PDFKit annotation for standard editable metadata. Its
        // generated appearance is not used: the explicit live vector draw is.
        let values=annotation.annotationKeyValues.reduce(into:[String:Any]()){if let key=$1.key as? String{$0[key]=$1.value}}
        let copy=PDFAnnotation(bounds:annotation.bounds,forType:PDFAnnotationSubtype(rawValue:annotation.type ?? ""),withProperties:values)
        copy.contents=annotation.contents;copy.font=annotation.font;copy.fontColor=annotation.fontColor
        copy.color=annotation.color;copy.interiorColor=annotation.interiorColor;copy.border=annotation.border?.copy() as? PDFBorder
        copy.removeAllAppearanceStreams();page.addAnnotation(copy)
        return ImportedMarkupEdit(metadata:doc.dataRepresentation() ?? Data(),appearance:appearance(annotation) ?? Data(),fields:fields)
    }
}

@MainActor extension RectangleMarkupController {
    func canEditImportedAppearance(_ annotation:PDFAnnotation)->Bool {
        ImportedMarkupState.selectable(annotation) && annotation.type != "Stamp" && annotation.type != "Text" && annotation.type != "Caret"
    }
    @discardableResult func replaceImported(_ old:PDFAnnotation,with replacement:PDFAnnotation,on page:PDFPage,fields:Set<String>,action:String)->Bool {
        guard canEdit(),page.document===view?.document,old.page===page,!old.isReadOnly,!layerIsLocked(old),canEditImportedAppearance(old),let state=importedState,
              state.replace(old,with:replacement,fields:fields) else{return false}
        undo.registerUndo(withTarget:self){target in _=target.replaceImported(replacement,with:old,on:page,fields:fields,action:action)};undo.setActionName(action)
        let position=page.annotations.firstIndex{$0===old} ?? page.annotations.count
        page.removeAnnotation(old);page.addAnnotation(replacement)
        // PDFKit appends; restore exact stacking position without moving peers.
        let trailing=Array(page.annotations.dropFirst(position).filter{$0 !== replacement})
        for a in trailing{page.removeAnnotation(a)};for a in trailing{page.addAnnotation(a)}
        selected=replacement;applyLayerVisibility();changed(page,importedAppearanceChanged:true);return true
    }
    func editedImportedCopy(_ annotation:PDFAnnotation)->PDFAnnotation {
        if annotation.type=="FreeText" {let rich=ImportedTextContent.read(annotation);return ImportedTextAnnotation(source:annotation,richText:rich,sourceText:rich,geometryOrigin:importedState?.originalOrigin(annotation))}
        let copy=annotation.copy() as! PDFAnnotation
        copy.interiorColor=copy.interiorColor?.withAlphaComponent(MarkupStyle.fillOpacity(annotation))
        copy.removeAllAppearanceStreams();return copy
    }
    func editImportedText(_ annotation:PDFAnnotation,on page:PDFPage,text:String,size:CGFloat,rich:NSAttributedString?=nil) {
        let original=ImportedTextContent.read(annotation)
        var content=rich ?? ImportedTextContent.replacing(original,with:text)
        let mutable=NSMutableAttributedString(attributedString:content)
        let oldSize=max(1,annotation.font?.pointSize ?? size)
        if abs(size-oldSize)>0.001 { mutable.enumerateAttribute(.font,in:NSRange(location:0,length:mutable.length)){font,range,_ in
            let font=font as? NSFont ?? NSFont.systemFont(ofSize:oldSize)
            mutable.addAttribute(.font,value:NSFont(descriptor:font.fontDescriptor,size:font.pointSize*size/oldSize) ?? font,range:range)
        }}
        content=mutable
        let copy=ImportedTextAnnotation(source:annotation,richText:content,sourceText:original,geometryOrigin:importedState?.originalOrigin(annotation))
        copy.font=NSFont(descriptor:(annotation.font ?? NSFont.systemFont(ofSize:size)).fontDescriptor,size:size)
        copy.setValue("font: \(copy.font?.fontName ?? "Helvetica") \(size)pt",forAnnotationKey:PDFAnnotationKey(rawValue:"/DS"))
        copy.contents=text;copy.removeValue(forAnnotationKey:PDFAnnotationKey(rawValue:"/RC"))
        // /RC is refreshed from the edited runs, so other editors do not reopen stale text.
        copy.setValue(ImportedTextContent.xhtml(content),forAnnotationKey:PDFAnnotationKey(rawValue:"/RC"))
        _=replaceImported(annotation,with:copy,on:page,fields:["/Contents","/RC","/DA","/DS","/DR"],action:"Edit Text")
    }
}
