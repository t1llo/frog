import AppKit
import SwiftUI

/// Non-activating, click-through feedback keeps the source selection focused.
@MainActor
final class ProcessingIndicator {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?
    private var processing = false
    /// Opens where a failure's whole message is: the Frog window, whose banner shows and copies it.
    var showDetails: (() -> Void)?

    /// The spinner and the rule it runs ("Proofread…"), as the Frog menu's status names it.
    func showWorking(rule: String? = nil) {
        // Flash once at the start; progress updates must not keep bringing it back.
        if processing { return }
        processing = true
        present(symbol: nil, warning: false, text: Self.workingText(rule: rule))
    }

    /// "Proofread…", or "Working…" when the rule is not known.
    static func workingText(rule: String?) -> String {
        guard let rule = rule?.trimmingCharacters(in: .whitespaces), !rule.isEmpty else { return L10n.text("Working…") }
        return rule + "…"
    }

    func show(_ outcome: RuleOutcome, rule: String? = nil) {
        processing = false
        let look = Self.appearance(of: outcome, rule: rule)
        // A failure offers its details as a button, so it stays long enough to be read and clicked.
        let details = look.detail.flatMap { title in showDetails.map { open in (title: title, run: open) } }
        present(symbol: look.symbol, warning: outcome.failure != nil, text: look.text, detail: details == nil ? look.detail : nil,
                action: details, seconds: outcome.failure != nil ? (details == nil ? 3.5 : 5) : 1)
    }

    /// What the pill says for an outcome. A failure says what failed first ("Proofread failed: Ollama is not
    /// running"), then offers its details.
    static func appearance(of outcome: RuleOutcome, rule: String? = nil) -> (symbol: String, text: String, detail: String?) {
        switch outcome {
        case .done: ("checkmark", "Done", nil)
        case .cancelled: ("checkmark", "Cancelled", nil)
        case .failed(let message):
            ("exclamationmark.circle", failureText(failureSummary(message), rule: rule), "Show details")
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

    /// `symbol` nil shows a spinner. With `action` the pill takes clicks for its one button; otherwise it lets them
    /// through to the app beneath.
    private func present(symbol: String?, warning: Bool, text: String, detail: String? = nil,
                         action: (title: String, run: () -> Void)? = nil, seconds: Double = 1) {
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
        panel.ignoresMouseEvents = action == nil
        let run = action.map { action in { [weak self] in self?.hide(); action.run() } }
        let host = NSHostingView(rootView: ProcessingPill(symbol: symbol, warning: warning, text: text, detail: detail,
                                                          action: action.map { ($0.title, run!) }))
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

/// The indicator's pill: a spinner or a symbol, a short text and, for a failure, a Show details button. It hugs
/// its text from `minWidth`; the panel stops at `maxWidth`, where a long failure is cut in the middle.
struct ProcessingPill: View {
    static let height: CGFloat = 36
    static let minWidth: CGFloat = 132
    static let maxWidth: CGFloat = 420
    let symbol: String?
    let warning: Bool
    let text: String
    var detail: String? = nil
    var action: (title: String, run: () -> Void)? = nil
    var body: some View {
        FrogNoticePill(symbol: symbol, tone: warning ? FrogStyle.warning : FrogStyle.accent, text: text, detail: detail,
                       action: action, minWidth: Self.minWidth)
    }
}

/// The small status pill along the bottom of the screen (Working, Done, a failure, Secure Input): a 36-point
/// capsule with a symbol or spinner, the message in the text colour, and an optional muted detail or one compact
/// ghost button after it (a failure's Show details).
struct FrogNoticePill: View {
    let symbol: String?
    var tone: Color = FrogStyle.accent
    let text: String
    var detail: String? = nil
    var action: (title: String, run: () -> Void)? = nil
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
            if let action {
                Button(L10n.text(action.title), action: action.run).buttonStyle(.frog(.ghost, compact: true)).fixedSize()
                    .padding(.trailing, -FrogStyle.space10)
            }
        }
        .padding(.horizontal, FrogStyle.space16)
        .frame(minWidth: minWidth)
        .frame(height: ProcessingPill.height)
        .frogPanel(pill: true)
        .accessibilityElement(children: .combine)
    }
}
