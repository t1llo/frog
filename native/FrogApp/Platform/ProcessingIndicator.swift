import AppKit
import SwiftUI

/// Non-activating, click-through feedback keeps the source selection focused.
@MainActor
final class ProcessingIndicator {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?
    private var processing = false

    func show(_ message: String, working: Bool, failed: Bool = false) {
        // Flash once at the start; progress updates must not keep bringing it back.
        if working && processing { return }
        processing = working
        dismissal?.cancel()
        if panel == nil {
            let created = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 36),
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
        panel.alphaValue = 0.9
        panel.contentView = NSHostingView(rootView: HStack(spacing: 8) {
            if working { ProgressView().controlSize(.small) }
            else { Image(systemName: failed ? "exclamationmark.circle" : "checkmark").foregroundStyle(failed ? .orange : FrogStyle.accent) }
            Text(working ? "Working…" : (failed ? "Check Frog for details" : (message.hasPrefix("Cancelled") ? "Cancelled" : "Done")))
                .font(.system(size: 11, weight: .medium)).lineLimit(1)
        }.frame(width: 200, height: 36).background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5)).preferredColorScheme(.dark))
        if !panel.isVisible, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 100, y: screen.visibleFrame.minY + 24))
        }
        panel.orderFrontRegardless()
        dismissal = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                self?.panel?.orderOut(nil)
                self?.dismissal = nil
            } catch { }
        }
    }

    func hide() { dismissal?.cancel(); dismissal = nil; processing = false; panel?.orderOut(nil) }
}
