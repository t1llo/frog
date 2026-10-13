import AppKit
import SwiftUI
import XCTest
@testable import FrogApp

@MainActor final class UpdateReadinessTests: XCTestCase {
    func testMenuRowAppearsOnlyWhileAnUpdateWaitsForFrogToQuit() {
        let readiness = UpdateReadiness.shared
        defer { readiness.ready(nil) }
        readiness.ready(nil)
        XCTAssertEqual(rowHeight(), 0, accuracy: 0.5)
        readiness.ready("1.0.26")
        XCTAssertEqual(readiness.version, "1.0.26")
        XCTAssertEqual(rowHeight(), 30, accuracy: 0.5)
        readiness.ready("")
        XCTAssertEqual(rowHeight(), 0, accuracy: 0.5, "An update with no version to name is not announced")
    }

    private func rowHeight() -> CGFloat {
        NSHostingView(rootView: UpdateReadyRow(install: {}).frame(width: 282)).fittingSize.height
    }
}
