import AppKit
import SwiftUI
import UniformTypeIdentifiers
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
    @State private var dropTask: Task<Void, Never>?
    private var title: String { switch kind { case .note: "Notes"; case .snippet: "Snippets"; case .shelf: "Shelf"; case .script: "Scripts" } }
    private var subtitle: String {
        switch kind {
        case .note: "A private space for notes on this Mac."
        case .snippet: "Reusable text, ready to copy."
        case .shelf: "Keep files, links and text close."
        case .script: "Your local scripts and their output."
        }
    }
    private var items: [UtilityDocument] { documents.items.filter { $0.kind == kind && (search.isEmpty || ($0.title + " " + $0.text).localizedStandardContains(search)) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: title, subtitle: subtitle) {
                if kind == .shelf { Button("Paste", systemImage: "clipboard") { pasteToShelf() }.disabled(!documents.loaded) }
                Button("New", systemImage: "plus") {
                    selected = documents.add(UtilityDocument(kind: kind, title: kind == .note ? "Untitled note" : kind == .snippet ? "New snippet" : kind == .script ? "New script" : "Shelf item"))
                }.disabled(!documents.loaded)
            }
            ListToolbar(placeholder: "Search \(title.lowercased())", search: $search) {
                Text("\(items.count) \(items.count == 1 ? "item" : "items")")
                    .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
            }
            if let issue = documents.issue { InlineIssue(message: issue) }
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 8) {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(items) { item in
                                Button { selected = item.id } label: {
                                    Text(item.title.isEmpty ? "Untitled" : item.title).font(.system(size: 12)).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                                        .background(item.id == selected ? FrogStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain).onDrag { provider(item) }
                            }
                        }
                    }
                }.frame(width: 154)
                Divider()
                if let item = documents.items.first(where: { $0.id == selected && $0.kind == kind }) {
                    editor(item)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: kind == .shelf ? "tray" : "note.text").font(.system(size: 28))
                        Text(items.isEmpty ? "Create your first item" : "Select an item")
                    }.foregroundStyle(FrogStyle.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.padding(20).frame(maxWidth: 1080).frame(maxWidth: .infinity, alignment: .top)
            .buttonStyle(FrogButtonStyle())
            .task { await documents.load(); if selected == nil { selected = items.first?.id } }
            .onDrop(of: [.fileURL, .url, .utf8PlainText], isTargeted: nil) { providers in
                guard kind == .shelf, documents.loaded else { return false }
                dropTask?.cancel()
                dropTask = Task {
                    for provider in providers.prefix(100) {
                        let item = await ShelfDrop.document(from: provider)
                        guard !Task.isCancelled, model.configuration.preferences.featureEnabled(.shelf) else { return }
                        if let item { selected = documents.add(item) }
                    }
                }
                return true
            }
            .onDisappear { dropTask?.cancel(); dropTask = nil }
    }
    private func editor(_ item: UtilityDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: binding(item, \.title)).textFieldStyle(.plain).font(.system(size: 17, weight: .medium))
            HStack {
                Button("Copy", systemImage: "doc.on.doc") { copy(item) }
                if kind == .note {
                    CompactSegments(values: [false, true], selected: preview, title: { $0 ? "Preview" : "Edit" }) { preview = $0 }
                }
                Spacer()
                Menu {
                    Button("Export…", systemImage: "square.and.arrow.up") { export(item) }
                    if item.files.isEmpty { ShareLink(item: item.text) { Label("Share text…", systemImage: "square.and.arrow.up.on.square") } }
                    Divider()
                    Button("Delete item", systemImage: "trash", role: .destructive) { documents.remove(item.id); selected = nil }
                } label: { Image(systemName: "ellipsis").frame(width: 26).modifier(CompactActionSurface()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Item actions")
            }.controlSize(.small)
            if kind == .snippet { Text("Variables: {{date}}, {{time}}, {{clipboard}}").font(.system(size: 10)).foregroundStyle(FrogStyle.muted) }
            if !item.files.isEmpty {
                ForEach(item.files, id: \.self) { url in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24)
                        Text(url.lastPathComponent).lineLimit(1); Spacer()
                        Button("Open") { NSWorkspace.shared.open(url) }
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.help("Share file")
                    }.onDrag { NSItemProvider(object: url as NSURL) }
                }
            }
            if kind == .script { ScriptOutputView(runner: model.scripts, documentID: item.id, run: { model.runScript(item) }) }
            if preview && kind == .note {
                ScrollView { Text(.init(item.text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
            } else {
                TextEditor(text: binding(item, \.text)).font(.system(size: 13)).scrollContentBackground(.hidden)
                    .padding(8).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 6))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func binding(_ item: UtilityDocument, _ key: WritableKeyPath<UtilityDocument, String>) -> Binding<String> {
        Binding(get: { documents.items.first { $0.id == item.id }?[keyPath: key] ?? "" }, set: { text in
            guard var current = documents.items.first(where: { $0.id == item.id }) else { return }
            current[keyPath: key] = text; documents.update(current)
        })
    }
    private func provider(_ item: UtilityDocument) -> NSItemProvider {
        if let url = item.files.first { return NSItemProvider(object: url as NSURL) }
        return NSItemProvider(object: item.text as NSString)
    }
    private func copy(_ item: UtilityDocument) {
        let board = model.clipboardHistoryStore.pasteboard
        if !item.files.isEmpty { board.clearContents(); board.writeObjects(item.files as [NSURL]); return }
        let text = kind == .snippet ? SnippetExpansion.expand(item.text, clipboard: board.string(forType: .string) ?? "") : item.text
        let sensitive = kind == .snippet && item.text.contains("{{clipboard}}") && board.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true
        guard ClipboardHistoryEntry(text: text, isSensitive: sensitive).write(to: board, plainText: true) else {
            model.report(FrogError.message("Could not copy the item.")); return
        }
        if kind == .snippet { model.statistics.recordToolUse(.snippetCopy) }
    }
    private func export(_ item: UtilityDocument) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = (item.title.isEmpty ? "Untitled" : item.title) + (kind == .note ? ".md" : kind == .script ? ".sh" : ".txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try item.text.write(to: url, atomically: true, encoding: .utf8) }
        catch { let alert = NSAlert(error: error); alert.runModal() }
    }
    private func pasteToShelf() {
        let board = model.clipboardHistoryStore.pasteboard
        if let urls = board.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            for url in urls.prefix(100) { selected = documents.add(ShelfDrop.document(url: url)) }
        } else if let text = board.string(forType: .string), let item = ShelfDrop.document(text: text) { selected = documents.add(item) }
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
                Button("Run", systemImage: "play.fill", action: run).disabled(runner.running != nil)
                if runner.running != nil { Button("Stop", systemImage: "stop.fill", action: runner.stop) }
                Text(showsResult ? runner.status : runner.running != nil ? "Another script is running…" : "").font(.caption).foregroundStyle(FrogStyle.muted).lineLimit(2)
                Spacer()
                if showsResult, !runner.output.isEmpty { Button("Copy output") { ViewActions.copy(runner.output) } }
            }.controlSize(.small)
            Text("Runs with zsh in your home folder, up to 60 seconds. Output stays in memory.").font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
            if showsResult, !runner.output.isEmpty {
                ScrollView { Text(runner.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 120)
            }
        }.buttonStyle(FrogButtonStyle())
    }
}

