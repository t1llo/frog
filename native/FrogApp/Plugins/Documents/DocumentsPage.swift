import AppKit
import FrogCore
import SwiftUI

/// The page Notes and Scripts share: search and New in the header, the list beside the chosen item. Each plugin
/// adds its own controls above the item and its own body below them.
struct DocumentsPage<Controls: View, Content: View, Footer: View>: View {
    @ObservedObject var documents: LocalDocuments
    let kind: UtilityDocument.Kind
    let title: String
    let symbol: String
    let emptyMessage: String
    @ViewBuilder let controls: (UtilityDocument) -> Controls
    @ViewBuilder let content: (UtilityDocument) -> Content
    @ViewBuilder let footer: () -> Footer

    @State private var search = ""
    @State private var deleting: UUID?
    private static var height: CGFloat { 540 }

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

    var body: some View {
        FrogPage(width: FrogStyle.wideWidth) {
            FrogPageHeader(title: title) {
                if !all.isEmpty { SearchBox(placeholder: "Search", text: $search).frame(width: 200) }
                Button("New", systemImage: "plus") {
                    search = ""
                    selected = documents.add(UtilityDocument(kind: kind, title: kind.newItemTitle))
                }.buttonStyle(.frog(.primary)).disabled(!documents.loaded)
            }
            if let issue = documents.issue { notice(issue) }
            if let unreadable = documents.unreadable { notice(unreadable.message) }
            if documents.loaded, all.isEmpty {
                FrogEmptyState(symbol: symbol, title: "No \(title.lowercased()) yet", message: emptyMessage).frogTableSurface()
            } else if documents.loaded {
                HStack(alignment: .top, spacing: 16) {
                    list.frame(width: 210, height: Self.height)
                    Group {
                        if let current { editor(current) }
                        else { FrogEmptyState(symbol: symbol, title: shown.isEmpty ? "Nothing matches" : "Choose one", message: "") }
                    }.frame(maxWidth: .infinity).frame(height: Self.height, alignment: .top)
                }
            }
            footer()
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
            LazyVStack(spacing: 2) {
                ForEach(shown) { item in
                    Button { selected = item.id } label: {
                        HStack(spacing: 6) {
                            Text(item.shownTitle).font(item.id == selected ? FrogType.bodyMedium : FrogType.body)
                                .foregroundStyle(FrogStyle.ink).lineLimit(1)
                            Spacer(minLength: 0)
                            if item.pastes {
                                Image(systemName: "text.badge.plus").font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                                    .help("Pastes from the command bar")
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: FrogStyle.controlHeight, alignment: .leading)
                        .contentShape(Rectangle())
                        .frogHoverRow(selected: item.id == selected)
                    }.buttonStyle(.plain).onDrag { provider(item) }
                }
            }.padding(6)
        }.frogTableSurface()
    }

    private func editor(_ item: UtilityDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(L10n.text("Title"), text: binding(item, \.title)).textFieldStyle(.plain).font(FrogType.section)
                controls(item)
                IconMenu(title: "More") {
                    Button("Export…", systemImage: "square.and.arrow.up") { export(item) }
                    if item.files.isEmpty { ShareLink(item: item.text) { Label("Share…", systemImage: "square.and.arrow.up.on.square") } }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        if item.deletionAsksFirst { deleting = item.id } else { remove(item.id) }
                    }
                }
            }.frame(height: FrogStyle.controlHeight)
            ForEach(item.files, id: \.self) { url in fileRow(url) }
            content(item)
        }.buttonStyle(.frog(compact: true))
    }

    private func fileRow(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
            Text(url.lastPathComponent).font(FrogType.body).lineLimit(1)
            Spacer()
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }.onDrag { NSItemProvider(object: url as NSURL) }
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

    private func binding(_ item: UtilityDocument, _ key: WritableKeyPath<UtilityDocument, String>) -> Binding<String> {
        documents.binding(item.id, key)
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

extension DocumentsPage where Footer == EmptyView {
    init(documents: LocalDocuments, kind: UtilityDocument.Kind, title: String, symbol: String, emptyMessage: String,
         @ViewBuilder controls: @escaping (UtilityDocument) -> Controls, @ViewBuilder content: @escaping (UtilityDocument) -> Content) {
        self.init(documents: documents, kind: kind, title: title, symbol: symbol, emptyMessage: emptyMessage,
                  controls: controls, content: content, footer: { EmptyView() })
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

/// A text area on the inset fill, as both editors use it.
struct DocumentTextEditor: View {
    @Binding var text: String
    var font: Font = FrogType.lead
    var body: some View {
        TextEditor(text: $text).font(font).scrollContentBackground(.hidden)
            .padding(8).frogControlSurface(height: nil)
    }
}
