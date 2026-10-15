import SwiftUI
import FrogCore

/// Lists every item before anything moves and says what Finder, macOS and the password prompt will ask.
/// Moving to the Trash is never the default action, so Return alone cannot confirm it.
struct CleanerConfirmationSheet: View {
    let pending: PendingRemoval
    @ObservedObject var cleaner: CleanerModel
    let roots: CleanerRoots

    private var removing: (done: Int, total: Int)? {
        if case .removing(let done, let total) = cleaner.phase { return (done, total) }
        return nil
    }

    var body: some View {
        let plan = pending.plan, prompt = pending.prompt
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.title).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(plan.removals, id: \.item.id) { removal in
                        itemRow(removal.item)
                        if removal.item.id != plan.removals.last?.item.id { Divider().opacity(0.4) }
                    }
                }
            }
            .frame(maxHeight: 260).fixedSize(horizontal: false, vertical: true)
            .frogTableSurface()
            VStack(alignment: .leading, spacing: 4) {
                ForEach(prompt.notes, id: \.self) { note in
                    Text(note).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !plan.refused.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionCaption(text: "Left out")
                    ForEach(plan.refused, id: \.item.id) { refusal in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(roots.displayPath(refusal.item.url)).font(.system(size: 11))
                                .lineLimit(1).truncationMode(.middle)
                            Text(refusal.reason).font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                        }
                    }
                }
            }
            if let removing {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(removing.done), total: Double(max(removing.total, 1)))
                    Text("Moving \(min(removing.done + 1, removing.total)) of \(removing.total)…")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(FrogStyle.muted)
                }
            } else {
                HStack(spacing: 8) {
                    Spacer()
                    Button(prompt.cancel) { cleaner.cancelRemoval() }.keyboardShortcut(.cancelAction)
                    Button(prompt.confirm, role: .destructive) { Task { await cleaner.confirmRemoval() } }
                        .buttonStyle(FrogButtonStyle(primary: true))
                }
            }
        }
        .padding(20).frame(width: 480)
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
            Text(roots.displayPath(item.url)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            if item.owner == .administrator { FrogBadge(text: "Needs password") }
            Spacer(minLength: 8)
            Text(size(of: item)).font(.system(size: 11).monospacedDigit()).foregroundStyle(FrogStyle.muted)
        }.padding(.horizontal, 10).padding(.vertical, 5)
    }

    private func size(of item: CleanerItem) -> String {
        guard let bytes = pending.request.sizes[item.id]?.bytes ?? item.size else { return "—" }
        return CleanerFormat.bytes(bytes)
    }
}
