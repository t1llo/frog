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
        // One menu row of the popup, like the rows beside it.
        let menuRow = NSHostingView(rootView: MenuActionRow(title: "Row", symbol: "gear", action: {}).frame(width: 282)).fittingSize.height
        XCTAssertEqual(rowHeight(), menuRow, accuracy: 0.5)
        readiness.ready("")
        XCTAssertEqual(rowHeight(), 0, accuracy: 0.5, "An update with no version to name is not announced")
    }

    private func rowHeight() -> CGFloat {
        NSHostingView(rootView: UpdateReadyRow(install: {}).frame(width: 282)).fittingSize.height
    }
}
