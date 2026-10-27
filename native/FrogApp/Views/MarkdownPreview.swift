import SwiftUI

/// One block of a note's Markdown preview. A `Text` draws emphasis, code spans and links but
/// no headings, lists, quotes, code blocks or tables, so the preview lays those out itself,
/// one block below the other.
struct MarkdownBlock: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case paragraph
        case heading(level: Int)
        case code
        case rule
        /// Rows of cells. The first row is the table's header.
        case table([[AttributedString]])
    }
    let id: Int
    var kind: Kind
    var text = AttributedString()
    /// The bullet or number of a list item, on the first block of the item only.
    var marker: String?
    /// The number of lists the block is nested in.
    var listDepth = 0
    var quoted = false
}

enum MarkdownPreview {
    /// Foundation parses the Markdown and names the block each stretch of text belongs to; this
    /// collects the stretches into blocks. A note of 100 KB takes about half a second, so the
    /// preview calls it off the main thread.
    static func blocks(_ markdown: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let read = try? AttributedString(markdown: markdown, options: options) else {
            return markdown.isEmpty ? [] : [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(markdown))]
        }
        let parsed = keepingLineBreaks(read)
        var blocks: [MarkdownBlock] = []
        var markedItems = Set<Int>()
        var openTable: (table: Int, row: Int)?
        for (intent, range) in parsed.runs[\.presentationIntent] {
            var text = AttributedString(parsed[range])
            // A code block and a block of HTML end with the line break that closes them.
            while text.characters.last?.isNewline == true { text.characters.removeLast() }
            var block = MarkdownBlock(id: blocks.count, kind: .paragraph, text: text)
            // Components run from the block itself outwards to the lists and quotes around it.
            var item: (identity: Int, ordinal: Int)?
            var ordered: Bool?
            var cell: (table: Int?, row: Int?, column: Int) = (nil, nil, 0)
            for component in intent?.components ?? [] {
                switch component.kind {
                case .header(let level): block.kind = .heading(level: level)
                case .codeBlock: block.kind = .code
                case .thematicBreak: block.kind = .rule
                case .blockQuote: block.quoted = true
                case .listItem(let ordinal): if item == nil { item = (component.identity, ordinal) }
                case .orderedList, .unorderedList:
                    block.listDepth += 1
                    if item != nil, ordered == nil { ordered = component.kind == .orderedList }
                case .tableCell(let column): cell.column = column
                case .tableHeaderRow, .tableRow: cell.row = component.identity
                case .table: cell.table = component.identity
                default: break
                }
            }
            if let item, markedItems.insert(item.identity).inserted { block.marker = ordered == true ? "\(item.ordinal)." : "•" }
            guard let table = cell.table, let row = cell.row else { blocks.append(block); openTable = nil; continue }
            // Foundation leaves out an empty cell, so the column index places the next one.
            if let last = blocks.indices.last, openTable?.table == table, case .table(var rows) = blocks[last].kind {
                if openTable?.row != row { rows.append([]) }
                rows[rows.count - 1] += Array(repeating: AttributedString(), count: max(0, cell.column - rows[rows.count - 1].count)) + [text]
                blocks[last].kind = .table(rows)
            } else {
                block.kind = .table([Array(repeating: AttributedString(), count: cell.column) + [text]])
                block.text = AttributedString()
                blocks.append(block)
            }
            openTable = (table, row)
        }
        return blocks
    }

    /// Foundation reads a line break inside a paragraph as a space marked as a soft break. The
    /// preview keeps it a line break, as the note was typed: a list, an address or a poem
    /// written without Markdown keeps its lines.
    private static func keepingLineBreaks(_ text: AttributedString) -> AttributedString {
        var kept = AttributedString(), copied = text.startIndex
        for (intent, range) in text.runs[\.inlinePresentationIntent] {
            guard var intent, intent.contains(.softBreak) else { continue }
            intent.remove(.softBreak); intent.insert(.lineBreak)
            var lineBreak = AttributedString(text[range])
            lineBreak.characters.replaceSubrange(lineBreak.startIndex..<lineBreak.endIndex, with: "\n")
            lineBreak.inlinePresentationIntent = intent
            kept += text[copied..<range.lowerBound]; kept += lineBreak
            copied = range.upperBound
        }
        kept += text[copied...]
        return kept
    }
}

struct MarkdownPreviewView: View {
    let markdown: String
    @State private var blocks: [MarkdownBlock] = []
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 9) { ForEach(blocks) { MarkdownBlockView(block: $0) } }
                .font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .task(id: markdown) {
            let text = markdown
            let parsed = await Task.detached(priority: .userInitiated) { MarkdownPreview.blocks(text) }.value
            if !Task.isCancelled { blocks = parsed }
        }
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if block.listDepth > 0 {
                Text(block.marker ?? "").monospacedDigit().foregroundStyle(FrogStyle.muted)
                    .frame(minWidth: 20, alignment: .trailing).padding(.leading, CGFloat(block.listDepth - 1) * 20)
            }
            content
        }
        .padding(.leading, block.quoted ? 10 : 0)
        .overlay(alignment: .leading) { if block.quoted { Rectangle().fill(FrogStyle.border).frame(width: 2) } }
    }
    @ViewBuilder private var content: some View {
        switch block.kind {
        case .paragraph: Text(block.text).foregroundStyle(block.quoted ? FrogStyle.muted : FrogStyle.ink)
        case .heading(let level): Text(block.text).font(.system(size: level == 1 ? 20 : level == 2 ? 17 : level == 3 ? 15 : 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
        case .code:
            Text(block.text).font(.system(size: 12, design: .monospaced)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
        case .rule: Rectangle().fill(FrogStyle.border).frame(height: 1).frame(maxWidth: .infinity)
        case .table(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(rows.indices, id: \.self) { row in
                    GridRow { ForEach(rows[row].indices, id: \.self) { Text(rows[row][$0]).fontWeight(row == 0 ? .semibold : nil) } }
                }
            }
        }
    }
}
