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
            if statistics.loaded, Self.isEmpty(statistics.snapshot.allTime) {
                // Nothing counted yet: one card, no heading. Rows of zeros say nothing; one calm note says when
                // numbers arrive, with the switch that counts them under it as the note's one control.
                FrogSection {
                    FrogEmptyState(symbol: "chart.bar.fill", title: "Nothing recorded yet",
                                   message: statistics.snapshot.recordingEnabled
                                       ? "Statistics appear after your first dictation or rule run. Only counts are kept, on this Mac."
                                       : "Turn on Record statistics to start counting. Only counts are kept, on this Mac.", tint: .gray) {
                        HStack(spacing: FrogStyle.space10) {
                            Text("Record statistics").font(FrogType.row)
                            recordingToggle
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: FrogStyle.space12) {
                    CompactSegments(values: Period.allCases, selected: period, title: { $0.rawValue }) { period = $0 }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: FrogStyle.space10), GridItem(.flexible())], spacing: FrogStyle.space10) {
                        metric("Recordings", value: Self.number(totals.dictations), symbol: "mic", zero: totals.dictations == 0)
                        metric("Recording time", value: duration(totals.recordingSeconds), symbol: "clock", zero: totals.recordingSeconds < 1)
                        metric("Words dictated", value: Self.number(totals.words), symbol: "text.word.spacing", zero: totals.words == 0)
                        metric("Words per minute", value: totals.wordsPerMinute.map { $0.formatted(.number.precision(.fractionLength(0)).locale(L10n.locale)) } ?? "—",
                               symbol: "speedometer", zero: totals.wordsPerMinute == nil)
                    }
                }
                // The total belongs to the heading, as every counted group's does, so the card holds one group:
                // the runs by kind.
                FrogSection("Rule runs", count: totals.ruleRuns) {
                    ForEach(ActivityRuleKind.allCases, id: \.self) { kind in
                        countRow(ruleTitle(kind), count: totals.ruleRuns(kind))
                    }
                }
                FrogSection("Tool use", count: ActivityToolKind.allCases.reduce(0) { $0 + totals.toolUses($1) },
                            footer: "Only completed runs count. Daily totals are kept for a year.") {
                    ForEach(ActivityToolKind.allCases, id: \.self) { kind in
                        countRow(toolTitle(kind), count: totals.toolUses(kind))
                    }
                }
                // Recording and resetting close the page, under their own heading, two rows with the counts there.
                FrogSection("Recording") { recordingRows }
            }
        }.foregroundStyle(FrogStyle.ink).buttonStyle(.frog())
            .onAppear { statistics.reload() }
            .confirmationDialog("Reset all statistics?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Reset statistics", role: .destructive) { statistics.reset() }
            } message: { Text("Every total and daily count will be permanently cleared. Your recording choice is kept.") }
    }

    private var recordingToggle: some View {
        Toggle("Record statistics", isOn: Binding(get: { statistics.snapshot.recordingEnabled }, set: statistics.setRecordingEnabled))
            .labelsHidden().toggleStyle(.frogSwitch).controlSize(.small).disabled(!statistics.loaded)
    }

    /// Whether statistics are recorded, and clearing them once there is something counted.
    @ViewBuilder private var recordingRows: some View {
        FrogRow("Record statistics", caption: "Counts only, kept on this Mac") {
            recordingToggle
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

    /// Nothing counted at all: no recording, rule run or tool use.
    static func isEmpty(_ totals: ActivityStatisticsTotals) -> Bool {
        totals.dictations == 0 && totals.ruleRuns == 0 && ActivityToolKind.allCases.allSatisfy { totals.toolUses($0) == 0 }
    }

    /// A count in English digits ("1,276"), whatever region the Mac is set to, as the rest of the interface is English.
    static func number(_ value: Int) -> String { value.formatted(.number.locale(L10n.locale)) }

    /// One figure: its tile and name on top, the number large under them, as Activity and Screen Time set a figure.
    private func metric(_ title: String, value: String, symbol: String, zero: Bool) -> some View {
        FrogCard {
            VStack(alignment: .leading, spacing: FrogStyle.space10) {
                HStack(spacing: FrogStyle.space8) {
                    PluginIconTile(symbol: symbol, tint: DictationPlugin.info.tint.color, size: .sidebar)
                    Text(L10n.text(title)).font(FrogType.row).foregroundStyle(FrogStyle.ink).lineLimit(1)
                }
                Text(value).font(FrogType.title).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundStyle(zero ? FrogStyle.muted : FrogStyle.ink)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .combine)
    }
    private func countRow(_ title: String, count: Int) -> some View {
        FrogRow(title) {
            Text(Self.number(count)).font(FrogType.body).monospacedDigit().foregroundStyle(count == 0 ? FrogStyle.muted : FrogStyle.ink)
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
