import XCTest
import PDFKit
@testable import Drawbridge

final class PDFLineworkSnappingTests: XCTestCase {
    func testEndpointsMidpointsAndIntersectionsUseZoomIndependentTolerance() {
        let index = PDFLineworkIndex(segments:[
            .init(a:CGPoint(x:10,y:10),b:CGPoint(x:110,y:10)),
            .init(a:CGPoint(x:30,y:0),b:CGPoint(x:30,y:30))])
        XCTAssertEqual(index.nearest(to:CGPoint(x:11,y:11),tolerance:3,endpoints:true,midpoints:false,intersections:false),CGPoint(x:10,y:10))
        XCTAssertEqual(index.nearest(to:CGPoint(x:61,y:10),tolerance:3,endpoints:false,midpoints:true,intersections:false),CGPoint(x:60,y:10))
        XCTAssertEqual(index.nearest(to:CGPoint(x:31,y:11),tolerance:3,endpoints:false,midpoints:false,intersections:true),CGPoint(x:30,y:10))
        XCTAssertNil(index.nearest(to:CGPoint(x:11,y:11),tolerance:0.5,endpoints:true,midpoints:false,intersections:false))
        XCTAssertNil(index.nearest(to:CGPoint(x:30,y:10),tolerance:3,endpoints:false,midpoints:false,intersections:false))
    }
    func testPaintedPDFPathsAndTransformsAreExtracted() throws {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data:data))
        var box = CGRect(x:0,y:0,width:300,height:300)
        let context = try XCTUnwrap(CGContext(consumer:consumer,mediaBox:&box,nil))
        context.beginPDFPage(nil)
        context.translateBy(x:40,y:50)
        context.move(to:CGPoint(x:10,y:10)); context.addLine(to:CGPoint(x:110,y:10)); context.strokePath()
        context.endPDFPage(); context.closePDF()
        let provider = try XCTUnwrap(CGDataProvider(data:data))
        let pdf = try XCTUnwrap(CGPDFDocument(provider))
        let index = PDFPathScanner.index(page:try XCTUnwrap(pdf.page(at:1)))
        XCTAssertEqual(index.nearest(to:CGPoint(x:51,y:60),tolerance:3,endpoints:true,midpoints:false,intersections:false),CGPoint(x:50,y:60))
    }

}
