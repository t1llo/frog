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

    /// The text's paragraphs, set apart by blank lines, each hard-wrapped one joined into one line. A paragraph with
    /// indented or listed lines keeps its line breaks.
    static func paragraphs(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard !lines.isEmpty else { return nil }
            let kept = lines.dropFirst().contains { $0.hasPrefix(" ") || $0.hasPrefix("\t") || $0.hasPrefix("-") || $0.hasPrefix("*") }
            return kept ? lines.joined(separator: "\n") : lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }
    }
}

extension LegalDocument {
    /// How a paragraph of a short text reads: its short first line is the heading, and a paragraph set in capitals
    /// (a licence's warranty disclaimer) keeps its words and case but is set small and quiet so it doesn't shout.
    enum ParagraphStyle: Equatable {
        case heading, prose, capitals
        var font: Font { self == .heading ? FrogType.section : self == .capitals ? FrogType.small : FrogType.body }
        var muted: Bool { self == .capitals }
    }

    static func style(of paragraph: String, at index: Int) -> ParagraphStyle {
        if index == 0, paragraph.count <= 40, !paragraph.contains("\n") { return .heading }
        let letters = paragraph.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let capitals = letters.filter { CharacterSet.uppercaseLetters.contains($0) }
        return letters.count >= 80 && capitals.count * 10 >= letters.count * 9 ? .capitals : .prose
    }
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

    /// A short text's paragraphs, its heading line and copyright line aside: those become the sheet's title and
    /// subtitle, so "License" over "MIT License" never says the same thing twice.
    private var parts: (title: String, subtitle: String?, body: [String]) {
        var paragraphs = LegalDocument.paragraphs(text)
        guard short, let first = paragraphs.first, LegalDocument.style(of: first, at: 0) == .heading else {
            return (document.title, document.summary, paragraphs)
        }
        paragraphs.removeFirst()
        var subtitle = document.summary
        if let copyright = paragraphs.first, copyright.hasPrefix("Copyright"), !copyright.contains("\n") {
            subtitle = copyright
            paragraphs.removeFirst()
        }
        return (first, subtitle, paragraphs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FrogStyle.space16) {
            // A sheet is its own window, so its header keeps the title.
            let parts = parts
            FrogPageHeader(title: parts.title, subtitle: parts.subtitle).environment(\.frogToolbarTitle, false)
            Group {
                if short {
                    // A short text such as the licence reads as prose: its hard-wrapped lines joined into paragraphs in
                    // the body font, and the sheet as tall as the text, with no empty card under it.
                    FrogSheetScroll(maxHeight: 420) {
                        VStack(alignment: .leading, spacing: FrogStyle.space10) {
                            ForEach(Array(parts.body.enumerated()), id: \.offset) { index, paragraph in
                                let style = LegalDocument.style(of: paragraph, at: parts.body.count == LegalDocument.paragraphs(text).count ? index : index + 2)
                                Text(paragraph).font(style.font).foregroundStyle(style.muted ? FrogStyle.muted : FrogStyle.ink)
                                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityAddTraits(style == .heading ? .isHeader : [])
                            }
                        }
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, FrogStyle.cardPadding).padding(.vertical, FrogStyle.space16)
                    }
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
