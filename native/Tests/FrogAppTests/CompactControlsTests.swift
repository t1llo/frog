import AppKit
import SwiftUI
import XCTest
@testable import FrogApp

@MainActor
final class CompactControlsTests: XCTestCase {
    /// A dropdown shows only its choice, so VoiceOver has to name it by the row it sits in.
    func testARowTellsItsControlsItsTitle() {
        let seen = Seen()
        let host = NSHostingView(rootView: VStack {
            CompactRow(title: "Theme") { Probe(name: "in a row", seen: seen) }
            CompactRow(title: "Microphone", detail: "Used for dictation.") { HStack { Probe(name: "nested in a row", seen: seen) } }
            Probe(name: "outside a row", seen: seen)
        })
        _ = host.fittingSize
        XCTAssertEqual(seen.titles["in a row"], .some("Theme"))
        XCTAssertEqual(seen.titles["nested in a row"], .some("Microphone"))
        XCTAssertEqual(seen.titles["outside a row"], .some(nil), "A control outside a row keeps the name it has")
    }

    func testADropdownInARowLaysOutAsBefore() {
        let host = NSHostingView(rootView: CompactRow(title: "Theme") {
            CompactMenu(value: "Tokyo Night") { Button("Tokyo Night") {}; Button("Frog") {} }
        }.frame(width: 520))
        // One line of FrogRow: the control and the row's vertical padding, at least the row height.
        XCTAssertEqual(host.fittingSize.height, max(FrogStyle.rowHeight, FrogStyle.controlHeight + 12), "The name is spoken, not drawn")
    }

    private final class Seen { var titles: [String: String?] = [:] }

    private struct Probe: View {
        let name: String
        let seen: Seen
        @Environment(\.compactRowTitle) private var title
        var body: some View {
            let _ = seen.titles[name] = title
            Color.clear.frame(width: 1, height: 1)
        }
    }
}
