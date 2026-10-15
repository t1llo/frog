import XCTest
import CoreGraphics
@testable import FrogCore

final class AXGeometryTests: XCTestCase {
    private let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testConvertsOnTheOnlyDisplay() {
        let rect = AXGeometry.cocoaRect(CGRect(x: 100, y: 200, width: 80, height: 20), primaryHeight: 900, screens: [primary])
        XCTAssertEqual(rect, CGRect(x: 100, y: 680, width: 80, height: 20))
    }

    func testConvertsOnADisplayAboveAndLeftOfThePrimary() {
        let second = CGRect(x: -1920, y: 900, width: 1920, height: 1080)
        // Accessibility y is negative above the primary display.
        let rect = AXGeometry.cocoaRect(CGRect(x: -500, y: -300, width: 60, height: 16), primaryHeight: 900, screens: [primary, second])
        XCTAssertEqual(rect, CGRect(x: -500, y: 1184, width: 60, height: 16))
    }

    func testKeepsACaretWithZeroWidth() {
        XCTAssertEqual(AXGeometry.cocoaRect(CGRect(x: 10, y: 10, width: 0, height: 18), primaryHeight: 900, screens: [primary]),
                       CGRect(x: 10, y: 872, width: 0, height: 18))
    }

    func testRejectsEmptyNonFiniteAndAbsurdSizes() {
        let bad: [CGRect] = [
            .zero,
            CGRect(x: 100, y: 100, width: 80, height: 0),
            CGRect(origin: CGPoint(x: 100, y: 100), size: CGSize(width: -80, height: 20)),
            CGRect(x: CGFloat.nan, y: 100, width: 80, height: 20),
            CGRect(x: 100, y: 100, width: CGFloat.infinity, height: 20),
            CGRect(x: 100, y: 100, width: 100_001, height: 20),
            CGRect(x: 100, y: 100, width: 80, height: 100_001)
        ]
        for rect in bad {
            XCTAssertNil(AXGeometry.cocoaRect(rect, primaryHeight: 900, screens: [primary]), "\(rect)")
        }
    }

    func testRejectsARectangleOnNoDisplay() {
        XCTAssertNil(AXGeometry.cocoaRect(CGRect(x: 3000, y: 100, width: 80, height: 20), primaryHeight: 900, screens: [primary]))
    }
}
