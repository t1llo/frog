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
            .bottomScrollFade(height: FrogSheetScrollMetrics.fade)
            .frame(width: ShortcutReferencePanel.width, height: height).foregroundStyle(FrogStyle.ink)
            .frogPanel()
            .environment(\.locale, L10n.locale)
    }
}

/// The same layout as the window cheat sheet: a title, then one card in which each group starts with its caption,
/// every row with its keys.
struct ShortcutReferenceContent: View {
    let groups: ShortcutReferencePanel.Groups
    var body: some View {
        ShortcutPanelLayout(title: "Frog shortcuts") {
            if groups.isEmpty {
                FrogEmptyState(symbol: "command", title: "No shortcuts yet",
                               message: "Give a Writing or Dictation rule a shortcut, or add one in Shortcuts.", tint: .blue)
                    .frogTableSurface()
            } else {
                ShortcutPanelCard {
                    ForEach(Array(groups.enumerated()), id: \.element.group) { index, section in
                        ShortcutPanelCaption(title: section.group.title, first: index == 0)
                        ForEach(section.items) { item in
                            // A plugin's action names its plugin, muted, so two plugins' "Refresh" read apart.
                            let label = Self.label(item)
                            ShortcutPanelRow(title: label.title, detail: label.plugin, hotkey: item.hotkey) {
                                if let action = item.windowAction { WindowLayoutGlyph(action: action) }
                                else { ShortcutPanelSymbol(name: item.symbol ?? "command") }
                            }
                                .help(L10n.text(item.title))
                                .accessibilityLabel(L10n.text(item.title))
                        }
                    }
                }
            }
        }
    }
}

/// A shortcut panel (the shortcut reference, the window cheat sheet): its title, then its content, padded as a sheet.
struct ShortcutPanelLayout<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: FrogStyle.space12) {
            Text(L10n.text(title)).font(FrogType.title).tracking(-0.4).accessibilityAddTraits(.isHeader)
            content
        }
        .padding(FrogStyle.sheetPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(FrogStyle.ink)
    }
}

/// The one card of a shortcut panel. Its groups are captions inside it rather than cards of their own, so a group of
/// one row (Sizes, Displays) weighs no more than its row.
struct ShortcutPanelCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.bottom, FrogStyle.space6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frogTableSurface()
    }
}

/// A group's caption inside a shortcut panel's card, on the rows' text edge.
struct ShortcutPanelCaption: View {
    let title: String
    var first = false
    var body: some View {
        SectionCaption(text: title)
            .padding(.horizontal, FrogStyle.cardPadding)
            .padding(.top, first ? FrogStyle.space10 : FrogStyle.space16).padding(.bottom, FrogStyle.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row of a shortcut panel: an optional glyph, the title, and the keys ending on the card's content edge. Every
/// cap is one width (`KeyCap`), so the keys of every row end and line up on the same edge.
struct ShortcutPanelRow<Leading: View>: View {
    let title: String
    /// Muted after the title, such as the plugin an action belongs to.
    var detail: String? = nil
    let hotkey: Hotkey
    @ViewBuilder var leading: Leading
    var body: some View {
        HStack(spacing: FrogStyle.space10) {
            if Leading.self != EmptyView.self { leading.frame(width: 22) }
            Text(title).font(FrogType.row).lineLimit(1)
            // The detail is short (a plugin's name) and always whole; a long title is the one to shorten.
            if let detail { Text(detail).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1).fixedSize() }
            Spacer(minLength: FrogStyle.space8)
            KeyCaps(hotkey: hotkey)
        }
        .padding(.horizontal, FrogStyle.cardPadding)
        .frame(height: FrogStyle.menuRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(HotkeyManager.display(hotkey))
    }
}

/// A row's symbol in a shortcut panel, in the slot a window layout's picture takes, muted like the cheat sheet's.
struct ShortcutPanelSymbol: View {
    let name: String
    var body: some View {
        Image(systemName: name).font(.system(size: 13)).foregroundStyle(FrogStyle.muted).accessibilityHidden(true)
    }
}

extension ShortcutReferenceContent {
    /// "Focus timer: Start or pause the focus timer" as the action, "Start or pause the focus timer", and its plugin,
    /// unless the action already names it.
    static func label(_ item: ShortcutReferenceItem) -> (title: String, plugin: String?) {
        let title = L10n.text(item.title)
        guard item.group == .plugins, let colon = title.range(of: ": ") else { return (title, nil) }
        let action = String(title[colon.upperBound...])
        let plugin = String(title[..<colon.lowerBound])
        return (action.prefix(1).uppercased() + action.dropFirst(),
                action.localizedCaseInsensitiveContains(plugin) ? nil : plugin)
    }
}

