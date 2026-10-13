import AppKit
import SwiftUI
import XCTest
@testable import FrogApp

final class GraphStyleTests: XCTestCase {
    /// Set `FROG_TEST_GRAPH_SNAPSHOT` to a path prefix to keep the rendered charts as PNG files.
    @MainActor func testUsageChartLaysOutAtBothSizes() throws {
        _ = NSApplication.shared
        let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let buckets = (0..<30).map { index -> (date: Date, amount: Double) in
            let wave: Double = 2.5 + 2 * sin(Double(index) / 3)
            let burst: Double = index % 7 == 5 ? 6 : 0
            let quiet: Double = index % 6 == 0 ? -2.4 : 0
            return (day.addingTimeInterval(Double(index) * 86_400), wave + burst + quiet)
        }
        let steps = UsageTrend(buckets).steps
        let money: (Double) -> String = { "$" + String(format: "%.2f", $0) }
        for (compact, width) in [(true, CGFloat(300)), (false, CGFloat(640))] {
            let host = NSHostingView(rootView: UsageChartFixture(steps: steps, compact: compact, width: width, format: money))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, width, accuracy: 0.5)
            XCTAssertEqual(host.fittingSize.height, compact ? 168 : 274, accuracy: 30)
            guard let path = ProcessInfo.processInfo.environment["FROG_TEST_GRAPH_SNAPSHOT"] else { continue }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path + (compact ? "-compact" : "-wide") + ".png"))
        }
    }

    func testUsageTrendDrawsTheRunningTotalAsTheLineAndEachBucketAsABar() {
        let day = Date(timeIntervalSinceReferenceDate: 0)
        let steps = UsageTrend([2.0, 0, 6, 2].enumerated().map { (day.addingTimeInterval(Double($0.offset) * 86_400), $0.element) }).steps
        XCTAssertEqual(steps.map(\.total), [2, 2, 8, 10])
        XCTAssertEqual(steps.map(\.line), [0.2, 0.2, 0.8, 1])
        XCTAssertEqual(steps.map(\.bar), [UsageTrend.barShare / 3, 0, UsageTrend.barShare, UsageTrend.barShare / 3])
        XCTAssertEqual(steps.map(\.date), (0..<4).map { day.addingTimeInterval(Double($0) * 86_400) })
    }

    func testUsageTrendOfAnIdleOrUnreadablePeriodStaysOnTheBaseline() {
        let day = Date(timeIntervalSinceReferenceDate: 0)
        let idle = UsageTrend([(day, 0), (day.addingTimeInterval(86_400), 0)]).steps
        XCTAssertEqual(idle.map(\.line), [0, 0])
        XCTAssertEqual(idle.map(\.bar), [0, 0])
        let odd = UsageTrend([(day, -4), (day.addingTimeInterval(86_400), .nan), (day.addingTimeInterval(172_800), 5)]).steps
        XCTAssertEqual(odd.map(\.total), [0, 0, 5])
        XCTAssertEqual(odd.map(\.line), [0, 0, 1])
        XCTAssertTrue(UsageTrend([]).steps.isEmpty)
    }

    func testAxisNamesHowLongAgo() {
        XCTAssertEqual(GraphStyle.ago(0), "Now")
        XCTAssertEqual(GraphStyle.ago(45), "45 s ago")
        XCTAssertEqual(GraphStyle.ago(150), "3 min ago")
        XCTAssertEqual(GraphStyle.ago(600), "10 min ago")
        XCTAssertEqual(GraphStyle.ago(-3), "Now")
    }
}

private struct UsageChartFixture: View {
    let steps: [UsageTrend.Step]
    let compact: Bool
    let width: CGFloat
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            GraphLegend(color: FrogStyle.series, title: "Estimated API cost", spacing: 5) {
                Text(format(steps.last?.total ?? 0)).font(.system(size: compact ? 20 : 32, weight: .semibold)).monospacedDigit()
            }
            UsageTrendChart(steps: steps, compact: compact, hourly: false, timeZone: TimeZone(secondsFromGMT: 0)!, format: format)
        }.padding(14).frame(width: width).fixedSize(horizontal: false, vertical: true).background(FrogStyle.panelSurface)
    }
}
