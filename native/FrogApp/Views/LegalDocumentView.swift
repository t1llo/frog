import SwiftUI
import AppKit

/// License texts that `scripts/build-app.sh` puts in the packaged app's Resources.
enum LegalDocument: String, Identifiable, CaseIterable {
    case license = "LICENSE"
    case thirdPartyNotices = "ThirdPartyNotices"

    var id: String { rawValue }
    var title: String { self == .license ? "License" : "Third-party notices" }
    var summary: String {
        self == .license ? "GNU General Public License, version 3 or later."
            : "Licenses of the open-source software Frog is built with."
    }
    /// Nil outside a packaged app, such as under `swift run`, Xcode and tests.
    func url(in bundle: Bundle = .main) -> URL? { bundle.url(forResource: rawValue, withExtension: "txt") }
    func text(in bundle: Bundle = .main) -> String? { url(in: bundle).flatMap { try? String(contentsOf: $0, encoding: .utf8) } }
}

struct LegalDocumentView: View {
    let document: LegalDocument
    private let text: String
    @Environment(\.dismiss) private var dismiss

    init(document: LegalDocument, bundle: Bundle = .main) {
        self.document = document
        text = document.text(in: bundle) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: document.title, subtitle: document.summary)
            ReadOnlyText(text: text).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.cardRadius))
                .accessibilityLabel(L10n.text(document.title))
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.frog(.primary)).keyboardShortcut(.defaultAction) }
        }.padding(22).frame(width: 640, height: 520).foregroundStyle(FrogStyle.ink).background(FrogStyle.panelSurface)
            .buttonStyle(.frog()).environment(\.locale, L10n.locale)
    }
}

/// AppKit lays out only the visible part of a long text; a SwiftUI `Text` measures all of it at once.
private struct ReadOnlyText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.drawsBackground = false
        view.isEditable = false; view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 8, height: 10)
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}
}
