import AppKit
import SwiftUI
import FrogCore

/// The texts and buttons of one record in Recently moved, decided apart from the view so they are tested.
struct RecentlyMovedRow: Identifiable {
    let record: RemovalRecord
    /// "12 items · 1.4 GB", "12 items · at least 1.4 GB" when a size is unknown, or "12 items" when none is known.
    let detail: String
    /// "3 put back", or nil while nothing is back.
    let restoredText: String?
    /// Some item Frog may put back itself is still in the Trash.
    let canPutBack: Bool
    /// Some item still in the Trash needs Finder's Put Back: an administrator's item, or one Finder gave no place for.
    let needsFinder: Bool
    var id: UUID { record.id }

    init(_ record: RemovalRecord, formatBytes: (Int64) -> String = CleanerFormat.bytes) {
        self.record = record
        let count = record.entries.count
        let items = "\(count) \(count == 1 ? "item" : "items")"
        let known = record.entries.compactMap(\.bytes)
        if known.isEmpty {
            detail = items
        } else {
            let bytes = formatBytes(known.reduce(0, +))
            detail = items + " · " + (known.count < count ? "at least \(bytes)" : bytes)
        }
        let restored = record.entries.filter(\.restored).count
        restoredText = restored == 0 ? nil : "\(restored) put back"
        let waiting = record.entries.filter { !$0.restored }
        canPutBack = waiting.contains(where: \.restorable)
        needsFinder = waiting.contains { !$0.restorable }
    }

    /// What the disclosure says about one item.
    static func state(of entry: RemovalRecord.Entry) -> String {
        if entry.restored { return "Put back" }
        if entry.trashed == nil { return "Finder did not say where it went · Use Put Back in Finder" }
        if !entry.restorable { return "Use Put Back in Finder" }
        return "In the Trash"
    }
}

/// "Recently moved": what Frog moved to the Trash in the last 30 days, with Put Back per removal.
struct CleanerRestoreView: View {
    @ObservedObject var cleaner: CleanerModel
    @State private var expanded: Set<UUID> = []

    private var roots: CleanerRoots { cleaner.dependencies.roots }
    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Recently moved").font(.system(size: 14, weight: .medium))
                Text("Items Frog moved to the Trash in the last 30 days.").font(FrogType.body).foregroundStyle(FrogStyle.muted)
            }
            if let issue = cleaner.issue { InlineIssue(message: issue) }
            if let summary = cleaner.putBackSummary {
                CleanerPutBackSummaryView(summary: summary, roots: roots)
            } else if cleaner.records.isEmpty {
                FrogEmptyState(symbol: "tray", title: "Nothing moved yet",
                               message: "Items you move to the Trash with Frog appear here for 30 days.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(cleaner.records.map { RecentlyMovedRow($0) }) { row in
                            recordRow(row)
                            if row.id != cleaner.records.last?.id { Divider().opacity(0.4) }
                        }
                    }
                }
                .frame(maxHeight: 330).fixedSize(horizontal: false, vertical: true)
                .frogTableSurface()
            }
            Text("Items stay in the Trash until you empty it. After that, Frog cannot put them back.")
                .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                // After a Put Back, Done returns to the list; otherwise it closes the sheet.
                Button("Done") {
                    if cleaner.putBackSummary != nil { cleaner.dismissPutBack() } else { cleaner.showsRecent = false }
                }
                .buttonStyle(FrogButtonStyle(primary: true)).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 520).frame(maxHeight: 520)
        .buttonStyle(FrogButtonStyle())
        .foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent)
    }

    private func recordRow(_ row: RecentlyMovedRow) -> some View {
        let record = row.record, open = expanded.contains(record.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    if open { expanded.remove(record.id) } else { expanded.insert(record.id) }
                } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FrogStyle.muted).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(open ? "Hide items" : "Show items")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(record.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(Self.relativeDate.localizedString(for: record.date, relativeTo: Date()))
                            .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineLimit(1)
                    }
                    Text([row.detail, row.restoredText].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(FrogStyle.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                if cleaner.puttingBack == record.id { ProgressView().controlSize(.small) }
                if row.needsFinder { Button("Put Back in Finder") { openTrash() } }
                Button("Put Back") { Task { await cleaner.putBack(record.id) } }
                    .disabled(!row.canPutBack || cleaner.puttingBack != nil)
                Button { cleaner.forget(record.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).foregroundStyle(FrogStyle.muted)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(cleaner.puttingBack == record.id)
                .accessibilityLabel("Remove from this list").help("Forgets the record. The items stay where they are.")
            }
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(record.entries, id: \.original) { entry in
                        HStack(spacing: 8) {
                            Text(roots.displayPath(URL(fileURLWithPath: entry.original))).font(.system(size: 11))
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Spacer(minLength: 8)
                            Text(RecentlyMovedRow.state(of: entry)).font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                                .lineLimit(1)
                        }
                    }
                }.padding(.leading, 26)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    /// Finder's Put Back handles administrator items and items Frog has no Trash location for.
    private func openTrash() {
        let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? roots.home.appendingPathComponent(".Trash", isDirectory: true)
        NSWorkspace.shared.open(trash)
    }
}

/// What a Put Back did: how many items are back and why the others are not.
struct CleanerPutBackSummaryView: View {
    let summary: PutBackSummary
    let roots: CleanerRoots

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: summary.restored == 0 ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(summary.restored == 0 ? FrogStyle.warning : FrogStyle.good).accessibilityHidden(true)
                Text(summary.title).font(.system(size: 14, weight: .medium))
            }
            ForEach(Array(summary.failures.enumerated()), id: \.offset) { _, failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text(roots.displayPath(URL(fileURLWithPath: failure.path))).font(.system(size: 12))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Text(failure.message).font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).frogTableSurface()
    }
}
