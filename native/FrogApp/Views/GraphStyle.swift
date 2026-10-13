import SwiftUI

/// One look for Frog's graphs: a legend of small squares, a thin smooth line over a fading
/// fill, and a time axis that names only its two ends. No grid and no value scale; the
/// legend and the pointer give the numbers.
enum GraphStyle {
    static let line = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)

    static func fill(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color.opacity(0.3), color.opacity(0.02)], startPoint: .top, endPoint: .bottom)
    }

    /// "Now", "45 s ago", "10 min ago".
    static func ago(_ seconds: TimeInterval) -> String {
        let seconds = Int(max(0, seconds).rounded())
        if seconds < 5 { return "Now" }
        if seconds < 90 { return "\(seconds) s ago" }
        return "\(Int((Double(seconds) / 60).rounded())) min ago"
    }
}

/// A legend entry: a square in the line's colour, its name beside it and its value below.
struct GraphLegend<Value: View>: View {
    let color: Color
    let title: String
    var spacing: CGFloat = 3
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 7, height: 7)
                Text(title).font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineLimit(1)
            }
            value
        }.accessibilityElement(children: .combine)
    }
}

/// The baseline under a graph, marked at its start, middle and end and labelled at both ends.
struct GraphAxis: View {
    let leading: String
    let trailing: String

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 0) {
                mark; Spacer(minLength: 0); mark; Spacer(minLength: 0); mark
            }.padding(.horizontal, 1).accessibilityHidden(true)
            HStack {
                Text(leading)
                Spacer(minLength: 4)
                Text(trailing)
            }.font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(1)
        }
    }

    private var mark: some View {
        Rectangle().fill(FrogStyle.muted.opacity(0.6)).frame(width: 3.5, height: 3.5).rotationEffect(.degrees(45))
    }
}
