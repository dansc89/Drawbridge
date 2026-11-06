import AppKit
import PDFKit

/// Read the actual foreign appearance's stroke color/weight. FreeText /C is
/// commonly the background, not the border, and PDFKit otherwise substitutes black.
enum ImportedTextBorder {
    struct Style { let color:NSColor; let width:CGFloat;let dash:[CGFloat];let phase:CGFloat }
    private final class Probe {
        var color=NSColor.black
        var width:CGFloat=1
        var components=3
        var dash:[CGFloat]=[]
        var phase:CGFloat=0
        var stack:[(NSColor,CGFloat,Int,[CGFloat],CGFloat)]=[]
        var result:Style?
        var table:CGPDFOperatorTableRef?
        var depth=0
    }
    private static func state(_ info:UnsafeMutableRawPointer?)->Probe {Unmanaged<Probe>.fromOpaque(info!).takeUnretainedValue()}
    static func standardDash(_ annotation:PDFAnnotation)->[CGFloat] {
        if let border=annotation.border,border.style == .dashed,let values=border.dashPattern {
            let dash=values.compactMap{($0 as? NSNumber).map{CGFloat($0.doubleValue)}}
            if !dash.isEmpty{return dash}
        }
        if let bs=annotation.value(forAnnotationKey:PDFAnnotationKey(rawValue:"/BS")) as? [String:Any],let style=(bs["/S"] ?? bs["S"]) as? String,["D","/D"].contains(style),let values=(bs["/D"] ?? bs["D"]) as? [NSNumber],values.count<=64 {
            let dash=values.map{CGFloat($0.doubleValue)}
            return dash.allSatisfy{$0.isFinite && $0>=0} && dash.contains{$0>0} ? dash:[]
        }
        return []
    }
    static func read(_ data:Data)->Style? {
        guard let provider=CGDataProvider(data:data as CFData),let doc=CGPDFDocument(provider),let page=doc.page(at:1),let table=CGPDFOperatorTableCreate() else{return nil}
        let probe=Probe();probe.table=table
        CGPDFOperatorTableSetCallback(table,"q"){_,info in let s=ImportedTextBorder.state(info);s.stack.append((s.color,s.width,s.components,s.dash,s.phase))}
        CGPDFOperatorTableSetCallback(table,"Q"){_,info in let s=ImportedTextBorder.state(info);if let old=s.stack.popLast(){s.color=old.0;s.width=old.1;s.components=old.2;s.dash=old.3;s.phase=old.4}}
        CGPDFOperatorTableSetCallback(table,"RG"){scanner,info in
            var r:CGPDFReal=0,g:CGPDFReal=0,b:CGPDFReal=0
            if CGPDFScannerPopNumber(scanner,&b),CGPDFScannerPopNumber(scanner,&g),CGPDFScannerPopNumber(scanner,&r){ImportedTextBorder.state(info).color=NSColor(deviceRed:r,green:g,blue:b,alpha:1)}
        }
        CGPDFOperatorTableSetCallback(table,"G"){scanner,info in var g:CGPDFReal=0;if CGPDFScannerPopNumber(scanner,&g){ImportedTextBorder.state(info).color=NSColor(deviceWhite:g,alpha:1)}}
        CGPDFOperatorTableSetCallback(table,"K"){scanner,info in
            var c:CGPDFReal=0,m:CGPDFReal=0,y:CGPDFReal=0,k:CGPDFReal=0
            if CGPDFScannerPopNumber(scanner,&k),CGPDFScannerPopNumber(scanner,&y),CGPDFScannerPopNumber(scanner,&m),CGPDFScannerPopNumber(scanner,&c){ImportedTextBorder.state(info).color=NSColor(deviceCyan:c,magenta:m,yellow:y,black:k,alpha:1)}
        }
        CGPDFOperatorTableSetCallback(table,"CS"){scanner,info in
            var name:UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner,&name),let name else{return}
            let direct=String(cString:name);let state=ImportedTextBorder.state(info)
            if direct=="DeviceGray"{state.components=1;return}
            if direct=="DeviceCMYK"{state.components=4;return}
            if direct=="DeviceRGB"{state.components=3;return}
            guard let object=CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner),"ColorSpace",name) else{return}
            var array:CGPDFArrayRef?
            if CGPDFObjectGetValue(object,.array,&array),let array {
                var family:UnsafePointer<CChar>?
                if CGPDFArrayGetName(array,0,&family),let family {
                    switch String(cString:family) {
                    case "CalGray":state.components=1
                    case "CalRGB", "Lab":state.components=3
                    case "ICCBased":
                        var profile:CGPDFStreamRef?;var count:CGPDFInteger=3
                        if CGPDFArrayGetStream(array,1,&profile),let profile,let dict=CGPDFStreamGetDictionary(profile),CGPDFDictionaryGetInteger(dict,"N",&count),(1...4).contains(count){state.components=count}
                    default:break
                    }
                }
            }
        }
        for op in ["SC", "SCN"] { CGPDFOperatorTableSetCallback(table,op){scanner,info in
            var values:[CGFloat]=[],v:CGPDFReal=0
            let state=ImportedTextBorder.state(info)
            for _ in 0..<state.components {guard CGPDFScannerPopNumber(scanner,&v) else{return};values.insert(v,at:0)}
            switch values.count {
            case 1: state.color=NSColor(deviceWhite:values[0],alpha:1)
            case 3: state.color=NSColor(deviceRed:values[0],green:values[1],blue:values[2],alpha:1)
            case 4: state.color=NSColor(deviceCyan:values[0],magenta:values[1],yellow:values[2],black:values[3],alpha:1)
            default: break
            }
        }}
        CGPDFOperatorTableSetCallback(table,"d"){scanner,info in
            var phase:CGPDFReal=0;var array:CGPDFArrayRef?
            guard CGPDFScannerPopNumber(scanner,&phase),CGPDFScannerPopArray(scanner,&array),let array,CGPDFArrayGetCount(array)<=64,phase.isFinite else{return}
            var dash:[CGFloat]=[]
            for i in 0..<CGPDFArrayGetCount(array) {var n:CGPDFReal=0;guard CGPDFArrayGetNumber(array,i,&n),n.isFinite,n>=0 else{return};dash.append(n)}
            guard dash.isEmpty || dash.contains(where:{$0>0}) else{return}
            let state=ImportedTextBorder.state(info);state.dash=dash;state.phase=phase
        }
        CGPDFOperatorTableSetCallback(table,"w"){scanner,info in var w:CGPDFReal=0;if CGPDFScannerPopNumber(scanner,&w),w.isFinite{ImportedTextBorder.state(info).width=w}}
        for op in ["S","s","B","B*","b","b*"] {CGPDFOperatorTableSetCallback(table,op){_,info in let s=ImportedTextBorder.state(info);if s.result==nil{s.result=Style(color:s.color,width:s.width,dash:s.dash,phase:s.phase)}}}
        CGPDFOperatorTableSetCallback(table,"Do"){scanner,info in
            let s=ImportedTextBorder.state(info);guard s.depth<8,s.result==nil else{return}
            var name:UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner,&name),let name else{return}
            let parent=CGPDFScannerGetContentStream(scanner)
            guard let object=CGPDFContentStreamGetResource(parent,"XObject",name) else{return}
            var stream:CGPDFStreamRef?
            guard CGPDFObjectGetValue(object,.stream,&stream),let stream,let table=s.table else{return}
            guard let dict=CGPDFStreamGetDictionary(stream) else{return};var resources:CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(dict,"Resources",&resources)
            let content=CGPDFContentStreamCreateWithStream(stream,resources ?? dict,parent)
            let nested=CGPDFScannerCreate(content,table,info)
            let color=s.color,width=s.width,stack=s.stack,components=s.components,dash=s.dash,phase=s.phase;s.depth+=1
            _=CGPDFScannerScan(nested);s.depth-=1;s.color=color;s.width=width;s.stack=stack;s.components=components;s.dash=dash;s.phase=phase
        }
        let content=CGPDFContentStreamCreateWithPage(page)
        let scanner=CGPDFScannerCreate(content,table,Unmanaged.passUnretained(probe).toOpaque())
        guard CGPDFScannerScan(scanner) else{return nil}
        return probe.result
    }
}
