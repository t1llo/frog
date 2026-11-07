import AppKit
import FrogCore
import SwiftUI

/// The Notes editor: a borderless text area like `DocumentTextEditor`, in which `{{date}}`, `{{time}}` and
/// `{{clipboard}}` show as small accent tokens reading "date", "time" and "clipboard" rather than as raw braces.
/// Only how the text is drawn changes: the note keeps its braces, so pasting, searching and undo are untouched, and
/// the caret still steps over every character.
struct NoteTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Whether picking the note fills its tokens in. When it does not, they paste as written, so they show muted.
    var fillsTokens: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NoteTokenLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        // Takes back the line fragment padding, so the text starts on the card's content edge as in the other editor.
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let textView = NoteTextView(frame: .zero, textContainer: container)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.textContainerInset = .zero
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.typingAttributes = NoteTokenStyle.base
        textView.delegate = context.coordinator
        storage.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.fillsTokens = fillsTokens
        context.coordinator.appearance = FrogAppearance.shared.settings
        // Token colours are fixed once applied, so light and dark redraw them in the new appearance's colours.
        textView.appearanceChanged = { [weak coordinator = context.coordinator] in coordinator?.restyleAll() }
        textView.string = text

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        guard let textView = coordinator.textView else { return }
        // Whether tokens fill in, and the theme or accent, change every token's colours: the one whole restyle.
        let appearance = FrogAppearance.shared.settings
        if coordinator.fillsTokens != fillsTokens || coordinator.appearance != appearance {
            coordinator.fillsTokens = fillsTokens
            coordinator.appearance = appearance
            coordinator.restyleAll()
        }
        if textView.string != text, let storage = textView.textStorage {
            // A different note, or the text changed elsewhere: replace it, keeping the caret where it can stay. The
            // old text's undo steps point into text that is gone, so they go with it.
            let selection = textView.selectedRanges
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
            textView.undoManager?.removeAllActions(withTarget: textView)
            textView.undoManager?.removeAllActions(withTarget: storage)
            let length = (text as NSString).length
            textView.selectedRanges = selection.map {
                let location = min($0.rangeValue.location, length)
                return NSValue(range: NSRange(location: location, length: min($0.rangeValue.length, length - location)))
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        var fillsTokens = true
        var appearance = AppearancePreferences()

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if text.wrappedValue != textView.string { text.wrappedValue = textView.string }
        }

        func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
            guard mask.contains(.editedCharacters) else { return }
            // Text still being composed (an input method's marked text) is styled once it is committed.
            if textView?.hasMarkedText() == true { return }
            // Only the edited paragraphs: a token never spans a line, so the rest of a long note keeps its styling.
            restyle(storage, in: (storage.string as NSString).paragraphRange(for: range))
        }

        func restyleAll() {
            guard let textView, let storage = textView.textStorage else { return }
            // Resolved in the text view's own appearance, so light and dark each get their token colours.
            textView.effectiveAppearance.performAsCurrentDrawingAppearance {
                restyle(storage, in: NSRange(location: 0, length: storage.length))
            }
        }

        /// Styles `range` afresh: the base look, then every token in it.
        func restyle(_ storage: NSTextStorage, in range: NSRange) {
            guard range.length > 0 else { return }
            storage.beginEditing()
            storage.setAttributes(NoteTokenStyle.base, range: range)
            for match in NoteTokenStyle.pattern.matches(in: storage.string, range: range) {
                NoteTokenStyle.apply(to: storage, token: match.range, word: match.range(at: 1), filled: fillsTokens)
            }
            storage.endEditing()
        }
    }
}

/// The note's text view, which says when light or dark changes so the tokens can take the new colours.
final class NoteTextView: NSTextView {
    var appearanceChanged: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }
}

/// How a note's text and its tokens look.
enum NoteTokenStyle {
    static let pattern = try! NSRegularExpression(pattern: #"\{\{(date|time|clipboard)\}\}"#)
    /// Marks a token's background, so only tokens get rounded corners and the selection stays square.
    static let tokenKey = NSAttributedString.Key("FrogNoteToken")

    static var base: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        return [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    static func apply(to storage: NSTextStorage, token: NSRange, word: NSRange, filled: Bool) {
        let fill = filled ? NSColor(FrogStyle.accentSoft) : NSColor(FrogStyle.muted.opacity(0.15))
        storage.addAttributes([.backgroundColor: fill, tokenKey: true], range: token)
        storage.addAttribute(.foregroundColor, value: filled ? NSColor(FrogStyle.accentText) : NSColor.secondaryLabelColor, range: word)
        // The two braces on each side are drawn clear and pulled together, so they leave only a little padding
        // inside the token instead of showing.
        for brace in [NSRange(location: token.location, length: 2), NSRange(location: NSMaxRange(word), length: 2)] {
            storage.addAttributes([.foregroundColor: NSColor.clear, .kern: -3.0], range: brace)
        }
    }
}

/// Draws a token's background as a rounded rectangle; every other background, the selection among them, as usual.
final class NoteTokenLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rects: UnsafePointer<NSRect>, count: Int, forCharacterRange range: NSRange, color: NSColor) {
        guard let storage = textStorage, range.location < storage.length,
              storage.attribute(NoteTokenStyle.tokenKey, at: range.location, effectiveRange: nil) != nil,
              color != NSColor.selectedTextBackgroundColor, color != NSColor.unemphasizedSelectedTextBackgroundColor else {
            super.fillBackgroundRectArray(rects, count: count, forCharacterRange: range, color: color)
            return
        }
        color.setFill()
        for index in 0..<count {
            // The line's own height, without the paragraph's extra spacing under it.
            var rect = rects[index]
            rect.size.height -= 3
            NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 0.5), xRadius: 4, yRadius: 4).fill()
        }
    }
}

extension SnippetExpansion {
    /// A note as its preview shows it: as picking it would paste it, with the clipboard named rather than read,
    /// since the preview is not a paste. A note that does not fill its tokens in shows them as code.
    static func preview(_ text: String, fills: Bool) -> String {
        guard fills else {
            return NoteTokenStyle.pattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "`$1`")
        }
        return expand(text.replacingOccurrences(of: "{{clipboard}}", with: "`\(L10n.text("clipboard"))`"), clipboard: "")
    }
}
