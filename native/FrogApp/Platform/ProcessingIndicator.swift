import AppKit
import SwiftUI

/// Non-activating, click-through feedback keeps the source selection focused.
@MainActor
final class ProcessingIndicator {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    func show(_ message: String, working: Bool) {
        dismissal?.cancel()
        if panel == nil {
            let created = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            created.level = .floating
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = true
            created.ignoresMouseEvents = true
            created.hidesOnDeactivate = false
            created.isReleasedWhenClosed = false
            panel = created
        }
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView: HStack(spacing: 14) {
            if working { ProgressView().controlSize(.small) }
            else { Image(systemName: "text.badge.checkmark").foregroundStyle(FrogStyle.accent) }
            Text(message).font(.system(size: 13, weight: .medium)).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(18).frame(width: 360, height: 80).background(FrogStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(FrogStyle.border, lineWidth: 1)).preferredColorScheme(.dark))
        if !panel.isVisible, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 180, y: screen.visibleFrame.minY + 40))
        }
        panel.orderFrontRegardless()
        if !working {
            dismissal = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)); self?.hide() } catch { }
            }
        }
    }

    func hide() { dismissal?.cancel(); dismissal = nil; panel?.orderOut(nil) }
}
