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
            CleanerBackButton(cleaner: cleaner)
            HStack(alignment: .center, spacing: 12) {
                ApplicationIcon(path: app.path, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(app.name).font(FrogType.section).lineLimit(1)
                        if let version = app.version {
                            Text(version).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
                        }
                        if review.removedApp { FrogBadge(text: "In the Trash") }
                    }
                    Group {
                        Text(app.bundleID)
                        Text(roots.displayPath(app.url)).lineLimit(1).truncationMode(.middle)
                    }.font(FrogType.small).foregroundStyle(FrogStyle.muted).textSelection(.enabled)
                }
                Spacer(minLength: 12)
            }
            notices
            ForEach(review.groups(showPossible: showPossible)) { group in groupView(group) }
            if let nothing = review.nothingElseFound(showPossible: showPossible) {
                Text(nothing).font(FrogType.body).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .task(id: app.path) { await checkRunning() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await checkRunning() }
        }
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
        if let fullDiskAccess = review.fullDiskAccessNotice {
            notice(fullDiskAccess, symbol: "lock.shield") {
                Button("Open Settings") { NSWorkspace.shared.open(RemovalSummary.SettingsLink.fullDiskAccess.url) }
            }
        }
    }

    private func notice(_ text: String, symbol: String) -> some View {
        notice(text, symbol: symbol) { EmptyView() }
    }

    private func notice<Action: View>(_ text: String, symbol: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(FrogStyle.muted).frame(width: 18).accessibilityHidden(true)
            Text(text).font(FrogType.body).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            action()
        }.padding(.horizontal, 4)
    }

    private func groupView(_ group: CleanerGroup) -> some View {
        let allTicked = group.items.allSatisfy { review.selected.contains($0.id) }
        // Headed like a settings section: the group's name, then its list in one card.
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.text("\(group.kind.title) · \(group.items.count)")).font(FrogType.section)
                    .foregroundStyle(FrogStyle.ink).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button(allTicked ? "Untick all" : "Tick all") { cleaner.setGroup(group.kind, selected: !allTicked) }
                    .buttonStyle(.frog(.ghost, compact: true))
            }.frame(minHeight: 20)
            VStack(spacing: 2) {
                ForEach(group.items) { item in itemRow(item) }
            }.padding(6).frogTableSurface()
        }
    }

    private func itemRow(_ item: CleanerItem) -> some View {
        let path = roots.displayPath(item.url)
        return HStack(spacing: 10) {
            Toggle(path, isOn: Binding(get: { review.selected.contains(item.id) }, set: { _ in cleaner.toggle(item.id) }))
                .toggleStyle(.frogCheckbox).labelsHidden()
            // The name and reason tick the item too, not only the checkbox; the controls keep their own click.
            HStack(spacing: 10) {
                Image(systemName: item.kind.symbol).font(.system(size: 12)).foregroundStyle(FrogStyle.muted)
                    .frame(width: 18).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(path).font(FrogType.body).lineLimit(1).truncationMode(.middle).help(path)
                    HStack(spacing: 6) {
                        Text(item.reason).font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
                        if item.owner == .administrator { FrogBadge(text: "Needs password") }
                        if review.needsFullDiskAccessToMove(item) { FrogBadge(text: "Needs Full Disk Access") }
                        if !item.sharedWith.isEmpty {
                            FrogBadge(text: "Also used by \(item.sharedWith.formatted(.list(type: .and)))")
                        }
                    }
                }
                Spacer(minLength: 8)
                size(of: item)
            }
            .contentShape(Rectangle()).onTapGesture { cleaner.toggle(item.id) }
            IconAction(title: "Reveal in Finder", symbol: "magnifyingglass") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6).frogHoverRow()
    }

    @ViewBuilder private func size(of item: CleanerItem) -> some View {
        if let bytes = review.sizes[item.id]?.bytes ?? item.size {
            let incomplete = review.sizes[item.id]?.complete == false
            Text((incomplete ? "≥ " : "") + CleanerFormat.bytes(bytes))
                .font(FrogType.small.monospacedDigit()).foregroundStyle(FrogStyle.muted)
        } else if review.sizes.isEmpty, review.measures(item) {
            // Sizes arrive together once the measuring finishes.
            ProgressView().controlSize(.mini).accessibilityLabel("Measuring")
        } else {
            Text("—").font(FrogType.small).foregroundStyle(FrogStyle.muted).accessibilityLabel("Size unknown")
                .help(review.measures(item) ? "Frog could not measure this item." : "Frog needs Full Disk Access to measure this item.")
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
            Text(review.selectionSummary()).font(FrogType.body.monospacedDigit()).foregroundStyle(FrogStyle.muted)
            Spacer()
            Button("Move to Trash…") { Task { await cleaner.prepareRemoval() } }
                .buttonStyle(.frog(.destructive))
                // After a removal that left the app, the review stays open with the phase back at idle.
                .disabled(count == 0 || ![.reviewing, .idle].contains(cleaner.phase))
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        // The bar sits on the inset fill rather than behind a line; the canvas below keeps the scrolled page from showing through.
        .background(FrogStyle.inset).background(FrogStyle.canvas)
    }
}

