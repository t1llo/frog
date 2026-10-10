import SwiftUI
import FrogCore

struct StatisticsView: View {
    @ObservedObject var statistics: ActivityStatisticsStore
    var onBack: (() -> Void)? = nil
    @State private var period = Period.allTime

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
        PageScroll {
            if let onBack {
                Button("Settings", systemImage: "chevron.left", action: onBack)
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(FrogStyle.muted)
            }
            PageHeader(title: "Statistics", subtitle: "Your activity in Frog, counted only on this Mac.")
            SettingsSection(title: "Local statistics") {
                CompactRow(title: "Record statistics", detail: "Aggregate counts only. No text, names, or activity is sent anywhere.") {
                    Toggle("Record statistics", isOn: Binding(get: { statistics.snapshot.recordingEnabled }, set: statistics.setRecordingEnabled))
                        .labelsHidden().toggleStyle(.switch).disabled(!statistics.loaded)
                }
                if !statistics.snapshot.recordingEnabled {
                    Text("Paused. Existing totals remain until you reset them.").font(.caption).foregroundStyle(FrogStyle.muted)
                }
                if let issue = statistics.issue { InlineIssue(message: issue) }
            }
            CompactSegments(values: Period.allCases, selected: period, title: { $0.rawValue }) { period = $0 }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                metric("Recordings", value: totals.dictations.formatted(), symbol: "mic")
                metric("Recording time", value: duration(totals.recordingSeconds), symbol: "clock")
                metric("Words dictated", value: totals.words.formatted(), symbol: "text.word.spacing")
                metric("Words per minute", value: totals.wordsPerMinute.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—", symbol: "speedometer")
            }
            SettingsSection(title: "Rules executed") {
                countRow("Successful rule runs", count: totals.ruleRuns)
                Divider()
                ForEach(ActivityRuleKind.allCases, id: \.self) { kind in
                    countRow(ruleTitle(kind), count: totals.ruleRuns(kind))
                }
            }
            SettingsSection(title: "Tool use") {
                ForEach(ActivityToolKind.allCases, id: \.self) { kind in
                    countRow(toolTitle(kind), count: totals.toolUses(kind))
                }
            }
            Text("Only completed actions count. Recording time excludes loading and transcription. Words per minute uses total words divided by recording time. Recent periods include today; daily totals are kept for 365 days. Rule runs and tool counts can overlap.")
                .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
            SettingsSection(title: "Storage") {
                CompactRow(title: "Reset all statistics", detail: "Permanently clears every total and daily count. Your recording choice is kept.") {
                    Button("Reset statistics", role: .destructive) { statistics.reset() }
                }
                Text("Independent of transformation history and configuration exports. Statistics start when this version is used; previous activity is not imported.")
                    .font(.system(size: 10)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.foregroundStyle(FrogStyle.ink).buttonStyle(FrogButtonStyle())
            .onAppear { statistics.reload() }
    }

    private func metric(_ title: String, value: String, symbol: String) -> some View {
        FrogCard {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                Text(value).font(.system(size: 24, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            }
        }.accessibilityElement(children: .combine)
    }
    private func countRow(_ title: String, count: Int) -> some View {
        CompactRow(title: title) { Text(count.formatted()).monospacedDigit().font(.system(size: 12, weight: .medium)) }
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
        case .snippetCopy: "Snippets copied"
        }
    }
}
