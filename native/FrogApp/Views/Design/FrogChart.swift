import Charts
import SwiftUI

/// One look for Frog's graphs and meters (docs/design.md, "Charts and meters"): a smooth 2-point line over a
/// fading fill, faint dashed grid lines, a live dot with a halo at the newest value, and a rounded chip on hover.
enum FrogChart {
    static let line = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
    /// A second series sits quieter than the main one.
    static let secondaryLine = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
    static let gridLine = StrokeStyle(lineWidth: 0.75, lineCap: .round, dash: [2, 4])

    /// The series colour fading to clear, top to bottom.
    static func areaFill(_ color: Color) -> LinearGradient {
        LinearGradient(stops: [.init(color: color.opacity(0.35), location: 0), .init(color: color.opacity(0.08), location: 0.7),
                               .init(color: color.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom)
    }

    /// The plot's corner: nested in the card around it, and gentler in the small popup graph.
    static func plotRadius(compact: Bool) -> CGFloat { compact ? FrogStyle.smallRadius : FrogStyle.controlRadius }

    /// Room the plot keeps at its ends so the live dot and its halo are never cut off by the clip.
    static let endInset: CGFloat = 8
    /// The column left of a percentage chart for its scale (`FrogChartScaleGutter`), so the labels never sit on the
    /// plot; the time axis under it starts this far in, under the plot's left edge.
    static let scaleGutter: CGFloat = 42
    /// Which corner the chip takes: away from the pointer, so it never covers what it names.
    static func chipAlignment(pointerAt fraction: Double) -> Alignment { fraction > 0.5 ? .topLeading : .topTrailing }
}

/// Faint dashed horizontal lines behind a chart whose y scale is 0 to 1.
struct FrogChartGrid: ChartContent {
    let values: [Double]
    var body: some ChartContent {
        ForEach(values, id: \.self) { value in
            RuleMark(y: .value("Grid", value)).lineStyle(FrogChart.gridLine).foregroundStyle(FrogStyle.hairline)
                .accessibilityHidden(true)
        }
    }
}

/// A point on a line: a filled dot with a soft halo. At the newest value it marks "now"; under the pointer
/// it marks the value read.
struct FrogChartPoint<X: Plottable>: ChartContent {
    let x: PlottableValue<X>
    let y: PlottableValue<Double>
    let color: Color
    var body: some ChartContent {
        PointMark(x: x, y: y).symbolSize(170).foregroundStyle(color.opacity(0.2)).accessibilityHidden(true)
        PointMark(x: x, y: y).symbolSize(34).foregroundStyle(color).accessibilityHidden(true)
    }
}

/// The thin rule under the pointer.
struct FrogChartRule<X: Plottable>: ChartContent {
    let x: PlottableValue<X>
    var body: some ChartContent {
        RuleMark(x: x).lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round)).foregroundStyle(FrogStyle.muted.opacity(0.4))
            .accessibilityHidden(true)
    }
}

extension View {
    /// Clips a chart's plot area to the rounded corner token.
    func frogChartPlot(compact: Bool) -> some View {
        chartPlotStyle { $0.clipShape(RoundedRectangle(cornerRadius: FrogChart.plotRadius(compact: compact), style: .continuous)) }
    }
}

/// The value chip a chart shows while the pointer is on it. It overlays the plot's top corner, so it stays inside.
struct FrogChartChip<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.font(FrogType.caption).monospacedDigit().lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(FrogStyle.panelSurface, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: FrogStyle.controlRadius, style: .continuous).strokeBorder(FrogStyle.hairline))
            .padding(4).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The 100%, 50% and 0% of a percentage chart in a column to its left, each centred on its gridline, as Activity
/// Monitor and Stocks label their scales, so no label sits on a line or on the plot.
struct FrogChartScaleGutter: View {
    let height: CGFloat
    /// The plot's padding above 100% and below 0%, as the chart's `chartYScale` range sets it.
    var inset: CGFloat = 6

    var body: some View {
        let top = inset, bottom = height - inset
        ZStack(alignment: .topLeading) {
            label("100%").position(x: FrogChart.scaleGutter / 2 - 4, y: top)
            label("50%").position(x: FrogChart.scaleGutter / 2 - 4, y: (top + bottom) / 2)
            label("0%").position(x: FrogChart.scaleGutter / 2 - 4, y: bottom)
        }
        .frame(width: FrogChart.scaleGutter, height: height)
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(FrogType.caption).monospacedDigit().foregroundStyle(FrogStyle.muted)
            .fixedSize().frame(width: FrogChart.scaleGutter - 8, alignment: .trailing)
    }
}

/// What a chart shows before it has a line: a dashed baseline and a calm note, at the chart's own height so
/// nothing around it moves when the first readings arrive.
struct FrogChartPlaceholder<Label: View>: View {
    let height: CGFloat
    @ViewBuilder let label: Label
    var body: some View {
        ZStack {
            Baseline().stroke(style: FrogChart.gridLine).foregroundStyle(FrogStyle.hairline).frame(height: 1).offset(y: height / 4)
            label.foregroundStyle(FrogStyle.muted)
        }.frame(maxWidth: .infinity).frame(height: height).accessibilityElement(children: .combine)
    }

    private struct Baseline: Shape {
        func path(in rect: CGRect) -> Path {
            Path { $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
        }
    }
}

/// A horizontal meter: a rounded track, a fill that is its level colour fading from lighter to full with a soft
/// highlight along the top, and an optional crisp tick. One thickness everywhere, popups and pages alike, so every
/// meter of a kind reads as the same object. The fill glides to a new value unless Reduce Motion is on.
struct FrogMeter: View {
    /// The one thickness of every meter and progress track.
    static let height: CGFloat = 6

    let fraction: Double
    let tint: Color
    /// Where a tick marks something on the same scale, such as the share of a window's time gone. It stands a
    /// little over the track on both sides without making the meter any taller.
    var tick: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let value = fraction.isFinite ? min(1, max(0, fraction)) : 0
        let height = Self.height
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(FrogStyle.track)
                if value > 0 {
                    Capsule().fill(LinearGradient(colors: [tint.opacity(0.65), tint], startPoint: .leading, endPoint: .trailing))
                        .overlay {
                            Capsule().fill(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0)], startPoint: .top, endPoint: .center))
                                .padding(.horizontal, height / 3)
                        }
                        .frame(width: max(height, geometry.size.width * value))
                }
            }
            .frame(height: height)
            .overlay(alignment: .leading) {
                if let tick, tick.isFinite {
                    Capsule().fill(FrogStyle.ink.opacity(0.6)).frame(width: 2, height: height + 4)
                        .offset(x: max(0, min(geometry.size.width - 2, (geometry.size.width * tick - 1).rounded())))
                }
            }
            .animation(reduceMotion ? nil : FrogMotion.reveal, value: value)
        }.frame(height: height).accessibilityHidden(true)
    }
}
