import AppKit
import SwiftUI
import FrogCore

@MainActor
final class ShortcutReferencePanel {
    typealias Groups = [(group: ShortcutReferenceGroup, items: [ShortcutReferenceItem])]
    static let width: CGFloat = 420
    /// Where the screen is unknown, as in the screenshot harness.
    static let maxHeight: CGFloat = 640
    private var panel: NSPanel?
    func hide() { panel?.orderOut(nil) }
    func show(groups: Groups) {
        if panel?.isVisible == true { return }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 360), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hidesOnDeactivate = false; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.level = .floating; self.panel = panel
        }
        // The panel is as tall as its rows up to a limit, and scrolls after.
        let measured = NSHostingView(rootView: ShortcutReferenceContent(groups: groups).frame(width: Self.width).environment(\.locale, L10n.locale)).fittingSize.height
        // Shown while its key is held, so as tall as the display allows: every group is seen without scrolling.
        let height = min(WindowCheatSheetPanel.maximumHeight(on: NSScreen.main), ceil(measured))
        panel?.title = L10n.text("Frog shortcuts")
        panel?.contentView = NSHostingView(rootView: ShortcutReferenceView(groups: groups, height: height))
        panel?.setContentSize(NSSize(width: Self.width, height: height))
        panel?.center(); panel?.orderFrontRegardless()
    }
}

struct ShortcutReferenceView: View {
    let groups: ShortcutReferencePanel.Groups
    let height: CGFloat
    var body: some View {
        ScrollView { ShortcutReferenceContent(groups: groups) }
            .scrollIndicators(.automatic)
            // A row cut by the bottom edge fades out, so it reads as more below rather than as clipped.
            .bottomScrollFade(height: FrogStyle.sheetPadding)
            .frame(width: ShortcutReferencePanel.width, height: height).foregroundStyle(FrogStyle.ink)
            .frogPanel()
            .environment(\.locale, L10n.locale)
    }
}

/// The same layout as the window cheat sheet: a title, then each group under its caption, every row with its keys.
struct ShortcutReferenceContent: View {
    let groups: ShortcutReferencePanel.Groups
    var body: some View {
        VStack(alignment: .leading, spacing: FrogStyle.space16) {
            Text("Frog shortcuts").font(FrogType.title).accessibilityAddTraits(.isHeader)
            ForEach(groups, id: \.group) { section in
                VStack(alignment: .leading, spacing: FrogStyle.space8) {
                    Text(L10n.text(section.group.title)).font(FrogType.section).accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                    ForEach(section.items) { item in
                        let label = Self.label(item)
                        HStack(spacing: 10) {
                            // One line each: a plugin's action, its plugin's name muted under it.
                            VStack(alignment: .leading, spacing: FrogStyle.space2) {
                                Text(label.title).font(FrogType.row).lineLimit(1)
                                if let plugin = label.plugin {
                                    Text(plugin).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
                                }
                            }.help(L10n.text(item.title))
                            Spacer(minLength: 8)
                            KeyCaps(hotkey: item.hotkey)
                        }.padding(.horizontal, FrogStyle.cardPadding).padding(.vertical, FrogStyle.space6).frame(minHeight: FrogStyle.rowHeight)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(L10n.text(item.title))
                            .accessibilityValue(HotkeyManager.display(item.hotkey))
                    }
                    }.frogTableSurface()
                }
            }
            if groups.isEmpty {
                FrogEmptyState(symbol: "command", title: "No shortcuts yet",
                               message: "Give a Writing or Dictation rule a shortcut, or add one in Shortcuts.", tint: .blue)
                    .frogTableSurface()
            }
        }.padding(FrogStyle.sheetPadding).frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ShortcutReferenceContent {
    /// "Focus timer: Start or pause the focus timer" as the action, "Start or pause the focus timer", and its plugin.
    static func label(_ item: ShortcutReferenceItem) -> (title: String, plugin: String?) {
        let title = L10n.text(item.title)
        guard item.group == .plugins, let colon = title.range(of: ": ") else { return (title, nil) }
        let action = String(title[colon.upperBound...])
        return (action.prefix(1).uppercased() + action.dropFirst(), String(title[..<colon.lowerBound]))
    }
}

