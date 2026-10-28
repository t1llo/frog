import AppKit
import SwiftUI
import FrogCore

struct UtilityDocumentsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var documents: LocalDocuments
    let kind: UtilityDocument.Kind
    private var selected: UUID? {
        get { documents.selection[kind] }
        nonmutating set { documents.selection[kind] = newValue }
    }
    @State private var preview = false
    @State private var search = ""
    @State private var deleting: UUID?
    private var title: String { switch kind { case .note: "Notes"; case .script: "Scripts" } }
    private var deleteQuestion: String { switch kind { case .note: "Delete this note?"; case .script: "Delete this script?" } }
    private var items: [UtilityDocument] { documents.items.filter { $0.kind == kind && (search.isEmpty || ($0.title + " " + $0.text).localizedStandardContains(search)) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: title) {
                Button("New", systemImage: "plus") {
                    selected = documents.add(UtilityDocument(kind: kind, title: kind.newItemTitle))
                }.disabled(!documents.loaded)
            }
            ListToolbar(placeholder: "Search \(title.lowercased())", search: $search) {
                Text("\(items.count) \(items.count == 1 ? "item" : "items")")
                    .font(FrogType.caption).foregroundStyle(FrogStyle.muted)
            }
            if let issue = documents.issue { notice(issue) }
            if let unreadable = documents.unreadable { notice(unreadable.message) }
            // The list and the editor are set apart by space alone.
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 8) {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(items) { item in
                                Button { selected = item.id } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(item.title.isEmpty ? "Untitled" : item.title)
                                            .font(item.id == selected ? FrogType.bodyMedium : FrogType.body).lineLimit(2)
                                        Spacer(minLength: 0)
                                        if item.pastes {
                                            Image(systemName: "text.badge.plus").font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                                                .help("Pastes from the command bar")
                                        }
                                    }.padding(.horizontal, 9).padding(.vertical, 6)
                                        .frame(maxWidth: .infinity, minHeight: FrogStyle.controlHeight, alignment: .leading)
                                        .frogHoverRow(selected: item.id == selected)
                                }.buttonStyle(.plain).onDrag { provider(item) }
                            }
                        }
                    }
                }.frame(width: 154)
                if let item = documents.items.first(where: { $0.id == selected && $0.kind == kind }) {
                    editor(item)
                } else {
                    VStack(spacing: 10) {
                        SymbolTile(symbol: kind == .script ? "terminal" : "note.text", size: 32)
                        Text(items.isEmpty ? "Create your first item" : "Select an item").font(FrogType.lead)
                    }.foregroundStyle(FrogStyle.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.padding(20).frame(maxWidth: 1080).frame(maxWidth: .infinity, alignment: .top)
            .buttonStyle(FrogButtonStyle())
            .task { await documents.load(); if selected == nil { selected = items.first?.id } }
            .confirmationDialog(L10n.text(deleteQuestion), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let deleting { remove(deleting) }
                    deleting = nil
                }
            } message: {
                Text(documents.items.first { $0.id == deleting }?.files.isEmpty == false
                    ? "It will be permanently deleted from this Mac. Files it holds stay where they are."
                    : "It will be permanently deleted from this Mac.")
            }
    }
    private func remove(_ id: UUID) {
        documents.remove(id)
        if selected == id { selected = nil }
    }
    private func notice(_ message: String) -> some View {
        HStack(spacing: 8) {
            InlineIssue(message: message)
            if let file = documents.fileToReveal { Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
        }
    }
    private func editor(_ item: UtilityDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: binding(item, \.title)).textFieldStyle(.plain).font(FrogType.title)
            HStack {
                CopyAction(labeled: true) { copy(item) }.buttonStyle(.frog(compact: true))
                if kind == .note {
                    CompactSegments(values: [false, true], selected: preview, width: 160, compact: true, title: { $0 ? "Preview" : "Edit" }) { preview = $0 }
                }
                Spacer()
                if kind == .note {
                    Toggle("Paste from command bar", isOn: pastesBinding(item)).toggleStyle(.switch).controlSize(.mini)
                        .font(FrogType.small).foregroundStyle(FrogStyle.muted)
                        .help("Choosing the note in the command bar pastes its text instead of opening it")
                }
                Menu {
                    Button("Export…", systemImage: "square.and.arrow.up") { export(item) }
                    if item.files.isEmpty { ShareLink(item: item.text) { Label("Share text…", systemImage: "square.and.arrow.up.on.square") } }
                    Button("Delete item", systemImage: "trash", role: .destructive) {
                        if item.deletionAsksFirst { deleting = item.id } else { remove(item.id) }
                    }
                } label: { Image(systemName: "ellipsis").font(FrogType.label).frame(width: FrogStyle.compactHeight).modifier(CompactActionSurface()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Item actions")
            }.controlSize(.small)
            if item.pastes { Text("Variables: {{date}}, {{time}}, {{clipboard}}").font(FrogType.caption).foregroundStyle(FrogStyle.muted) }
            if !item.files.isEmpty {
                ForEach(item.files, id: \.self) { url in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24)
                        Text(url.lastPathComponent).font(FrogType.body).lineLimit(1); Spacer()
                        Button("Open") { NSWorkspace.shared.open(url) }
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.help("Share file")
                    }.buttonStyle(.frog(compact: true)).onDrag { NSItemProvider(object: url as NSURL) }
                }
            }
            if kind == .script { ScriptOutputView(runner: model.scripts, documentID: item.id, run: { model.runScript(item) }) }
            if preview && kind == .note {
                MarkdownPreviewView(markdown: item.text).id(item.id)
            } else {
                TextEditor(text: binding(item, \.text)).font(FrogType.lead).scrollContentBackground(.hidden)
                    .padding(8).frogControlSurface(height: nil)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func binding(_ item: UtilityDocument, _ key: WritableKeyPath<UtilityDocument, String>) -> Binding<String> {
        Binding(get: { documents.items.first { $0.id == item.id }?[keyPath: key] ?? "" }, set: { text in
            guard var current = documents.items.first(where: { $0.id == item.id }) else { return }
            current[keyPath: key] = text; documents.update(current)
        })
    }
    private func pastesBinding(_ item: UtilityDocument) -> Binding<Bool> {
        Binding(get: { documents.items.first { $0.id == item.id }?.pastes ?? false }, set: { pastes in
            guard var current = documents.items.first(where: { $0.id == item.id }) else { return }
            current.pastes = pastes; documents.update(current)
        })
    }
    private func provider(_ item: UtilityDocument) -> NSItemProvider {
        if let url = item.files.first { return NSItemProvider(object: url as NSURL) }
        return NSItemProvider(object: item.text as NSString)
    }
    private func copy(_ item: UtilityDocument) {
        let board = model.clipboardHistoryStore.pasteboard
        if !item.files.isEmpty { board.clearContents(); board.writeObjects(item.files as [NSURL]); return }
        let text = item.pastes ? SnippetExpansion.expand(item.text, clipboard: board.string(forType: .string) ?? "") : item.text
        let sensitive = item.pastes && item.text.contains("{{clipboard}}") && board.holdsSensitiveText
        guard ClipboardHistoryEntry(text: text, isSensitive: sensitive).write(to: board, plainText: true) else {
            model.report(FrogError.message("Could not copy the item.")); return
        }
        if item.pastes { model.statistics.recordToolUse(.snippetCopy) }
    }
    private func export(_ item: UtilityDocument) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = (item.title.isEmpty ? "Untitled" : item.title) + (kind == .note ? ".md" : kind == .script ? ".sh" : ".txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try item.text.write(to: url, atomically: true, encoding: .utf8) }
        catch { let alert = NSAlert(error: error); alert.runModal() }
    }
}

extension UtilityDocument.Kind {
    /// The title of an item that New creates.
    var newItemTitle: String {
        switch self { case .note: "Untitled note"; case .script: "New script" }
    }
}

extension UtilityDocument {
    /// A deleted item cannot be brought back, so Frog asks before it deletes one that holds
    /// something, a title of its own included. An item that was only just created is removed
    /// without a question.
    var deletionAsksFirst: Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !files.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(title.isEmpty || title == kind.newItemTitle)
    }
}

struct ScriptOutputView: View {
    @ObservedObject var runner: ScriptRunner
    let documentID: UUID
    let run: () -> Void
    private var showsResult: Bool { runner.resultID == documentID }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Run", systemImage: "play.fill", action: run).buttonStyle(.frog(.primary, compact: true)).disabled(runner.running != nil)
                if runner.running != nil { Button("Stop", systemImage: "stop.fill", action: runner.stop) }
                Text(showsResult ? runner.status : runner.running != nil ? "Another script is running…" : "").font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(2)
                Spacer()
                if showsResult, !runner.output.isEmpty { CopyAction(title: "Copy output", labeled: true) { ViewActions.copy(runner.output) } }
            }.controlSize(.small)
            Text("Runs with zsh in your home folder, up to 60 seconds. Output stays in memory.").font(FrogType.caption).foregroundStyle(FrogStyle.muted)
            if showsResult, !runner.output.isEmpty {
                ScrollView { Text(runner.output).font(FrogType.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                    .frame(height: 120).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
            }
        }.buttonStyle(.frog(compact: true))
    }
}
