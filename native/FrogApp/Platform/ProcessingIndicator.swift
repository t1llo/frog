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

    /// The spinner and what the rule is doing ("Proofreading…"), as the Frog menu's status names it.
    func showWorking(rule: String? = nil) {
        // Flash once at the start; progress updates must not keep bringing it back.
        if processing { return }
        processing = true
        present(symbol: nil, tone: FrogStyle.accent, text: Self.workingText(rule: rule))
    }

    /// "Proofreading…" for a rule whose name starts with a verb Frog knows, the rule's own name ("Spelling only…")
    /// otherwise, or "Working…" when the rule is not known. Always the one ellipsis character.
    static func workingText(rule: String?) -> String {
        guard let rule = rule?.trimmingCharacters(in: .whitespaces), !rule.isEmpty else { return L10n.text("Working…") }
        return (progressive(rule) ?? rule) + "…"
    }

    /// The rule's name with its leading verb in the -ing form ("Translate to German" → "Translating to German"), in
    /// English only and only for the verbs rules are named with, so a name that is not a command stays as it is.
    static func progressive(_ rule: String) -> String? {
        guard L10n.locale.language.languageCode?.identifier ?? "en" == "en" else { return nil }
        let words = rule.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = words.first, let verb = progressiveVerbs[first.lowercased()] else { return nil }
        let capitalised = first.first?.isUppercase == true ? verb.prefix(1).uppercased() + verb.dropFirst() : verb
        return words.count > 1 ? "\(capitalised) \(words[1])" : capitalised
    }

    private static let progressiveVerbs: [String: String] = [
        "proofread": "proofreading", "translate": "translating", "summarize": "summarizing", "summarise": "summarising",
        "polish": "polishing", "shorten": "shortening", "rewrite": "rewriting", "fix": "fixing", "improve": "improving",
        "explain": "explaining", "define": "defining", "simplify": "simplifying", "expand": "expanding",
        "correct": "correcting", "format": "formatting", "reply": "replying", "write": "writing", "make": "making",
        "convert": "converting", "clean": "cleaning", "check": "checking", "tidy": "tidying", "draft": "drafting",
    ]

    /// How the run ended. Done names the rule and what it did ("Proofread · 3 words changed"), so the pill says
    /// more than that something finished. There is no Undo: the app the text went into keeps that (⌘Z there).
    func show(_ outcome: RuleOutcome, rule: String? = nil, summary: String? = nil) {
        processing = false
        let look = Self.appearance(of: outcome, rule: rule, summary: summary)
        // A failure offers its details as a button, so it stays long enough to be read and clicked.
        let details = look.detail.flatMap { title in outcome.failure == nil ? nil : showDetails.map { open in (title: title, run: open) } }
        present(symbol: look.symbol, tone: look.tone, text: look.text, detail: details == nil ? look.detail : nil,
                action: details, seconds: outcome.failure != nil ? (details == nil ? 3.5 : 5) : 1.4)
    }

    /// What the pill says for an outcome. Done names the rule and, muted, what changed; a failure says what failed
    /// first ("Proofread failed: Ollama is not running"), then offers its details.
    static func appearance(of outcome: RuleOutcome, rule: String? = nil, summary: String? = nil)
        -> (symbol: String, tone: Color, text: String, detail: String?) {
        let trimmed = rule?.trimmingCharacters(in: .whitespaces) ?? ""
        let name: String? = trimmed.isEmpty ? nil : trimmed
        switch outcome {
        case .done: return ("checkmark.circle.fill", FrogStyle.good, name ?? L10n.text("Done"), name == nil ? nil : summary ?? L10n.text("Done"))
        case .cancelled: return ("xmark.circle.fill", FrogStyle.muted, name.map { String(format: L10n.text("%@ cancelled"), $0) } ?? L10n.text("Cancelled"), nil)
        case .failed(let message):
            return (failureSymbol, FrogStyle.warning, failureText(failureSummary(message), rule: rule), "Show details")
        }
    }

    /// The one warning glyph of a failure, in the pill and the answer panel alike.
    static let failureSymbol = "exclamationmark.triangle.fill"

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
    func note(_ text: String) { present(symbol: "hourglass", tone: FrogStyle.muted, text: text) }

    /// `symbol` nil shows a spinner. With `action` the pill takes clicks for its one button; otherwise it lets them
    /// through to the app beneath.
    private func present(symbol: String?, tone: Color, text: String, detail: String? = nil,
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
        let host = NSHostingView(rootView: ProcessingPill(symbol: symbol, tone: tone, text: text, detail: detail,
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
    var tone: Color = FrogStyle.accent
    let text: String
    var detail: String? = nil
    var action: (title: String, run: () -> Void)? = nil
    var body: some View {
        FrogNoticePill(symbol: symbol, tone: tone, text: text, detail: detail,
                       action: action, minWidth: Self.minWidth)
    }
}

/// The small status pill along the bottom of the screen (Working, Done, a failure, Secure Input): a 36-point
/// capsule with a symbol or spinner, the message in the text colour, and an optional muted detail after a `·`
/// ("Proofread · 3 words changed") or one compact secondary button (a failure's Show details).
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
                // As close to the message as the dot's own spaces, so the two read as one line.
                Text(verbatim: "·  " + L10n.text(detail)).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
                    .padding(.leading, -FrogStyle.space4)
            }
            if let action {
                // The pill's one button, a grey pill like every secondary action, ending 6 in from the capsule's end.
                Button(L10n.text(action.title), action: action.run).buttonStyle(.frog()).fixedSize()
                    .padding(.leading, FrogStyle.space4).padding(.trailing, -(FrogStyle.space16 - FrogStyle.space6))
            }
        }
        .padding(.horizontal, FrogStyle.space16)
        .frame(minWidth: minWidth)
        .frame(height: ProcessingPill.height)
        .frogPanel(pill: true)
        .accessibilityElement(children: .combine)
    }
}
