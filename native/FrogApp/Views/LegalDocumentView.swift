import SwiftUI
import AppKit

/// License texts that `scripts/build-app.sh` puts in the packaged app's Resources.
enum LegalDocument: String, Identifiable, CaseIterable {
    case license = "LICENSE"
    case thirdPartyNotices = "ThirdPartyNotices"

    var id: String { rawValue }
    var title: String { self == .license ? "License" : "Third-party notices" }
    /// Nil when the text's first line already says it, as the licence's "MIT License" does.
    var summary: String? {
        self == .license ? nil : "Licenses of the open-source software Frog is built with."
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

    /// Short enough for SwiftUI to measure at once; longer texts go to AppKit, which lays out only what shows.
    private var short: Bool { text.count < 6000 }

    var body: some View {
        VStack(alignment: .leading, spacing: FrogStyle.space16) {
            // A sheet is its own window, so its header keeps the title.
            FrogPageHeader(title: document.title, subtitle: document.summary).environment(\.frogToolbarTitle, false)
            Group {
                if short {
                    // A short text such as the licence: the sheet is as tall as the text, with no empty card under it.
                    ScrollView {
                        Text(text).font(FrogType.mono).foregroundStyle(FrogStyle.ink).textSelection(.enabled)
                            .lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, FrogStyle.cardPadding).padding(.vertical, FrogStyle.space12)
                    }.frame(maxHeight: 400).fixedSize(horizontal: false, vertical: true)
                } else {
                    ReadOnlyText(text: text).frame(height: 360)
                }
            }
            .frogTableSurface().accessibilityLabel(L10n.text(document.title))
            FrogSheetButtons(padded: false) { FrogPrimaryButton("Done") { dismiss() } }
        }.padding(FrogStyle.sheetPadding).frame(width: 640).foregroundStyle(FrogStyle.ink).background(FrogStyle.panelSurface)
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
        view.textContainerInset = NSSize(width: 10, height: 12)
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}
}
