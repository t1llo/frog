import AppKit
import FrogCore
import SwiftUI

/// The page Notes and Scripts share: the list down the side, headed by its search, and the chosen item in one card
/// that fills the page's height. The card has the item's own actions along its top (`toolbar`, then "…"), its text,
/// and a slim footer row with what belongs to that item or to running it (`footer`). An item's title heads its text in
/// the card, renamed in place there or in the list (double-click, "Rename" or right after adding).
struct DocumentsPage<Toolbar: View, Content: View, Footer: View>: View {
    @ObservedObject var documents: LocalDocuments
    let kind: UtilityDocument.Kind
    let title: String
    var subtitle: String? = nil
    let symbol: String
    let emptyMessage: String
    @ViewBuilder let toolbar: (UtilityDocument) -> Toolbar
    @ViewBuilder let content: (UtilityDocument) -> Content
    @ViewBuilder let footer: (UtilityDocument) -> Footer

    @State private var search = ""
    @State private var deleting: UUID?
    @State private var renaming: UUID?
    @State private var draftTitle = ""
    @FocusState private var renameFocused: Bool
    /// The list and card never get shorter than this, however small the window.
    private static var minHeight: CGFloat { 380 }
    private static var listWidth: CGFloat { 240 }

    private var selected: UUID? {
        get { documents.selection[kind] }
        nonmutating set { documents.selection[kind] = newValue }
    }
    private var all: [UtilityDocument] { documents.items(kind) }
    private var shown: [UtilityDocument] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? all : all.filter { ($0.title + " " + $0.text).localizedStandardContains(query) }
    }
    private var current: UtilityDocument? { all.first { $0.id == selected } }
    private var tint: PluginTint { kind == .note ? NotesPlugin.info.tint : ScriptsPlugin.info.tint }

    var body: some View {
        // The split fills what the window leaves under the toolbar, so the card reaches the page's bottom edge.
        GeometryReader { geometry in
            FrogPage {
                FrogPageHeader(title: title, subtitle: subtitle) {
                    FrogAddButton(kind == .note ? "Add note" : "Add script") {
                        search = ""
                        let id = documents.add(UtilityDocument(kind: kind, title: kind.newItemTitle))
                        selected = id
                        startRenaming(id)
                    }.disabled(!documents.loaded)
                }
                if let issue = documents.issue { notice(issue) }
                if let unreadable = documents.unreadable { notice(unreadable.message) }
                if documents.loaded, all.isEmpty {
                    FrogEmptyState(symbol: symbol, title: "No \(title.lowercased()) yet", message: emptyMessage, tint: tint)
                        .frogTableSurface()
                } else if documents.loaded {
                    HStack(alignment: .top, spacing: FrogStyle.space16) {
                        // The search heads the list it filters, as on every page with a search.
                        VStack(spacing: FrogStyle.space8) {
                            ListToolbar(placeholder: kind == .note ? "Search notes" : "Search scripts", search: $search)
                            list
                        }.frame(width: Self.listWidth)
                        Group {
                            if let current { card(current) }
                            else {
                                FrogEmptyState(symbol: shown.isEmpty ? "magnifyingglass" : symbol,
                                               title: shown.isEmpty ? "No matches" : "Nothing chosen",
                                               message: shown.isEmpty ? "Try another word." : "Choose one from the list.")
                                    .frame(maxWidth: .infinity, maxHeight: .infinity).frogTableSurface()
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .frame(height: max(Self.minHeight, geometry.size.height - FrogStyle.toolbarFade - FrogStyle.pagePadding))
                }
            }
        }
        .task {
            await documents.load()
            if current == nil { selected = all.first?.id }
        }
        .confirmationDialog(L10n.text(kind == .note ? "Delete this note?" : "Delete this script?"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let deleting { remove(deleting) }
                deleting = nil
            }
        } message: {
            Text(all.first { $0.id == deleting }?.files.isEmpty == false
                 ? "It is deleted from this Mac. Files it holds stay where they are."
                 : "It is deleted from this Mac.")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: FrogStyle.space2) {
                ForEach(shown) { item in row(item) }
                if shown.isEmpty {
                    Text("No matches").font(FrogType.body).foregroundStyle(FrogStyle.muted)
                        .padding(.horizontal, FrogStyle.rowInset).frame(maxWidth: .infinity, minHeight: FrogStyle.controlHeight, alignment: .leading)
                }
            }
        }.minimalScrollbars()
    }

    /// A list row: the title, and a dim line under it with when it was last changed and how it starts.
    @ViewBuilder private func row(_ item: UtilityDocument) -> some View {
        let isSelected = item.id == selected
        if renaming == item.id {
            FrogTextField(placeholder: "Title", text: $draftTitle).font(FrogType.body)
                .focused($renameFocused)
                .onSubmit { commitRename() }
                .onExitCommand { renaming = nil }
                .onChange(of: renameFocused) { _, focused in if !focused { commitRename() } }
                .padding(.horizontal, FrogStyle.rowInset)
                .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                .frogControlSurface(height: Self.rowHeight)
        } else {
            Button { selected = item.id } label: {
                HStack(spacing: FrogStyle.space6) {
                    VStack(alignment: .leading, spacing: FrogStyle.space2) {
                        Text(item.shownTitle).font(FrogType.body).foregroundStyle(FrogStyle.ink).lineLimit(1)
                        // Worked out again every minute, so "Just now" moves on while the page stays open.
                        TimelineView(.everyMinute) { _ in
                            Text(Self.detail(item)).font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if item.pastes {
                        FrogBadge(text: "Pastes").help("Pastes when picked in the command bar")
                    }
                }
                .padding(.horizontal, FrogStyle.rowInset)
                .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
                .frogHoverRow(selected: isSelected)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { startRenaming(item.id) })
            .contextMenu { menuItems(item) }
            .onDrag { provider(item) }
        }
    }

    private static var rowHeight: CGFloat { 44 }

    /// "18:07 · Best, Anna": when it last changed, then its first line.
    private static func detail(_ item: UtilityDocument) -> String {
        // Stops at the first line with text, so a long note is not split whole for every row on every keystroke.
        var first: String?
        item.text.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { first = trimmed; stop = true }
        }
        let time = RecentTimestamp.text(item.modified)
        guard let first else { return time + " · " + L10n.text(item.files.isEmpty ? "Empty" : "Files") }
        // The row shows one short line, so only its start is cleaned: the patterns stay cheap on a long first line.
        return time + " · " + (item.kind == .note ? MarkdownPreview.plain(String(first.prefix(200))) : first)
    }

    /// The chosen item: its actions along the top, its text filling the card, its footer band at the bottom.
    private func card(_ item: UtilityDocument) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: FrogStyle.space8) {
                toolbar(item)
                IconMenu(title: "More", bordered: false) { menuItems(item) }
            }
            .frame(height: Self.barHeight)
            .padding(.leading, FrogStyle.cardPadding).padding(.trailing, FrogStyle.space8)
            VStack(alignment: .leading, spacing: FrogStyle.space8) {
                // The item's name heads its text, as a document's title does, and is renamed in place.
                FrogTextField(placeholder: "Untitled", text: documents.binding(item.id, \.title))
                    .textFieldStyle(.plain).font(FrogType.title).tracking(-0.3)
                    .accessibilityLabel(kind == .note ? "Note title" : "Script title")
                    .help("Click to rename")
                ForEach(item.files, id: \.self) { url in fileRow(url) }
                content(item)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, FrogStyle.cardPadding).padding(.bottom, FrogStyle.space10)
            // When it was last edited, then the item's own options, ending on the card's content edge: a row on the
            // card's own fill, as the bar along its top is, rather than a band of another shade.
            HStack(spacing: FrogStyle.space8) {
                DocumentEditedText(date: item.modified).foregroundStyle(FrogStyle.muted).lineLimit(1).layoutPriority(2)
                Spacer(minLength: FrogStyle.space8)
                HStack(spacing: FrogStyle.space8) { footer(item) }.layoutPriority(1)
            }
            .font(FrogType.small)
            .frame(height: Self.barHeight)
            .padding(.horizontal, FrogStyle.cardPadding)
        }
        .frogRowAccessory()
        .frogTableSurface()
    }

    private static var barHeight: CGFloat { 44 }

    @ViewBuilder private func menuItems(_ item: UtilityDocument) -> some View {
        Button("Rename", systemImage: "pencil") { selected = item.id; startRenaming(item.id) }
        Button("Export…", systemImage: "square.and.arrow.up") { export(item) }
        if item.files.isEmpty { ShareLink(item: item.text) { Label("Share…", systemImage: "square.and.arrow.up.on.square") } }
        Button("Delete", systemImage: "trash", role: .destructive) {
            if item.deletionAsksFirst { deleting = item.id } else { remove(item.id) }
        }
    }

    private func startRenaming(_ id: UUID) {
        // A rename still open on another item keeps what was typed, rather than taking this item's title.
        if renaming != nil, renaming != id { commitRename() }
        draftTitle = all.first { $0.id == id }?.title ?? ""
        renaming = id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        guard let id = renaming else { return }
        renaming = nil
        documents.binding(id, \.title).wrappedValue = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fileRow(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
            Text(url.lastPathComponent).font(FrogType.body).lineLimit(1)
            Spacer()
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }.frame(minHeight: FrogStyle.controlHeight).onDrag { NSItemProvider(object: url as NSURL) }
    }

    private func notice(_ message: String) -> some View {
        HStack(spacing: 8) {
            InlineIssue(message: message)
            if let file = documents.fileToReveal { Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
        }
    }

    private func remove(_ id: UUID) {
        documents.remove(id)
        if selected == id { selected = all.first?.id }
    }

    private func provider(_ item: UtilityDocument) -> NSItemProvider {
        if let url = item.files.first { return NSItemProvider(object: url as NSURL) }
        return NSItemProvider(object: item.text as NSString)
    }

    private func export(_ item: UtilityDocument) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.shownTitle + (kind == .note ? ".md" : ".sh")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try item.text.write(to: url, atomically: true, encoding: .utf8) }
        catch { NSAlert(error: error).runModal() }
    }
}

