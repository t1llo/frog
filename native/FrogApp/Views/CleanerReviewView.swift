import AppKit
import SwiftUI
import FrogCore

/// One app's bundle and leftovers, grouped by how sure Frog is, with what moves ticked.
struct CleanerReviewView: View {
    @ObservedObject var cleaner: CleanerModel
    let review: CleanerReview
    let setPossibleMatches: (Bool) -> Void
    @State private var running = false
    private var showPossible: Bool { cleaner.showPossibleMatches }

    private var roots: CleanerRoots { cleaner.dependencies.roots }

    var body: some View {
        let app = review.app
        // The app's name is the toolbar's title and its version and bundle ID the page's subtitle; its path is the
        // App row's, so it shows once.
        VStack(alignment: .leading, spacing: FrogStyle.sectionSpacing - 8) {
            notices
            ForEach(review.groups(showPossible: showPossible)) { group in groupView(group) }
            if review.nothingElseFound(showPossible: showPossible) != nil {
                Text(review.removedApp ? "No files found." : "No other files found.").font(FrogType.body).foregroundStyle(FrogStyle.muted)
            }
            possibleMatchesButton
        }
        .cleanerStepBack(cleaner)
        .task(id: app.path) { await checkRunning() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await checkRunning() }
        }
    }

    /// Possible matches are hidden unless asked for, and never ticked.
    @ViewBuilder private var possibleMatchesButton: some View {
        let possible = review.items.filter { $0.kind != .application && !$0.suggested && $0.confidence == .possible }.count
        if possible > 0 {
            Button(showPossible ? "Hide possible matches" : "Show \(possible) possible \(possible == 1 ? "match" : "matches")") {
                setPossibleMatches(!showPossible)
            }.buttonStyle(.frog())
        }
    }

    @ViewBuilder private var notices: some View {
        let app = review.app
        if running && !review.removedApp {
            notice("\(app.name) is running. Frog quits it first.", symbol: "play.circle")
        }
        if let uninstaller = app.vendorUninstaller, !review.removedApp {
            notice("\(app.name) has its own uninstaller.", symbol: "shippingbox") {
                Button("Open Uninstaller") { NSWorkspace.shared.open(URL(fileURLWithPath: uninstaller)) }
            }
        }
        if app.hasSystemExtensions, !review.removedApp {
            notice("Finder removes its system extension with it.", symbol: "puzzlepiece.extension")
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
        }.padding(.horizontal, FrogStyle.rowInset)
    }

    private func groupView(_ group: CleanerGroup) -> some View {
        // Headed like a settings section: the group's name, then its list in one card. Select all is the footer's,
        // once for the page, rather than repeated on every group.
        return VStack(alignment: .leading, spacing: 8) {
            FrogSectionHeader(group.kind.title, count: group.items.count)
            VStack(spacing: 2) {
                ForEach(group.items) { item in itemRow(item) }
            }.padding(6).frogTableSurface()
        }
    }

    private func itemRow(_ item: CleanerItem) -> some View {
        let path = roots.shownPath(item.url)
        let parts = roots.shownParts(item.url)
        return HStack(spacing: 10) {
            // The checkbox style draws its label, so the path is the accessibility label only.
            Toggle(isOn: Binding(get: { review.selected.contains(item.id) }, set: { _ in cleaner.toggle(item.id) })) { EmptyView() }
                .toggleStyle(.frogCheckbox).accessibilityLabel(path)
            // The name and reason tick the item too, not only the checkbox; the controls keep their own click.
            HStack(spacing: 10) {
                // The app itself shows its own icon; an outlined app symbol beside the checkbox read as a second box.
                if item.kind == .application {
                    ApplicationIcon(path: item.url.path, size: 24)
                } else {
                    Image(systemName: item.kind.symbol).font(.system(size: 13)).foregroundStyle(FrogStyle.muted)
                        .frame(width: 24).accessibilityHidden(true)
                }
                // The item's name leads; its folder and why it matched follow, so a long path is cut in the folder
                // rather than through the name.
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(parts.name).font(FrogType.body).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                        if item.owner == .administrator { FrogBadge(text: "Needs password") }
                        if review.needsFullDiskAccessToMove(item) { FrogBadge(text: "Needs Full Disk Access") }
                        if !item.sharedWith.isEmpty {
                            FrogBadge(text: "Also used by \(item.sharedWith.formatted(.list(type: .and)))")
                        }
                    }
                    HStack(spacing: 0) {
                        Text(parts.folder).lineLimit(1).truncationMode(.middle)
                        Text(" · " + item.reason).lineLimit(1).layoutPriority(1)
                    }.font(FrogType.small).foregroundStyle(FrogStyle.muted)
                }.help(path)
                Spacer(minLength: 8)
                size(of: item)
            }
            .contentShape(Rectangle()).onTapGesture { cleaner.toggle(item.id) }
            IconAction(title: "Show in Finder", symbol: "arrow.up.forward") {
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
            FrogSkeleton(width: 40, height: 14).accessibilityLabel("Measuring")
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
        let shown = review.groups(showPossible: cleaner.showPossibleMatches).flatMap(\.items)
        let allTicked = !shown.isEmpty && shown.allSatisfy { review.selected.contains($0.id) }
        HStack(spacing: 12) {
            Text(review.selectionSummary()).font(FrogType.body.monospacedDigit()).foregroundStyle(FrogStyle.muted)
            Button(allTicked ? "Deselect all" : "Select all") { cleaner.setAll(selected: !allTicked) }
                .buttonStyle(.frog())
            Spacer()
            // The page's one main action; the sheet it opens names what moves and holds the confirmation.
            Button("Move to Trash…", systemImage: "trash") { Task { await cleaner.prepareRemoval() } }
                .buttonStyle(.frog(.primary))
                // After a removal that left the app, the review stays open with the phase back at idle.
                .frogDisabled(count == 0 ? "Tick the files to move first" : ![.reviewing, .idle].contains(cleaner.phase) ? "Frog is still working" : nil)
        }
        // A card in the page's column, lined up with the lists above it, rather than a band across the window.
        .padding(.horizontal, FrogStyle.rowInset).padding(.vertical, FrogStyle.space10)
        .frogTableSurface()
        .frame(maxWidth: FrogStyle.pageWidth, alignment: .leading)
        .padding(.horizontal, FrogStyle.pagePadding).padding(.vertical, FrogStyle.space10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The canvas behind the card keeps the scrolled page from showing through around it.
        .background(FrogStyle.canvas)
    }
}

/// Shown while a scan looks for an app's files.
struct CleanerScanningView: View {
    @ObservedObject var cleaner: CleanerModel

    var body: some View {
        FrogLoadingNote(text: cleaner.scanningApp.map { "Looking for \($0.name)'s files…" } ?? "Looking for the app's files…")
            .frame(maxWidth: .infinity).padding(.vertical, 36).frogTableSurface()
            .cleanerStepBack(cleaner)
    }
}

extension View {
    /// The toolbar's Back (⌘[) and Escape return from a review or scan to the app list.
    func cleanerStepBack(_ cleaner: CleanerModel) -> some View {
        frogPageBack("cleaner-review", parent: "App cleaner", escapes: true) { cleaner.closeReview() }
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
                        FrogRow(path: roots.shownPath(URL(fileURLWithPath: failure.path)), caption: failure.message) {
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
