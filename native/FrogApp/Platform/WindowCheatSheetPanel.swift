import AppKit
import SwiftUI
import FrogCore

/// The window shortcuts, shown while the cheat sheet shortcut is held. Never key and never
/// activates Frog, so the front app keeps its focus. Created once and reused.
@MainActor
final class WindowCheatSheetPanel {
    static let width: CGFloat = 460
    static let maximumHeight: CGFloat = 520

    private var panel: FrogFloatingPanel?
    private var host: NSHostingView<WindowCheatSheetView>?

    func show(sections: [WindowCheatSheet.Section]) {
        // Measured without the scroll view, which has no height of its own.
        let measured = NSHostingView(rootView: WindowCheatSheetContent(sections: sections).frame(width: Self.width)).fittingSize.height
        let size = CGSize(width: Self.width, height: min(Self.maximumHeight, ceil(measured)))
        let view = WindowCheatSheetView(sections: sections, height: size.height)
        let panel = self.panel ?? FrogFloatingPanel(size: size, allowsKey: false)
        if let host { host.rootView = view } else {
            let host = NSHostingView(rootView: view)
            panel.contentView = host
            self.host = host
        }
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(origin: .zero, size: size)
        panel.show(at: CGRect(x: (screen.midX - size.width / 2).rounded(), y: (screen.midY - size.height / 2).rounded(),
                              width: size.width, height: size.height))
    }

    func hide() { panel?.orderOut(nil) }
}

struct WindowCheatSheetView: View {
    let sections: [WindowCheatSheet.Section]
    let height: CGFloat

    var body: some View {
        ScrollView { WindowCheatSheetContent(sections: sections) }
            .scrollIndicators(.never)
            .frame(width: WindowCheatSheetPanel.width, height: height)
            .frogPanel()
            .environment(\.locale, L10n.locale)
    }
}

/// The title and the grouped rows, without the panel around them.
struct WindowCheatSheetContent: View {
    let sections: [WindowCheatSheet.Section]

    var body: some View {
        VStack(alignment: .leading, spacing: FrogStyle.space16) {
            Text("Window shortcuts").font(FrogType.toolbarTitle).accessibilityAddTraits(.isHeader)
            if sections.isEmpty {
                // Shown only while its key is held, so it cannot offer a button: it says where the shortcuts are set.
                HStack(spacing: FrogStyle.space12) {
                    PluginIconTile(symbol: "rectangle.split.2x1", tint: PluginTint.purple.color, size: .list)
                    VStack(alignment: .leading, spacing: FrogStyle.space2) {
                        Text("No window shortcuts yet").font(FrogType.section)
                        Text("Give layouts a key in Frog → Windows, then hold this shortcut to see them here.")
                            .font(FrogType.small).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(FrogStyle.cardPadding).frame(maxWidth: .infinity, alignment: .leading).frogTableSurface()
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: FrogStyle.space8) {
                    Text(L10n.text(section.title)).font(FrogType.section).accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                    ForEach(section.items) { item in
                        HStack(spacing: 10) {
                            Group {
                                if let action = item.action { WindowLayoutGlyph(action: action) }
                                else if let command = item.command {
                                    Image(systemName: command.symbol).font(.system(size: 13)).foregroundStyle(FrogStyle.muted)
                                }
                            }.frame(width: 28)
                            Text(item.title).font(FrogType.row)
                            Spacer(minLength: 8)
                            ShortcutKeyCaps(hotkey: item.hotkey)
                        }
                        .padding(.horizontal, FrogStyle.cardPadding)
                        .frame(height: FrogStyle.rowHeight)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.title)
                        .accessibilityValue(HotkeyManager.display(item.hotkey))
                    }
                    }.frogTableSurface()
                }
            }
        }
        .padding(FrogStyle.sheetPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(FrogStyle.ink)
    }
}
