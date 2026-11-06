import AppKit
import SwiftUI
import FrogCore

/// Lists every item before anything moves and says what Finder, macOS and the password prompt will ask.
/// Moving to the Trash is never the default action, so Return alone cannot confirm it.
struct CleanerConfirmationSheet: View {
    let pending: PendingRemoval
    @ObservedObject var cleaner: CleanerModel
    let roots: CleanerRoots

    /// In the review's order: the app, then sure, likely and possible matches, shared and suggested items, each group
    /// in the order the review lists it.
    private var removals: [PlannedRemoval] {
        let order = CleanerGroupKind.allCases
        func rank(_ removal: PlannedRemoval) -> Int {
            CleanerGroupKind.of(removal.item, showPossible: true).flatMap { order.firstIndex(of: $0) } ?? order.count
        }
        return pending.plan.removals.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    private var removing: (done: Int, total: Int)? {
        if case .removing(let done, let total) = cleaner.phase { return (done, total) }
        return nil
    }

    var body: some View {
        let plan = pending.plan, prompt = pending.prompt
        VStack(alignment: .leading, spacing: FrogStyle.space16) {
            Text(prompt.title).font(FrogType.title).tracking(-0.4).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            // As tall as the list up to the limit, then it scrolls and fades out instead of cutting a row.
            FrogSheetScroll(maxHeight: 260) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(removals, id: \.item.id) { removal in itemRow(removal) }
                }.padding(FrogStyle.listInset)
            }
            .frogTableSurface()
            if let denied = prompt.finderDenied {
                VStack(alignment: .leading, spacing: 8) {
                    InlineIssue(message: denied)
                    Button(RemovalSummary.SettingsLink.automation.title) {
                        NSWorkspace.shared.open(RemovalSummary.SettingsLink.automation.url)
                    }
                }
            }
            // One paragraph rather than a stack of loose lines; the rows above mark what Finder moves.
            if !prompt.notes.isEmpty {
                Text(prompt.notes.joined(separator: " ")).font(FrogType.small).foregroundStyle(FrogStyle.muted)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            if !plan.refused.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionCaption(text: "Left out")
                    ForEach(plan.refused, id: \.item.id) { refusal in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(roots.shownPath(refusal.item.url)).font(FrogType.small)
                                .lineLimit(1).truncationMode(.middle)
                            Text(refusal.reason).font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                        }
                    }
                }
            }
            if let removing {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(removing.done), total: Double(max(removing.total, 1)))
                    Text("Moving \(min(removing.done + 1, removing.total)) of \(removing.total)…")
                        .font(FrogType.small.monospacedDigit()).foregroundStyle(FrogStyle.muted)
                }
            } else {
                // The confirming action removes, so it is destructive rather than the primary.
                FrogSheetButtons(padded: false) {
                    FrogCancelButton(prompt.cancel) { cleaner.cancelRemoval() }
                    Button(prompt.confirm, role: .destructive) { Task { await cleaner.confirmRemoval() } }
                        .buttonStyle(.frog(.destructive))
                }
            }
        }
        .padding(FrogStyle.sheetPadding).frame(width: 480)
        .buttonStyle(FrogButtonStyle())
        .foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent)
        .interactiveDismissDisabled(removing != nil)
        // The sheet stays open for the whole removal, so the force-quit question is asked from here.
        .confirmationDialog(cleaner.forceQuit?.title ?? "", isPresented: Binding(get: { cleaner.forceQuit != nil }, set: {
            if !$0, cleaner.forceQuit != nil { cleaner.answerForceQuit(false) }
        }), titleVisibility: .visible) {
            Button("Force Quit", role: .destructive) { cleaner.answerForceQuit(true) }
            Button("Cancel", role: .cancel) { cleaner.answerForceQuit(false) }
        } message: {
            Text(cleaner.forceQuit?.message ?? "")
        }
    }

    private func itemRow(_ removal: PlannedRemoval) -> some View {
        let item = removal.item
        let parts = roots.shownParts(item.url)
        return HStack(spacing: FrogStyle.space8) {
            icon(for: item).frame(width: 20, height: 20).accessibilityHidden(true)
            // The name leads and the folder follows in muted type, so a long path is cut in the folder, not the name.
            HStack(spacing: FrogStyle.space6) {
                Text(parts.name).font(FrogType.body).lineLimit(1).layoutPriority(1)
                Text(parts.folder).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1).truncationMode(.middle)
            }.help(roots.shownPath(item.url))
            if item.owner == .administrator { FrogBadge(text: "Needs password") }
            else if removal.route == .finder { FrogBadge(text: "Moved by Finder").help("Finder moves this item to the Trash, so it can ask for permission") }
            Spacer(minLength: 8)
            Text(size(of: item)).font(FrogType.small.monospacedDigit()).foregroundStyle(FrogStyle.muted)
        }.padding(.horizontal, FrogStyle.rowPadding).frame(minHeight: 30)
    }

    /// The app's own icon, or the system's generic app icon for a bundle without one; never a placeholder glyph.
    @ViewBuilder private func icon(for item: CleanerItem) -> some View {
        if item.kind == .application {
            ApplicationIcon(path: item.url.path, size: 20)
        } else {
            Image(systemName: item.kind.symbol).font(.system(size: 12)).foregroundStyle(FrogStyle.muted)
        }
    }

    private func size(of item: CleanerItem) -> String {
        guard let bytes = pending.request.sizes[item.id]?.bytes ?? item.size else { return "—" }
        return CleanerFormat.bytes(bytes)
    }
}
