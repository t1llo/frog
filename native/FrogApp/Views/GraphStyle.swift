import SwiftUI

/// The text around Frog's graphs: a legend of small dots and a time axis that names only its two ends.
/// The lines, fills, grid and meters are in `Design/FrogChart.swift`.
enum GraphStyle {
    /// The number under a graph's legend, the figure a usage or system view leads with: 20 points in
    /// popups, 28 on pages. Every other text uses `FrogType`.
    static func legendValue(page: Bool) -> Font { .system(size: page ? 28 : 20, weight: .semibold) }
    /// A figure in a block beside the graph: a plan limit's use, free disk space, the battery's charge,
    /// a token total.
    static let figure = Font.system(size: 15, weight: .semibold)

    /// "Now", "45 s ago", "10 min ago".
    static func ago(_ seconds: TimeInterval) -> String {
        let seconds = Int(max(0, seconds).rounded())
        if seconds < 5 { return "Now" }
        if seconds < 90 { return "\(seconds) s ago" }
        return "\(Int((Double(seconds) / 60).rounded())) min ago"
    }
}

/// A legend entry: a dot in the line's colour, its name beside it and its value below.
struct GraphLegend<Value: View>: View {
    /// The colour of the line it names; nil for a figure with no line (System monitor's memory), which gets no dot.
    let color: Color?
    let title: String
    var spacing: CGFloat = 3
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack(spacing: 5) {
                if let color { Circle().fill(color).frame(width: 7, height: 7) }
                Text(title).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
            }
            value
        }.accessibilityElement(children: .combine)
    }
}

/// The time labels under a graph, at its start and end.
struct GraphAxis: View {
    let leading: String
    let trailing: String

    var body: some View {
        HStack {
            Text(leading)
            Spacer(minLength: 4)
            Text(trailing)
        }.font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
    }
}
