import Foundation
import XCTest
@testable import Drawbridge

final class PDFJSONPatchEncoderTests: XCTestCase {
    func testExpandsExponentTokensExactlyAndLeavesStringsUntouched() throws {
        let input = #"{"numbers":[1e+3,-9.9e-15,1.25E-2,0,1e-9],"text":"9.9e-15 \"1e+3\" \\ 1E-2"}"#
        let expected = #"{"numbers":[1000,-0.0000000000000099,0.0125,0,0.000000001],"text":"9.9e-15 \"1e+3\" \\ 1E-2"}"#
        let output = try PDFJSONPatchEncoder.expandingExponents(in: Data(input.utf8))
        XCTAssertEqual(String(decoding: output, as: UTF8.self), expected)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: output))
    }

    func testFoundationNumberEncodingRetainsTinyAndLargeValues() throws {
        let numbers: [Double] = [-9.9e-15, 1.234e-30, 1.25e20]
        let output = try PDFJSONPatchEncoder.data(withJSONObject: numbers)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: output) as? [Double], numbers)
        XCTAssertFalse(String(decoding: output, as: UTF8.self).lowercased().contains("e"))
        // Check very large numbers lexically: Foundation's conversion back to
        // Double from a long decimal can round differently from exponent input.
        let large = try PDFJSONPatchEncoder.expandingExponents(in: Data("2.5e100".utf8))
        XCTAssertEqual(String(decoding: large, as: UTF8.self), "25" + String(repeating: "0", count: 99))
    }

    func testRejectsUnboundedExpansionWithoutIntegerOverflow() {
        XCTAssertThrowsError(try PDFJSONPatchEncoder.expandingExponents(in: Data("1e-9223372036854775808".utf8)))
    }
}
