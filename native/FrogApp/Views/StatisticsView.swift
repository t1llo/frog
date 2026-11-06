import SwiftUI
import FrogCore

struct StatisticsView: View {
    @ObservedObject var statistics: ActivityStatisticsStore
    @State private var period = Period.allTime
    @State private var confirmingReset = false

    private enum Period: String, CaseIterable {
        case allTime = "All time", week = "7 days", month = "30 days"
    }
    private var totals: ActivityStatisticsTotals {
        switch period {
        case .allTime: statistics.snapshot.allTime
        case .week: statistics.snapshot.totals(lastDays: 7)
        case .month: statistics.snapshot.totals(lastDays: 30)
        }
    }

    var body: some View {
        FrogPage {
            // The toolbar's Back (⌘[) returns to Settings, which opens this page (MainView offers the step).
            FrogPageHeader(title: "Statistics", subtitle: "What you did with Frog, counted on this Mac")
            FrogSection("Local statistics") {
                FrogRow("Record statistics", caption: "Counts only, kept on this Mac") {
                    Toggle("Record statistics", isOn: Binding(get: { statistics.snapshot.recordingEnabled }, set: statistics.setRecordingEnabled))
                        .labelsHidden().toggleStyle(.frogSwitch).controlSize(.small).disabled(!statistics.loaded)
                }
                if !statistics.snapshot.recordingEnabled {
                    FrogRowNote(text: "Paused. Existing totals remain until you reset them.")
                }
                // Resetting sits with the switch that records; with nothing counted there is nothing to clear.
                if statistics.loaded, !Self.isEmpty(statistics.snapshot.allTime) {
                    FrogRow("Clear all counts") {
                        Button("Reset…", role: .destructive) { confirmingReset = true }.buttonStyle(.frog(.destructive))
                    }
                }
                if let issue = statistics.issue { InlineIssue(message: issue) }
            }
            if statistics.loaded, Self.isEmpty(statistics.snapshot.allTime) {
                // Rows of zeros say nothing; one calm note says when numbers arrive.
                VStack(alignment: .leading, spacing: FrogStyle.space8) {
                    FrogSectionHeader("Activity")
                    FrogEmptyState(symbol: "chart.bar.fill", title: "Nothing recorded yet",
                                   message: statistics.snapshot.recordingEnabled
                                       ? "Statistics appear after your first dictation or rule run."
                                       : "Turn on Record statistics to start counting.", tint: .gray)
                        .frogTableSurface()
                }
            } else {
                VStack(alignment: .leading, spacing: FrogStyle.space12) {
                    CompactSegments(values: Period.allCases, selected: period, title: { $0.rawValue }) { period = $0 }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: FrogStyle.space10), GridItem(.flexible())], spacing: FrogStyle.space10) {
                        metric("Recordings", value: totals.dictations.formatted(), symbol: "mic", zero: totals.dictations == 0)
                        metric("Recording time", value: duration(totals.recordingSeconds), symbol: "clock", zero: totals.recordingSeconds < 1)
                        metric("Words dictated", value: totals.words.formatted(), symbol: "text.word.spacing", zero: totals.words == 0)
                        metric("Words per minute", value: totals.wordsPerMinute.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—",
                               symbol: "speedometer", zero: totals.wordsPerMinute == nil)
                    }
                }
                FrogSection("Rules executed") {
                    countRow("Successful rule runs", count: totals.ruleRuns)
                    SectionCaption(text: "By kind").padding(.top, 6)
                    ForEach(ActivityRuleKind.allCases, id: \.self) { kind in
                        countRow(ruleTitle(kind), count: totals.ruleRuns(kind))
                    }
                }
                FrogSection("Tool use", footer: "Only completed actions count. Daily totals are kept for a year.") {
                    ForEach(ActivityToolKind.allCases, id: \.self) { kind in
                        countRow(toolTitle(kind), count: totals.toolUses(kind))
                    }
                }
            }
        }.foregroundStyle(FrogStyle.ink).buttonStyle(.frog())
            .onAppear { statistics.reload() }
            .confirmationDialog("Reset all statistics?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Reset statistics", role: .destructive) { statistics.reset() }
            } message: { Text("Every total and daily count will be permanently cleared. Your recording choice is kept.") }
    }

    /// Nothing counted at all: no recording, rule run or tool use.
    static func isEmpty(_ totals: ActivityStatisticsTotals) -> Bool {
        totals.dictations == 0 && totals.ruleRuns == 0 && ActivityToolKind.allCases.allSatisfy { totals.toolUses($0) == 0 }
    }

    private func metric(_ title: String, value: String, symbol: String, zero: Bool) -> some View {
        FrogCard {
            VStack(alignment: .leading, spacing: 8) {
                // The symbol in a fixed width, so the four titles start at the same place.
                HStack(spacing: FrogStyle.space6) {
                    Image(systemName: symbol).frame(width: 16)
                    Text(title)
                }.font(FrogType.small).foregroundStyle(FrogStyle.muted)
                Text(value).font(FrogType.title).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundStyle(zero ? FrogStyle.muted : FrogStyle.ink)
            }
        }.accessibilityElement(children: .combine)
    }
    private func countRow(_ title: String, count: Int) -> some View {
        FrogRow(title) {
            Text(count.formatted()).font(FrogType.bodyMedium).monospacedDigit().foregroundStyle(count == 0 ? FrogStyle.muted : FrogStyle.ink)
        }
    }
    private func duration(_ seconds: Double) -> String {
        let seconds = Int(seconds.rounded(.down))
        if seconds >= 3_600 { return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }
    private func ruleTitle(_ kind: ActivityRuleKind) -> String {
        switch kind {
        case .local: "Local text models"
        case .remote: "Remote providers"
        case .cli: "CLI text models"
        case .dictation: "Dictation rules"
        case .application: "Application rules"
        case .window: "Window rules"
        case .system: "System rules"
        }
    }
    private func toolTitle(_ kind: ActivityToolKind) -> String {
        switch kind {
        case .clipboardPaste: "Clipboard pastes"
        case .applicationCommand: "Application commands"
        case .windowCommand: "Window commands"
        case .systemCommand: "System commands"
        case .commandSelection: "Command bar selections"
        case .scriptRun: "Scripts completed"
        case .snippetCopy: "Notes pasted"
        }
    }
}
