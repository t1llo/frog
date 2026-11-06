import AppKit
import SwiftUI
import FrogCore

@MainActor
final class ShortcutReferencePanel {
    typealias Groups = [(group: ShortcutReferenceGroup, items: [ShortcutReferenceItem])]
    static let width: CGFloat = 380
    static let maxHeight: CGFloat = 520
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
        let height = min(Self.maxHeight, ceil(measured))
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
            Text("Frog shortcuts").font(FrogType.toolbarTitle).accessibilityAddTraits(.isHeader)
            ForEach(groups, id: \.group) { section in
                VStack(alignment: .leading, spacing: FrogStyle.space8) {
                    Text(L10n.text(section.group.title)).font(FrogType.section).accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                    ForEach(section.items) { item in
                        HStack(spacing: 10) {
                            Text(L10n.text(item.title)).font(FrogType.row).lineLimit(1)
                            Spacer(minLength: 8)
                            ShortcutKeyCaps(hotkey: item.hotkey)
                        }.padding(.horizontal, FrogStyle.cardPadding).frame(minHeight: FrogStyle.rowHeight)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(L10n.text(item.title))
                            .accessibilityValue(HotkeyManager.display(item.hotkey))
                    }
                    }.frogTableSurface()
                }
            }
            if groups.isEmpty {
                Text("No shortcuts yet. Give a Writing or Dictation action a shortcut, or add one in Shortcuts.")
                    .font(FrogType.row).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(FrogStyle.sheetPadding).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A shortcut in a reference panel: each key as a cap.
struct ShortcutKeyCaps: View {
    let hotkey: Hotkey
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(HotkeyManager.keys(hotkey).enumerated()), id: \.offset) { KeyCap($0.element) }
        }
    }
}
