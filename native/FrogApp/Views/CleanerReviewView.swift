import AppKit
import SwiftUI
import FrogCore

/// One app's bundle and leftovers, grouped by how sure Frog is, with what moves ticked.
struct CleanerReviewView: View {
    @ObservedObject var cleaner: CleanerModel
    let review: CleanerReview
    let showPossible: Bool
    @State private var running = false

    private var roots: CleanerRoots { cleaner.dependencies.roots }

    var body: some View {
        let app = review.app
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                IconAction(title: "Back to apps", symbol: "chevron.left") { cleaner.closeReview() }
                ApplicationIcon(path: app.path, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(app.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if let version = app.version {
                            Text(version).font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineLimit(1)
                        }
                    }
                    Group {
                        Text(app.bundleID)
                        Text(roots.displayPath(app.url)).lineLimit(1).truncationMode(.middle)
                    }.font(.system(size: 11)).foregroundStyle(FrogStyle.muted).textSelection(.enabled)
                }
                Spacer(minLength: 12)
                Text(movesText).font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(review.selectedCount == 0 ? FrogStyle.muted : FrogStyle.ink)
            }
            notices
            ForEach(review.groups(showPossible: showPossible)) { group in groupView(group) }
        }
        .task(id: app.path) { await checkRunning() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await checkRunning() }
        }
    }

    private var movesText: String {
        guard review.selectedCount > 0 else { return "Nothing ticked" }
        let bytes = CleanerFormat.bytes(review.selectedBytes)
        return review.selectedSizeIncomplete ? "Moves at least \(bytes) to the Trash" : "Moves \(bytes) to the Trash"
    }

    @ViewBuilder private var notices: some View {
        let app = review.app
        if running && !review.removedApp {
            notice("\(app.name) is running. Frog quits it before moving anything.", symbol: "play.circle")
        }
        if let uninstaller = app.vendorUninstaller, !review.removedApp {
            notice("\(app.name) comes with its own uninstaller, which can remove parts Frog cannot see.", symbol: "shippingbox") {
                Button("Open Uninstaller") { NSWorkspace.shared.open(URL(fileURLWithPath: uninstaller)) }
            }
        }
        if app.hasSystemExtensions, !review.removedApp {
            notice("\(app.name) has a system extension. Finder removes it with the app.", symbol: "puzzlepiece.extension")
        }
        if review.needsFullDiskAccess {
            notice("Some items need Full Disk Access to be measured or moved.", symbol: "lock.shield")
        }
    }

    private func notice(_ text: String, symbol: String) -> some View {
        notice(text, symbol: symbol) { EmptyView() }
    }

    private func notice<Action: View>(_ text: String, symbol: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(FrogStyle.muted).frame(width: 18).accessibilityHidden(true)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            action()
        }.padding(.horizontal, 4)
    }

    private func groupView(_ group: CleanerGroup) -> some View {
        let allTicked = group.items.allSatisfy { review.selected.contains($0.id) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionCaption(text: "\(group.kind.title) · \(group.items.count)")
                Spacer()
                Button(allTicked ? "Untick all" : "Tick all") { cleaner.setGroup(group.kind, selected: !allTicked) }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(FrogStyle.accent)
            }.padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(group.items) { item in
                    itemRow(item)
                    if item.id != group.items.last?.id { Divider().opacity(0.4).padding(.leading, 64) }
                }
            }.frogTableSurface()
        }
    }

    private func itemRow(_ item: CleanerItem) -> some View {
        let path = roots.displayPath(item.url)
        return HStack(spacing: 10) {
            Toggle(path, isOn: Binding(get: { review.selected.contains(item.id) }, set: { _ in cleaner.toggle(item.id) }))
                .toggleStyle(.checkbox).labelsHidden()
            Image(systemName: item.kind.symbol).font(.system(size: 12)).foregroundStyle(FrogStyle.muted)
                .frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(path).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).help(path)
                HStack(spacing: 6) {
                    Text(item.reason).font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(1)
                    if item.owner == .administrator { FrogBadge(text: "Needs password") }
                    if !review.measures(item) { FrogBadge(text: "Needs Full Disk Access") }
                    if !item.sharedWith.isEmpty {
                        FrogBadge(text: "Also used by \(item.sharedWith.formatted(.list(type: .and)))")
                    }
                }
            }
            Spacer(minLength: 8)
            size(of: item)
            IconAction(title: "Reveal in Finder", symbol: "magnifyingglass") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }.padding(.horizontal, 10).padding(.vertical, 6)
    }

    @ViewBuilder private func size(of item: CleanerItem) -> some View {
        if let bytes = review.sizes[item.id]?.bytes ?? item.size {
            let incomplete = review.sizes[item.id]?.complete == false
            Text((incomplete ? "≥ " : "") + CleanerFormat.bytes(bytes))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(FrogStyle.muted)
        } else if review.sizes.isEmpty, review.measures(item) {
            // Sizes arrive together once the measuring finishes.
            ProgressView().controlSize(.mini).accessibilityLabel("Measuring")
        } else {
            Text("—").font(.system(size: 11)).foregroundStyle(FrogStyle.muted).accessibilityLabel("Size unknown")
        }
    }

    private func checkRunning() async {
        let app = review.app
        let found = await cleaner.dependencies.system.running(bundleIDs: [app.bundleID], inside: nil)
        running = found.contains { $0.bundleID == app.bundleID }
    }
}

