import FrogCore
import os
import SwiftUI

/// `[scripts]` in config.toml.
struct ScriptsSettings: ConfigSection {
    /// Seconds a script may run before Frog stops it, 1 to 600.
    var timeout = 60

    static let comments = ["timeout": "Seconds a script may run before Frog stops it (1 to 600)."]
    static let timeouts = [10, 30, 60, 120, 300, 600]
    var limit: TimeInterval { TimeInterval(min(600, max(1, timeout))) }
}

/// Shell scripts run with zsh in the home folder. Shares its store with Notes; the runner is shared with quitting,
/// which waits for a running script to stop.
final class ScriptsPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "scripts", name: "Scripts", symbol: "terminal", tint: .gray, category: .navigate,
                                 summary: "Run your shell scripts")

    private var documents: LocalDocuments { model.documents }
    private var runner: ScriptRunner { model.scripts }
    private(set) lazy var settings = context.settings(ScriptsSettings.self)

    func start() async {
        runner.onSuccessfulRun = { [weak model] in model?.statistics.recordToolUse(.scriptRun) }
    }

    func stop() async {
        runner.stop()
        runner.onSuccessfulRun = nil
    }

    func settingsChanged() { settings = context.settings(ScriptsSettings.self) }

    func page() -> AnyView? {
        AnyView(ScriptsPage(documents: documents, runner: runner, timeout: settings.timeout,
                            run: { [weak self] in self?.runOnPage($0) },
                            setTimeout: { [weak self] in self?.setTimeout($0) }))
    }

    /// Shows the script on the Scripts page and runs it there.
    func runOnPage(_ script: UtilityDocument) {
        guard documents.items.contains(where: { $0.id == script.id }) else { return }
        documents.selection[.script] = script.id
        context.openPage()
        runner.run(script, timeout: settings.limit)
    }

    private func setTimeout(_ seconds: Int) {
        var changed = settings
        changed.timeout = seconds
        do { try context.save(changed); settings = changed } catch { context.report(error) }
    }

    var actions: [PluginAction] {
        let title = ActionParameter(name: "title", required: true, help: "The script's title; its start is enough when only one script begins with it")
        return [
            PluginAction(id: "scripts.new", title: "New script", symbol: "plus.rectangle.on.rectangle", keywords: "shell zsh script") { [weak self] _ in
                guard let self else { throw CancellationError() }
                try await documents.loadForAction()
                try documents.checkRoom()
                let script = UtilityDocument(kind: .script, title: UtilityDocument.Kind.script.newItemTitle)
                documents.add(script)
                documents.selection[.script] = script.id
                context.openPage()
                return .done("Opened a new script.")
            },
            PluginAction(id: "scripts.list", title: "List scripts", symbol: "list.bullet", surfaces: .agent) { [weak self] _ in
                guard let self else { throw CancellationError() }
                try await documents.loadForAction()
                let scripts = documents.items(.script)
                let rows = scripts.map { [$0.shownTitle, Self.preview($0.text)] }
                return ActionResult(scripts.map { Entry($0) }, text: scripts.isEmpty ? "No scripts yet." : AgentTable.render(rows))
            },
            PluginAction(id: "scripts.read", title: "Read a script", symbol: "doc.text", parameters: [title], surfaces: .agent) { [weak self] input in
                guard let self else { throw CancellationError() }
                try await documents.loadForAction()
                let script = try documents.item(.script, titled: try input.required("title"))
                return ActionResult(Entry(script, text: true), text: script.text)
            },
            PluginAction(id: "scripts.run", title: "Run a script", symbol: "play",
                         parameters: [title, ActionParameter(name: "timeout", kind: .integer, help: "Seconds before it is stopped, 1 to 600; [scripts] timeout by default")],
                         surfaces: [.shortcut, .agent]) { [weak self] input in
                guard let self else { throw CancellationError() }
                try await documents.loadForAction()
                let script = try documents.item(.script, titled: try input.required("title"))
                // A shortcut runs it where its output shows; an agent reads the output it prints.
                if input.source != .agent {
                    runOnPage(script)
                    return .done("Running “\(script.shownTitle)”.")
                }
                return try await runForAgent(script, timeout: try input.integer("timeout"))
            },
            PluginAction(id: "scripts.stop", title: "Stop the script", symbol: "stop", keywords: "script cancel") { [weak self] _ in
                guard let self else { throw CancellationError() }
                guard runner.running != nil else { return .done("No script is running.") }
                runner.stop()
                return .done("Stopped the script.")
            },
        ]
    }

    private func runForAgent(_ script: UtilityDocument, timeout: Int?) async throws -> ActionResult {
        if let timeout, !(1...600).contains(timeout) { throw ActionError.invalid("timeout", "seconds from 1 to 600") }
        let limit = timeout.map(TimeInterval.init) ?? settings.limit
        let printed = OSAllocatedUnfairLock(initialState: "")
        let result: ScriptResult
        do {
            result = try await runner.runForAgent(script.text, timeout: limit) { text in printed.withLock { $0 = text } }
        } catch {
            // What it printed before it ran out of time is still worth showing.
            let output = printed.withLock { $0 }
            throw ActionError.failed([output, error.localizedDescription].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        let notice = result.truncated ? "\nIts output was cut off at 256 KB." : ""
        guard result.status == 0 else {
            throw ActionError.failed(result.output + (result.output.hasSuffix("\n") || result.output.isEmpty ? "" : "\n")
                                     + "“\(script.shownTitle)” exited with status \(result.status).\(notice)")
        }
        model.statistics.recordToolUse(.scriptRun)
        return ActionResult(Run(title: script.shownTitle, status: result.status, output: result.output, truncated: result.truncated),
                            text: result.output + notice)
    }

    private static func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    struct Entry: Encodable {
        let id: UUID
        let title: String
        let modified: Date
        var text: String?
        init(_ script: UtilityDocument, text: Bool = false) {
            id = script.id; title = script.title; modified = script.modified
            self.text = text ? script.text : nil
        }
    }

    struct Run: Encodable {
        let title: String
        let status: Int32
        let output: String
        let truncated: Bool
    }
}

/// The Scripts page: the list, the chosen script, its last output, and the time limit.
struct ScriptsPage: View {
    @ObservedObject var documents: LocalDocuments
    @ObservedObject var runner: ScriptRunner
    let run: (UtilityDocument) -> Void
    let setTimeout: (Int) -> Void
    @State private var timeout: Int

    init(documents: LocalDocuments, runner: ScriptRunner, timeout: Int, run: @escaping (UtilityDocument) -> Void, setTimeout: @escaping (Int) -> Void) {
        self.documents = documents; self.runner = runner; self.run = run; self.setTimeout = setTimeout
        _timeout = State(initialValue: timeout)
    }

    var body: some View {
        DocumentsPage(documents: documents, kind: .script, title: "Scripts", symbol: "terminal",
                      emptyMessage: "Each runs with zsh in your home folder, from here, the command bar or a shortcut.") { script in
            if runner.running == script.id {
                Button("Stop", systemImage: "stop.fill", action: runner.stop)
            } else {
                Button("Run", systemImage: "play.fill") { run(script) }
                    .buttonStyle(.frog(.primary, compact: true)).disabled(runner.running != nil)
                    .help(runner.running != nil ? "Another script is running" : "")
            }
        } content: { script in
            DocumentTextEditor(text: documents.binding(script.id, \.text), font: FrogType.mono)
            if runner.resultID == script.id { output }
        } footer: {
            FrogSection {
                FrogRow("Time limit", caption: "Frog stops a script that runs longer.") {
                    FrogDropdown(selected: timeout, options: ScriptsSettings.timeouts.contains(timeout) ? ScriptsSettings.timeouts : (ScriptsSettings.timeouts + [timeout]).sorted(),
                                 width: 120, title: Self.duration) { timeout = $0; setTimeout($0) }
                }
            }
        }
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(runner.status).font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
                Spacer()
                if !runner.output.isEmpty { CopyAction(title: "Copy output", labeled: true) { ViewActions.copy(runner.output) } }
            }
            if !runner.output.isEmpty {
                ScrollView {
                    Text(runner.output).font(FrogType.mono).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.frame(height: 150).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
            }
        }
    }

    static func duration(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) seconds" : seconds == 60 ? "1 minute" : seconds % 60 == 0 ? "\(seconds / 60) minutes" : "\(seconds) seconds"
    }
}