/// A note's first line as the list previews it: the words without their Markdown, so "# Standup" reads "Standup"
/// and "- [ ] **Call** [Anna](…)" reads "Call Anna".
extension MarkdownPreview {
    static func plain(_ line: String) -> String {
        var text = line
        // Block marks at the start: headings, quotes, list bullets, numbers and task boxes.
        for pattern in [#"^#{1,6}\s+"#, #"^(>\s*)+"#, #"^[-*+]\s+(\[[ xX]\]\s+)?"#, #"^\d+[.)]\s+(\[[ xX]\]\s+)?"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        // Links and images keep their text; emphasis and code lose their marks.
        text = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for pattern in [#"(\*\*|__)(.+?)\1"#, #"(?<!\w)(\*|_)(.+?)\1(?!\w)"#, #"(~~)(.+?)\1"#, #"(`)(.+?)\1"#] {
            text = text.replacingOccurrences(of: pattern, with: "$2", options: .regularExpression)
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? line : trimmed
    }
}

extension LocalDocuments {
    /// A field of one item that saves as it is edited.
    func binding<Value>(_ id: UUID, _ key: WritableKeyPath<UtilityDocument, Value>) -> Binding<Value> where Value: Equatable {
        Binding(get: { [unowned self] in
            // The item is gone only while its page is closing.
            (self.items.first { $0.id == id } ?? UtilityDocument(kind: .note, title: ""))[keyPath: key]
        }, set: { [unowned self] value in
            guard var item = self.items.first(where: { $0.id == id }), item[keyPath: key] != value else { return }
            item[keyPath: key] = value
            self.update(item)
        })
    }
}

/// A borderless text area inside the item's card, as both editors use it. Its text starts on the card's content
/// edge, under the toolbar's first control: the text view keeps a line fragment padding of 5 points, which the
/// negative inset takes back.
struct DocumentTextEditor: View {
    @Binding var text: String
    var font: Font = FrogType.lead
    var body: some View {
        TextEditor(text: $text).font(font).scrollContentBackground(.hidden).lineSpacing(3)
            .padding(.horizontal, -5)
    }
}

/// When an item was last changed, for its card's footer: "Edited just now", "Edited 12 min ago", "Edited 18:07",
/// "Edited yesterday".
struct DocumentEditedText: View {
    let date: Date
    var body: some View {
        TimelineView(.everyMinute) { _ in
            let when = RecentTimestamp.text(date)
            let lowered = [L10n.text("Just now"): L10n.text("just now"), L10n.text("Yesterday"): L10n.text("yesterday")]
            Text(L10n.text("Edited") + " " + (lowered[when] ?? when)).lineLimit(1).help(RecentTimestamp.full(date))
        }
    }
}
