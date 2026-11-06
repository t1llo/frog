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

    func show(_ outcome: RuleOutcome, rule: String? = nil) {
        processing = false
        let look = Self.appearance(of: outcome, rule: rule)
        present(symbol: look.symbol, warning: outcome.failure != nil, text: look.text, detail: look.detail,
                // A failure says what went wrong, so it stays long enough to be read.
                seconds: outcome.failure != nil ? 3.5 : 1)
    }

    /// What the pill says for an outcome. A failure says what failed first ("Proofread failed: Ollama is not
    /// running"), then where the details are.
    static func appearance(of outcome: RuleOutcome, rule: String? = nil) -> (symbol: String, text: String, detail: String?) {
        switch outcome {
        case .done: ("checkmark", "Done", nil)
        case .cancelled: ("checkmark", "Cancelled", nil)
        case .failed(let message):
            ("exclamationmark.circle", failureText(failureSummary(message), rule: rule), "Details in the Frog menu")
        }
    }

    /// "Proofread failed: Ollama is not running", or the reason alone when the rule is not known.
    static func failureText(_ summary: String, rule: String?) -> String {
        guard let rule = rule?.trimmingCharacters(in: .whitespaces), !rule.isEmpty else { return summary }
        let failed = String(format: L10n.text("%@ failed"), rule)
        return summary == "Failed" ? failed : failed + ": " + summary
    }

    /// The first line of a failure, without a closing full stop, so it reads as a short headline in the pill.
    static func failureSummary(_ message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return "Failed" }
        return line.hasSuffix(".") && !line.hasSuffix("...") ? String(line.dropLast()) : line
    }

    /// A short note that ends nothing, such as a press Frog could not act on yet.
    func note(_ text: String) { present(symbol: "hourglass", warning: false, text: text) }

    /// `symbol` nil shows a spinner.
    private func present(symbol: String?, warning: Bool, text: String, detail: String? = nil, seconds: Double = 1) {
        dismissal?.cancel()
        if panel == nil {
            let created = NSPanel(contentRect: NSRect(x: 0, y: 0, width: ProcessingPill.minWidth, height: ProcessingPill.height),
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
        let host = NSHostingView(rootView: ProcessingPill(symbol: symbol, warning: warning, text: text, detail: detail))
        // The pill hugs its text, so the panel takes its size, up to `maxWidth`, where a long failure is cut
        // short instead, and stays centred on the screen it shows on.
        let fitting = host.fittingSize
        let size = NSSize(width: min(max(fitting.width, ProcessingPill.minWidth), ProcessingPill.maxWidth), height: ProcessingPill.height)
        panel.contentView = host
        let screen = panel.isVisible ? panel.screen : NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        if let screen {
            panel.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 24,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        dismissal = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
                self?.panel?.fadeOut()
                self?.dismissal = nil
            } catch { }
        }
    }

    func hide() { dismissal?.cancel(); dismissal = nil; processing = false; panel?.orderOut(nil) }
}

/// The indicator's pill: a spinner or a symbol, a short text and, for a failure, where its details are. It hugs
/// its text from `minWidth`; the panel stops at `maxWidth`, where a long failure is cut in the middle.
struct ProcessingPill: View {
    static let height: CGFloat = 36
    static let minWidth: CGFloat = 132
    static let maxWidth: CGFloat = 420
    let symbol: String?
    let warning: Bool
    let text: String
    var detail: String? = nil
    var body: some View {
        FrogNoticePill(symbol: symbol, tone: warning ? FrogStyle.warning : FrogStyle.accent, text: text, detail: detail,
                       minWidth: Self.minWidth)
    }
}

/// The small status pill along the bottom of the screen (Working, Done, a failure, Secure Input): a 36-point
/// capsule with a symbol or spinner, the message in the text colour, and an optional muted detail after it.
struct FrogNoticePill: View {
    let symbol: String?
    var tone: Color = FrogStyle.accent
    let text: String
    var detail: String? = nil
    var minWidth: CGFloat = 0
    var body: some View {
        HStack(spacing: FrogStyle.space8) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tone)
            } else {
                FrogSpinner()
            }
            Text(L10n.text(text)).font(FrogType.label).foregroundStyle(FrogStyle.ink)
                .lineLimit(1).truncationMode(.middle).layoutPriority(1)
            if let detail {
                Text(L10n.text(detail)).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
            }
        }
        .padding(.horizontal, FrogStyle.space16)
        .frame(minWidth: minWidth)
        .frame(height: ProcessingPill.height)
        .frogPanel(pill: true)
        .accessibilityElement(children: .combine)
    }
}
