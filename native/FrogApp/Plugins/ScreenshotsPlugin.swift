import AppKit
import SwiftUI
import FrogCore

/// Copies every screenshot taken with macOS's own tool (⇧⌘3, ⇧⌘4, ⇧⌘5) to the clipboard, so it pastes
/// straight into an agent or a chat. The watcher exists only while the plugin is on.
final class ScreenshotsPlugin: LegacyPlugin, FrogPlugin, ObservableObject {
    static let info = PluginInfo(id: "screenshots", name: "Screenshots", symbol: "camera.viewfinder", tint: .teal, category: .system,
                                 summary: "Copy every screenshot to the clipboard")
    /// For tests: a watcher on fixture folders, which starts. Without one, only a model that registers shortcuts
    /// starts watching, so test models never touch the user's clipboard.
    nonisolated(unsafe) static var makeWatcher: (@MainActor () -> ScreenshotClipboard)?

    let watcher: ScreenshotClipboard
    private let watches: Bool

    override init(context: PluginContext) {
        watcher = Self.makeWatcher?() ?? ScreenshotClipboard()
        watches = Self.makeWatcher != nil || context.legacy.registerShortcuts
        super.init(context: context)
    }

    func start() async {
        if watches { watcher.start() }
    }

    func stop() async {
        watcher.stop()
    }

    func page() -> AnyView? { legacyPage(ScreenshotsPage(plugin: self)) }

    struct Status: Encodable {
        let on: Bool
        let saveFolder: String?
        let lastCopied: String?
        let lastCopiedAt: Date?
    }

    var actions: [PluginAction] {
        [PluginAction(id: "screenshots.copy-latest", title: "Copy the latest screenshot", symbol: "camera.viewfinder",
                      keywords: "screenshot screen capture clipboard paste image") { [weak self] _ in
            guard let watcher = self?.watcher else { throw ActionError.failed("Screenshots is off.") }
            guard let copied = watcher.copyLatest() else { throw ActionError.failed("No screenshot in \(watcher.saveFolder.path).") }
            return .done("Copied \(copied.name).")
         },
         PluginAction(id: "screenshots.status", title: "Screenshots status", symbol: "camera.viewfinder", surfaces: [.agent]) { [weak self] _ in
            let watcher = self?.watcher
            let status = Status(on: watcher?.isRunning == true, saveFolder: watcher?.saveFolder.path,
                                lastCopied: watcher?.lastCopied?.name, lastCopiedAt: watcher?.lastCopied?.time)
            let text = watcher?.lastCopied.map { "Last copied \($0.name)." } ?? "No screenshot copied yet."
            return ActionResult(status, text: text)
         }]
    }
}

struct ScreenshotsPage: View {
    @ObservedObject var plugin: ScreenshotsPlugin

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Screenshots", subtitle: "Take a screenshot as usual, then paste it anywhere.")
            ScreenshotsStatus(watcher: plugin.watcher)
        }
    }
}

private struct ScreenshotsStatus: View {
    @ObservedObject var watcher: ScreenshotClipboard

    var body: some View {
        // The page's state: what was copied last, as Stay awake shows its session.
        FrogSection {
            HStack(spacing: FrogStyle.space12) {
                PluginIconTile(symbol: ScreenshotsPlugin.info.symbol, tint: ScreenshotsPlugin.info.tint.color, size: .header)
                VStack(alignment: .leading, spacing: FrogStyle.space2) {
                    Text(L10n.text(watcher.lastCopied == nil ? "Ready to copy" : "Copied to the clipboard"))
                        .font(FrogType.title).foregroundStyle(FrogStyle.ink).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(caption(at: context.date)).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: FrogStyle.space8)
            }
            .padding(.vertical, FrogStyle.space12)
            .accessibilityElement(children: .combine)
        }
        FrogSection {
            FrogRow(path: watcher.saveFolder.path, caption: "Where macOS saves screenshots") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([watcher.saveFolder]) }.buttonStyle(.frog())
            }
            FrogRow("Latest screenshot", caption: "Copy it again") {
                Button("Copy") { watcher.copyLatest() }.buttonStyle(.frog())
            }
        }
    }

    private func caption(at now: Date) -> String {
        guard let copied = watcher.lastCopied else { return L10n.text("Press ⇧⌘4 or ⇧⌘5 to take one.") }
        let when = copied.time.formatted(.relative(presentation: .named))
        return "\(copied.name) · \(when)"
    }
}