/// Stays at the bottom of the page while a review is open.
struct CleanerReviewFooter: View {
    @ObservedObject var cleaner: CleanerModel
    let review: CleanerReview

    var body: some View {
        let count = review.selectedCount
        HStack(spacing: 12) {
            Text("\(count) \(count == 1 ? "item" : "items") · \(CleanerFormat.bytes(review.selectedBytes))")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(FrogStyle.muted)
            Spacer()
            Button("Move to Trash…") { Task { await cleaner.prepareRemoval() } }
                .buttonStyle(FrogButtonStyle(primary: true))
                // After a removal that left the app, the review stays open with the phase back at idle.
                .disabled(count == 0 || ![.reviewing, .idle].contains(cleaner.phase))
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(FrogStyle.canvas)
        .overlay(alignment: .top) { Rectangle().fill(FrogStyle.border.opacity(0.6)).frame(height: 1) }
    }
}

/// Shown while a scan looks for an app's files.
struct CleanerScanningView: View {
    @ObservedObject var cleaner: CleanerModel

    var body: some View {
        HStack(spacing: 10) {
            IconAction(title: "Back to apps", symbol: "chevron.left") { cleaner.closeReview() }
            ProgressView().controlSize(.small)
            Text(cleaner.scanningApp.map { "Looking for \($0.name)'s files…" } ?? "Looking for the app's files…")
                .font(.system(size: 12)).foregroundStyle(FrogStyle.muted)
        }
    }
}

/// What a removal did: what moved, what did not and why, and how to free the space.
struct CleanerOutcomeView: View {
    let outcome: RemovalOutcome
    @ObservedObject var cleaner: CleanerModel

    var body: some View {
        let summary = RemovalSummary(outcome)
        let roots = cleaner.dependencies.roots
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: outcome.moved.isEmpty ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(outcome.moved.isEmpty ? FrogStyle.warning : FrogStyle.good).accessibilityHidden(true)
                Text(summary.title).font(.system(size: 14, weight: .medium))
            }
            if let failureTitle = summary.failureTitle {
                VStack(alignment: .leading, spacing: 8) {
                    SectionCaption(text: failureTitle)
                    ForEach(Array(outcome.failures.enumerated()), id: \.offset) { _, failure in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(roots.displayPath(URL(fileURLWithPath: failure.path))).font(.system(size: 12))
                                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                Text(failure.message).font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if let link = RemovalSummary.settingsLink(for: failure.message) {
                                Button(link.title) { NSWorkspace.shared.open(link.url) }
                            }
                        }
                    }
                }
            }
            if !summary.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(summary.notes, id: \.self) { note in
                        Text(note).font(.system(size: 11)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { cleaner.dismissOutcome() }.buttonStyle(FrogButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).frogTableSurface()
    }
}
