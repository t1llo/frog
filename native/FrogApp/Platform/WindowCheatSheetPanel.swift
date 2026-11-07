import AppKit
import SwiftUI
import FrogCore

/// The window shortcuts, shown while the cheat sheet shortcut is held. Never key and never
/// activates Frog, so the front app keeps its focus. Created once and reused.
@MainActor
final class WindowCheatSheetPanel {
    static let width: CGFloat = 460
    /// Where the screen is unknown, as in the screenshot harness.
    static let maximumHeight: CGFloat = 640
    /// As tall as the display allows, less a margin, so a long list is seen whole while the key is held: it cannot
    /// be scrolled without the pointer.
    static func maximumHeight(on screen: NSScreen?) -> CGFloat {
        screen.map { max(320, $0.visibleFrame.height - 80) } ?? maximumHeight
    }

    private var panel: FrogFloatingPanel?
    private var host: NSHostingView<WindowCheatSheetView>?

    func show(sections: [WindowCheatSheet.Section]) {
        // Measured without the scroll view, which has no height of its own.
        let measured = NSHostingView(rootView: WindowCheatSheetContent(sections: sections).frame(width: Self.width)).fittingSize.height
        // As tall as the display it opens on, the one under the pointer, allows.
        let mouse = NSEvent.mouseLocation
        let display = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let size = CGSize(width: Self.width, height: min(Self.maximumHeight(on: display), ceil(measured)))
        let view = WindowCheatSheetView(sections: sections, height: size.height)
        let panel = self.panel ?? FrogFloatingPanel(size: size, allowsKey: false)
        if let host { host.rootView = view } else {
            let host = NSHostingView(rootView: view)
            panel.contentView = host
            self.host = host
        }
        self.panel = panel
        let screen = display?.visibleFrame ?? CGRect(origin: .zero, size: size)
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

/// The title and the grouped rows, without the panel around them: the shortcut reference's layout.
struct WindowCheatSheetContent: View {
    let sections: [WindowCheatSheet.Section]

    var body: some View {
        ShortcutPanelLayout(title: "Window shortcuts") {
            if sections.isEmpty {
                // Shown only while its key is held, so it cannot offer a button: it says where the shortcuts are set.
                FrogEmptyState(symbol: "rectangle.split.2x1", title: "No window shortcuts yet",
                               message: "Give layouts a key in Frog → Windows, then hold this shortcut to see them here.",
                               tint: .purple)
                    .frogTableSurface()
            } else {
                ShortcutPanelCard {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        ShortcutPanelCaption(title: section.title, first: index == 0)
                        ForEach(section.items) { item in
                            ShortcutPanelRow(title: item.title, hotkey: item.hotkey) {
                                if let action = item.action { WindowLayoutGlyph(action: action) }
                                else if let command = item.command { ShortcutPanelSymbol(name: command.symbol) }
                            }
                            .accessibilityLabel(item.title)
                        }
                    }
                }
            }
        }
    }
}