/// Shown while a scan looks for an app's files.
struct CleanerScanningView: View {
    @ObservedObject var cleaner: CleanerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CleanerBackButton(cleaner: cleaner)
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(cleaner.scanningApp.map { "Looking for \($0.name)'s files…" } ?? "Looking for the app's files…")
                    .font(FrogType.body).foregroundStyle(FrogStyle.muted)
            }
        }
    }
}

/// Returns to the app list, worded like the other pages' way back.
struct CleanerBackButton: View {
    @ObservedObject var cleaner: CleanerModel

    var body: some View {
        Button("Apps", systemImage: "chevron.left") { cleaner.closeReview() }
            .buttonStyle(.frog(.ghost))
            .help("Back to apps")
    }
}

/// What a removal did: what moved, what did not and why, and how to free the space.
struct CleanerOutcomeView: View {
    let outcome: RemovalOutcome
    @ObservedObject var cleaner: CleanerModel

    var body: some View {
        // After Put Back, its summary takes the outcome's place until Done.
        if let putBack = cleaner.putBackSummary {
            VStack(alignment: .leading, spacing: 12) {
                CleanerPutBackSummaryView(summary: putBack, roots: cleaner.dependencies.roots)
                HStack {
                    Spacer()
                    Button("Done") { cleaner.dismissPutBack(); cleaner.dismissOutcome() }
                        .buttonStyle(.frog(.primary)).keyboardShortcut(.defaultAction)
                }
            }
        } else {
            outcomeView
        }
    }

    private var outcomeView: some View {
        let summary = RemovalSummary(outcome)
        let roots = cleaner.dependencies.roots
        return FrogCard { VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: outcome.moved.isEmpty ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(outcome.moved.isEmpty ? FrogStyle.warning : FrogStyle.good).accessibilityHidden(true)
                Text(summary.title).font(FrogType.section)
            }
            if let failureTitle = summary.failureTitle {
                VStack(alignment: .leading, spacing: 8) {
                    SectionCaption(text: failureTitle)
                    ForEach(Array(outcome.failures.enumerated()), id: \.offset) { _, failure in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(roots.displayPath(URL(fileURLWithPath: failure.path))).font(FrogType.body)
                                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                Text(failure.message).font(FrogType.small).foregroundStyle(FrogStyle.muted)
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
                        Text(note).font(FrogType.small).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Spacer()
                if let record = outcome.record {
                    Button("Put Back") { Task { await cleaner.putBack(record.id) } }.buttonStyle(.frog())
                        .disabled(cleaner.puttingBack != nil)
                }
                Button("Done") { cleaner.dismissOutcome() }.buttonStyle(.frog(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        } }
    }
}
