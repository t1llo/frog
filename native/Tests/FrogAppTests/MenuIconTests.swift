import AppKit
import XCTest
@testable import FrogApp

final class MenuIconTests: XCTestCase {
    func testPackagedMenuIconHasVisibleTemplatePixelsAndTransparentSurround() throws {
        let image = FrogMenuIcon.image
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 15))
        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var opaque = 0, transparent = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                if alpha > 0.8 { opaque += 1 }
                if alpha < 0.1 { transparent += 1 }
            }
        }
        XCTAssertGreaterThan(opaque, bitmap.pixelsWide * bitmap.pixelsHigh / 3)
        XCTAssertGreaterThan(transparent, bitmap.pixelsWide * bitmap.pixelsHigh / 5)
    }
}
