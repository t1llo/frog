import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FrogCore

enum CleanerTab: String, CaseIterable, Identifiable {
    case apps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apps: "Apps"
        }
    }
    static func available(_ preferences: Preferences) -> [CleanerTab] {
        var tabs: [CleanerTab] = []
        tabs.append(.apps)
        return tabs
    }
}

/// The App cleaner's page. Nothing is read until it opens, and nothing is scanned until an app is picked or dropped.
struct CleanerView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var cleaner: CleanerModel
    @State private var showsSettings = false
    @State private var dropTargeted = false
    /// Read from the cleaner's store when the page opens; hidden until then.
    @State private var noticeDismissed = true
    @State private var visible = false

    static let fullDiskAccessNoticeFlag = "fullDiskAccessNoticeDismissed"

    private var preferences: Preferences { model.configuration.preferences }
    private var showPossible: Bool { preferences.featureEnabled(.cleaner) && preferences.cleanerSettings.possibleMatches }

    var body: some View {
        let tabs = CleanerTab.available(preferences)
        PageScroll {
            PageHeader(title: "App cleaner") {
                IconAction(title: "Recently moved", symbol: "clock.arrow.circlepath") {
                    cleaner.dismissPutBack(); cleaner.loadRecords(); cleaner.showsRecent = true
                }
                .sheet(isPresented: $cleaner.showsRecent, onDismiss: { cleaner.dismissPutBack() }) {
                    CleanerRestoreView(cleaner: cleaner)
                }
                IconAction(title: "Cleaner settings", symbol: "slider.horizontal.3") { showsSettings.toggle() }
                    .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                        CleanerSettingsView().environmentObject(model)
                    }
            }
            if tabs.count > 1 {
                HStack(spacing: 4) {
                    ForEach(tabs) { item in FilterTag(title: item.title, selected: item == cleaner.tab) { cleaner.tab = item } }
                }
            }
            // An open review says itself which of its items need Full Disk Access.
            if cleaner.fullDiskAccess == false, !noticeDismissed, cleaner.review == nil { fullDiskAccessNotice }
            if let issue = cleaner.issue { InlineIssue(message: issue) }
            switch cleaner.tab {
            case .apps: appsContent        // outcome, review or app list
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if cleaner.tab == .apps, cleaner.outcome == nil, let review = cleaner.review {
                CleanerReviewFooter(cleaner: cleaner, review: review)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(FrogStyle.accent, lineWidth: 2)
                    .padding(6).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in drop(providers) }
        .sheet(item: Binding(get: { cleaner.pending }, set: { if $0 == nil { cleaner.cancelRemoval() } })) { pending in
            CleanerConfirmationSheet(pending: pending, cleaner: cleaner, roots: cleaner.dependencies.roots)
        }
        .background(FeatureVisibility { shown in
            visible = shown
            if shown { measureAppSizes() }
        })
        .task {
            noticeDismissed = cleaner.dependencies.store.flag(Self.fullDiskAccessNoticeFlag)
            await cleaner.refreshFullDiskAccess()
        }
        .task {
            await cleaner.loadApps()
            if visible { measureAppSizes() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await cleaner.refreshFullDiskAccess() }
        }
    }

    @ViewBuilder private var appsContent: some View {
        if let outcome = cleaner.outcome {
            CleanerOutcomeView(outcome: outcome, cleaner: cleaner)
        } else if let review = cleaner.review {
            CleanerReviewView(cleaner: cleaner, review: review, showPossible: showPossible)
        } else if cleaner.phase == .scanning {
            CleanerScanningView(cleaner: cleaner)
        } else {
            CleanerAppsView(cleaner: cleaner)
        }
    }

    private var fullDiskAccessNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(FrogStyle.muted).accessibilityHidden(true)
            Text("Without Full Disk Access, Frog cannot measure or move some app data.")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open Settings") { NSWorkspace.shared.open(RemovalSummary.SettingsLink.fullDiskAccess.url) }
            Button("Not now") {
                do {
                    try cleaner.dependencies.store.setFlag(Self.fullDiskAccessNoticeFlag, true)
                    noticeDismissed = true
                } catch { model.report(error) }
            }
        }.padding(.horizontal, 4)
    }

    private func measureAppSizes() {
        guard visible, !cleaner.apps.isEmpty else { return }
        Task { await cleaner.measureAppSizes() }
    }

    /// The first file URL goes to the cleaner, which says when it is not an app.
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSURL.self) }) else { return false }
        Task {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: NSURL.self) { value, _ in continuation.resume(returning: value as? URL) }
            }
            guard let url, url.isFileURL else { return }
            await cleaner.open(url)
        }
        return true
    }
}

/// The popover behind "Cleaner settings". Each row saves through `updateCleanerSettings`.
struct CleanerSettingsView: View {
    @EnvironmentObject private var model: AppModel
    private var settings: CleanerPreferences { model.configuration.preferences.cleanerSettings }

    var body: some View {
        SettingsSection(title: "App cleaner") {
            possibleMatchesRow
        }
        .padding(12).frame(width: 320)
        .foregroundStyle(FrogStyle.ink).background(FrogStyle.panelSurface)
    }

    private var possibleMatchesRow: some View {
        CompactRow(title: "Show possible matches",
                   detail: "Files whose names only resemble the app. Never ticked.") {
            Toggle("Show possible matches", isOn: Binding(get: { settings.possibleMatches }, set: { value in
                save { $0.possibleMatches = value }
            })).labelsHidden().toggleStyle(.switch)
        }
    }

    private func save(_ change: (inout CleanerPreferences) -> Void) {
        do { try model.updateCleanerSettings(change) } catch { model.report(error) }
    }
}
