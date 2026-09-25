import AppKit
import SwiftUI
import FrogCore

@MainActor
final class ShortcutReferencePanel {
    private var panel: NSPanel?
    func hide() { panel?.orderOut(nil) }
    func show(rules: [Rule]) {
        if panel?.isVisible == true { hide(); return }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = .floating; self.panel = panel
        }
        panel?.title = L10n.text("Frog shortcuts")
        panel?.contentView = NSHostingView(rootView: ShortcutReferenceView(rules: rules))
        panel?.center(); panel?.makeKeyAndOrderFront(nil)
    }
}
private struct ShortcutReferenceView: View {
    let rules: [Rule]
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(rules.filter { $0.enabled && $0.hotkey != nil }) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) { Text(rule.name); Text(L10n.text(rule.category.title)).font(.caption).foregroundStyle(.secondary) }
                        Spacer(); ShortcutBadge(text: HotkeyManager.display(rule.hotkey!))
                    }
                }
                if !rules.contains(where: { $0.enabled && $0.hotkey != nil }) { Text("Add shortcuts in Rules.").foregroundStyle(.secondary) }
            }.padding(20)
        }.frame(width: 460, height: 420).background(FrogStyle.canvas)
            .environment(\.locale, L10n.locale)
    }
}
