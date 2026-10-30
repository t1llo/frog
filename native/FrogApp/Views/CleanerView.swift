import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FrogCore

/// The App cleaner's page. Nothing is read until it opens, and nothing is scanned until an app is picked or dropped.
struct CleanerView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var cleaner: CleanerModel
    /// Saves `[app-cleaner] possible-matches`.
    let setPossibleMatches: (Bool) -> Void
    @State private var dropTargeted = false
    /// Read from the cleaner's store when the page opens; hidden until then.
    @State private var noticeDismissed = true
    @State private var visible = false

    static let fullDiskAccessNoticeFlag = "fullDiskAccessNoticeDismissed"

    var body: some View {
        FrogPage(width: FrogStyle.wideWidth) {
            FrogPageHeader(title: "App cleaner", subtitle: cleaner.review == nil && cleaner.outcome == nil ? "Pick an app, or drop one here." : nil) {
                IconAction(title: "Recently moved", symbol: "clock.arrow.circlepath") {
                    cleaner.dismissPutBack(); cleaner.loadRecords(); cleaner.showsRecent = true
                }
                .sheet(isPresented: $cleaner.showsRecent, onDismiss: { cleaner.dismissPutBack() }) {
                    CleanerRestoreView(cleaner: cleaner)
                }
            }
            // An open review says itself which of its items need Full Disk Access.
            if cleaner.fullDiskAccess == false, !noticeDismissed, cleaner.review == nil { fullDiskAccessNotice }
            if let issue = cleaner.issue { InlineIssue(message: issue) }
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if cleaner.outcome == nil, let review = cleaner.review {
                CleanerReviewFooter(cleaner: cleaner, review: review)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: FrogStyle.cardRadius).strokeBorder(FrogStyle.accent, lineWidth: 2)
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

    /// The outcome, the review, or the app list.
    @ViewBuilder private var content: some View {
        if let outcome = cleaner.outcome {
            CleanerOutcomeView(outcome: outcome, cleaner: cleaner)
        } else if let review = cleaner.review {
            CleanerReviewView(cleaner: cleaner, review: review, setPossibleMatches: setPossibleMatches)
        } else if cleaner.phase == .scanning {
            CleanerScanningView(cleaner: cleaner)
        } else {
            CleanerAppsView(cleaner: cleaner)
        }
    }

    private var fullDiskAccessNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(FrogStyle.muted).accessibilityHidden(true)
            Text("Full Disk Access lets Frog find and move all app data.")
                .font(FrogType.body).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open Settings") { NSWorkspace.shared.open(RemovalSummary.SettingsLink.fullDiskAccess.url) }
            Button("Not now") {
                do {
                    try cleaner.dependencies.store.setFlag(Self.fullDiskAccessNoticeFlag, true)
                    noticeDismissed = true
                } catch { model.report(error) }
            }.buttonStyle(.frog(.ghost))
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
