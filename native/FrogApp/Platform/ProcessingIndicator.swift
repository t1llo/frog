import AppKit
import SwiftUI

/// Non-activating, click-through feedback keeps the source selection focused.
@MainActor
final class ProcessingIndicator {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?
    private var processing = false

    func showWorking() {
        // Flash once at the start; progress updates must not keep bringing it back.
        if processing { return }
        processing = true
        present(symbol: nil, warning: false, text: "Working…")
    }

    func show(_ outcome: RuleOutcome) {
        processing = false
        let (symbol, text) = Self.appearance(of: outcome)
        present(symbol: symbol, warning: outcome.failure != nil, text: text)
    }

    static func appearance(of outcome: RuleOutcome) -> (symbol: String, text: String) {
        switch outcome {
        case .done: ("checkmark", "Done")
        case .cancelled: ("checkmark", "Cancelled")
        case .failed: ("exclamationmark.circle", "Details in the Frog menu")
        }
    }

    /// A short note that ends nothing, such as a press Frog could not act on yet.
    func note(_ text: String) { present(symbol: "hourglass", warning: false, text: text) }

    /// `symbol` nil shows a spinner.
    private func present(symbol: String?, warning: Bool, text: String) {
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
        panel.alphaValue = 1
        panel.contentView = NSHostingView(rootView: HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol).foregroundStyle(warning ? FrogStyle.warning : FrogStyle.accent) }
            else { ProgressView().controlSize(.small) }
            Text(text).font(FrogType.label).lineLimit(1)
        }.frame(width: 200, height: 36).frogPanel(pill: true))
        if !panel.isVisible, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 100, y: screen.visibleFrame.minY + 24))
        }
        panel.orderFrontRegardless()
        dismissal = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                self?.panel?.fadeOut()
                self?.dismissal = nil
            } catch { }
        }
    }

    func hide() { dismissal?.cancel(); dismissal = nil; processing = false; panel?.orderOut(nil) }
}

extension NSWindow {
    /// A status pill leaving: it fades over `FrogMotion.fadeOut`, then orders out. Setting `alphaValue` back to 1
    /// meanwhile ends the fade and keeps the window. Only for windows whose content stays as it was while fading.
    func fadeOut() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = FrogMotion.fadeOut
            context.timingFunction = FrogMotion.fadeOutCurve
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.alphaValue < 0.01 else { return }
            self.orderOut(nil)
        }
    }
}