enum ShelfDrop {
    static func document(url: URL) -> UtilityDocument {
        UtilityDocument(kind: .shelf, title: url.lastPathComponent.isEmpty ? url.host ?? url.absoluteString : url.lastPathComponent,
                        text: url.isFileURL ? "" : url.absoluteString, files: url.isFileURL ? [url] : [])
    }
    static func document(text: String) -> UtilityDocument? {
        guard !text.isEmpty, text.utf8.count <= 1_000_000 else { return nil }
        return UtilityDocument(kind: .shelf, title: String(text.prefix(60)).replacingOccurrences(of: "\n", with: " "), text: text)
    }
    static func document(from provider: NSItemProvider) async -> UtilityDocument? {
        if provider.canLoadObject(ofClass: NSURL.self) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: NSURL.self) { value, _ in continuation.resume(returning: value as? URL) }
            }
            if let url { return document(url: url) }
        }
        if provider.canLoadObject(ofClass: NSString.self) {
            let text: String? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: NSString.self) { value, _ in continuation.resume(returning: value as? String) }
            }
            if let text { return document(text: text) }
        }
        return nil
    }
}

struct QuickActionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var input = ""
    @State private var result = ""
    var body: some View {
        PageScroll {
            PageHeader(title: "Quick actions", subtitle: "Useful controls and local text tools.")
            HStack {
                Button("Switch appearance", systemImage: "circle.lefthalf.filled") {
                    var prefs = model.configuration.preferences
                    var appearance = prefs.appearance ?? AppearancePreferences()
                    appearance.mode = appearance.mode == .dark ? .light : .dark; prefs.appearance = appearance
                    do { try model.savePreferences(prefs) } catch { model.report(error) }
                }
                Button("Lock screen", systemImage: "lock") {
                    let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? ProcessInfo.processInfo.processIdentifier
                    Task { do { try await SystemActionController.shared.perform(.lockScreen, pid: pid) } catch { model.report(error) } }
                }
            }
            SettingsSection(title: "Text tools") {
                TextEditor(text: $input).frame(minHeight: 110).scrollContentBackground(.hidden).padding(8).background(FrogStyle.inset)
                HStack {
                    Button("Clean URL") { result = LinkCleaning.clean(input) ?? "Enter an HTTP or HTTPS URL." }
                    Button("Base64 encode") { result = Data(input.utf8).base64EncodedString() }
                    Button("Base64 decode") { result = Data(base64Encoded: input).flatMap { String(data: $0, encoding: .utf8) } ?? "Not valid UTF-8 Base64." }
                    Button("Generate UUID") { result = UUID().uuidString }
                }.controlSize(.small)
                if !result.isEmpty {
                    Text(result).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Copy result") { ViewActions.copy(result) }
                }
            }
        }.buttonStyle(FrogButtonStyle())
    }
}
