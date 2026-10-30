import AppKit
import SwiftUI
import FrogCore

/// Lists every item before anything moves and says what Finder, macOS and the password prompt will ask.
/// Moving to the Trash is never the default action, so Return alone cannot confirm it.
struct CleanerConfirmationSheet: View {
    let pending: PendingRemoval
    @ObservedObject var cleaner: CleanerModel
    let roots: CleanerRoots

    /// The app first, then the rest by path.
    private var removals: [PlannedRemoval] {
        let removals = pending.plan.removals
        return removals.filter { $0.item.kind == .application } + removals.filter { $0.item.kind != .application }
    }

    private var removing: (done: Int, total: Int)? {
        if case .removing(let done, let total) = cleaner.phase { return (done, total) }
        return nil
    }

    var body: some View {
        let plan = pending.plan, prompt = pending.prompt
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.title).font(FrogType.section).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(removals, id: \.item.id) { removal in itemRow(removal.item) }
                }.padding(6)
            }
            .frame(maxHeight: 260).fixedSize(horizontal: false, vertical: true)
            .frogTableSurface()
            if let denied = prompt.finderDenied {
                VStack(alignment: .leading, spacing: 8) {
                    InlineIssue(message: denied)
                    Button(RemovalSummary.SettingsLink.automation.title) {
                        NSWorkspace.shared.open(RemovalSummary.SettingsLink.automation.url)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(prompt.notes, id: \.self) { note in
                    Text(note).font(FrogType.small).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !plan.refused.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionCaption(text: "Left out")
                    ForEach(plan.refused, id: \.item.id) { refusal in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(roots.displayPath(refusal.item.url)).font(FrogType.small)
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
                HStack(spacing: 8) {
                    Spacer()
                    Button(prompt.cancel) { cleaner.cancelRemoval() }.keyboardShortcut(.cancelAction)
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

    private func itemRow(_ item: CleanerItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind.symbol).font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                .frame(width: 16).accessibilityHidden(true)
            Text(roots.displayPath(item.url)).font(FrogType.body).lineLimit(1).truncationMode(.middle)
            if item.owner == .administrator { FrogBadge(text: "Needs password") }
            Spacer(minLength: 8)
            Text(size(of: item)).font(FrogType.small.monospacedDigit()).foregroundStyle(FrogStyle.muted)
        }.padding(.horizontal, 8).padding(.vertical, 5)
    }

    private func size(of item: CleanerItem) -> String {
        guard let bytes = pending.request.sizes[item.id]?.bytes ?? item.size else { return "—" }
        return CleanerFormat.bytes(bytes)
    }
}
