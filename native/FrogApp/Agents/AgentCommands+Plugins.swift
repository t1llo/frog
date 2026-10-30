import AppKit
import FrogCore

/// Plugins: what an AI agent needs to build one with the user, install it for their review, test it and share it.
/// Nothing here approves a plugin; only the user does, in Frog's window.
extension AgentCommands {
    static var plugins: [AgentCommand] {
        [
            AgentCommand(words: ["plugin", "guide"], summary: "How to build a plugin: the manifest, actions, permissions and the frog object.",
                         details: "Read it before building or changing a plugin. It is the reference for the Frog version that is running.") { _ in
                let guide = try pluginGuide()
                return AgentResult(["guide": guide], text: guide)
            },
            AgentCommand(words: ["plugin", "new"], arguments: "<folder> [--name NAME] [--id ID]", summary: "Start a plugin from a template.",
                         details: """
                         Creates the folder with a plugin.json, an index.html styled like Frog and an app.js with one \
                         action. The folder must not exist yet, or be empty. The name defaults to the folder's; the id \
                         defaults to local.<folder>. Give a plugin you will share an id you own, such as \
                         io.github.<user>.<name>: the id never changes between versions, and its storage belongs to it.

                         Example: frog plugin new ~/Plugins/pull-requests --name "Pull requests" --id io.github.jane.pull-requests
                         """, options: ["name", "id"]) { call in
                try newPlugin(call)
            },
            AgentCommand(words: ["plugin", "validate"], arguments: "<folder>", summary: "Check a plugin's manifest and files.",
                         details: "Reads the folder as installing it would, and points out what would not work in Frog.") { call in
                let package = try PluginPackage.read(call.path(try call.argument(0, "folder")))
                let report = PackageReport(package, hints: hints(for: package))
                var lines = [report.summary]
                lines += report.hints.map { "Hint: \($0)" }
                return AgentResult(report, text: lines.joined(separator: "\n"))
            },
            AgentCommand(words: ["plugin", "install"], arguments: "<folder | file.frogplugin | https link | directory id> [--sha256 HASH]",
                         summary: "Install or update a plugin, for the user's review.",
                         details: """
                         A folder installs a copy of it. The first install, and an update that asks for more access, \
                         wait for the user to approve them in Frog's window, which shows the review; an update that asks \
                         for nothing new runs at once and reloads the page. Run it again after every change to the folder.

                         A .frogplugin file, an https link to one (checked against --sha256 when given) or the id of a \
                         plugin in the signed directory opens its review in Frog; nothing is installed until the user \
                         approves it.

                         Exit code 0 means the plugin was installed or its review opened; the answer says which.
                         """, options: ["sha256"], feature: .plugins) { call in
                try await install(call)
            },
            AgentCommand(words: ["plugin", "list"], arguments: "[--directory]", summary: "Installed plugins and their state, or the directory's.",
                         details: "With --directory, the plugins in the signed directory at frog.beffa.xyz/plugins instead.",
                         flags: ["directory"], feature: .plugins) { call in
                let runtime = call.model.plugins
                if call.flag("directory") {
                    await runtime.loadRegistry()
                    if let error = runtime.registryError { throw AgentCommandError.failed(error) }
                    let entries = runtime.registry
                    guard !entries.isEmpty else { return AgentResult(entries, text: "The directory lists no signed plugins.") }
                    return AgentResult(entries, text: AgentTable.render(entries.map { [$0.id, $0.name, $0.version, $0.summary] }))
                }
                runtime.refresh()
                let entries = runtime.items.map { PluginEntry($0, loaded: runtime.loadedHost($0.id) != nil) }
                guard !entries.isEmpty else { return AgentResult(entries, text: "No plugins are installed.") }
                let text = AgentTable.render(entries.map { [$0.state, $0.id, $0.name, $0.version ?? "", $0.source] })
                return AgentResult(entries, text: text)
            },
            AgentCommand(words: ["plugin", "remove"], arguments: "<id>", summary: "Remove a plugin and its storage, to the Trash.",
                         details: "Only when the user asks for it. The folder it was installed from is not touched.", feature: .plugins) { call in
                let item = try installed(call)
                call.model.plugins.remove(item.id)
                guard call.model.plugins.item(item.id) == nil else { throw AgentCommandError.failed("\(item.name) could not be removed. Frog's window says why.") }
                return .done("Removed \(item.name).")
            },
            AgentCommand(words: ["plugin", "publish"], arguments: "<folder | id> [--output FILE]",
                         summary: "Pack a plugin to share and print its directory entry.",
                         details: """
                         Packs a plugin's folder, or the installed copy of a plugin by its id, into <id>-<version>.frogplugin \
                         next to the folder or in the current folder, and prints the entry for the plugin directory at \
                         frog.beffa.xyz/plugins. To list it there, open an issue at \(publishIssues) with the entry and \
                         the file; once the entry is signed, everyone can install it from Frog → Community plugins → Directory.

                         Shared on its own, the file installs from Frog → Community plugins or with \
                         frog://plugins/install?url=<its https URL>&sha256=<its SHA-256>.
                         """, options: ["output"]) { call in
                try publish(call)
            },
            AgentCommand(words: ["plugin", "logs"], arguments: "<id> [--lines N]", summary: "A plugin's console messages and errors.",
                         details: "The page's console.log, errors and rejected promises, and what Frog blocked, since Frog started. The newest come last; --lines takes 1 to 500, 50 by default.",
                         options: ["lines"], feature: .plugins) { call in
                let item = try installed(call)
                let count = try call.integer("lines", default: 50, in: 1...500)
                let lines = (call.model.plugins.logs[item.id] ?? []).suffix(count).map(LogEntry.init)
                guard !lines.isEmpty else { return AgentResult(lines, text: "\(item.name) has logged nothing since Frog started.") }
                return AgentResult(Array(lines), text: lines.map { "\($0.time) \($0.level.padding(toLength: 5, withPad: " ", startingAt: 0)) \($0.text)" }.joined(separator: "\n"))
            },
            AgentCommand(words: ["plugin", "snapshot"], arguments: "<id> [--output FILE]", summary: "Save a picture of a plugin's page.",
                         details: """
                         Loads the page if it is not running and saves a PNG of it, 800 by 600 points unless the page is \
                         open in Frog's window. Look at the picture to check the layout. Without --output it goes to a \
                         temporary folder; the answer gives the path.

                         Example: frog plugin snapshot local.word-counter --output /tmp/word-counter.png
                         """, options: ["output"], feature: .plugins) { call in
                let item = try runnable(call)
                guard item.hasPage else { throw AgentCommandError.failed("\(item.name) has no page; it only has commands.") }
                let png = try await call.model.plugins.snapshot(item.id)
                let file = try snapshotFile(call, id: item.id)
                try png.write(to: file, options: .atomic)
                return AgentResult(["path": file.path], text: file.path)
            },
            AgentCommand(words: ["plugin", "open"], arguments: "<id>", summary: "Show a plugin's page in Frog's window.", feature: .plugins) { call in
                let item = try runnable(call)
                guard item.hasPage else { throw AgentCommandError.failed("\(item.name) has no page; it only has commands.") }
                call.model.openPlugin(item.id)
                NSApp?.activate(ignoringOtherApps: true)
                return .done("Opened \(item.name).")
            }
        ]
    }

    /// Where plugins are submitted to the directory.
    static let publishIssues = "https://github.com/t1llo/frog/issues/new"

    // MARK: Guide and template

    static func pluginGuide() throws -> String {
        guard let url = FrogResources.bundle.url(forResource: "plugin-guide", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw AgentCommandError.failed("The plugin guide is missing from this copy of Frog.")
        }
        return text
    }

    private static func newPlugin(_ call: AgentCall) throws -> AgentResult {
        let folder = call.path(try call.argument(0, "folder"))
        let manager = FileManager.default
        var isFolder: ObjCBool = false
        if manager.fileExists(atPath: folder.path, isDirectory: &isFolder) {
            guard isFolder.boolValue, (try manager.contentsOfDirectory(atPath: folder.path)).allSatisfy({ $0.hasPrefix(".") }) else {
                throw AgentCommandError.failed("\(folder.path) already exists. Choose a new folder, or work on the plugin that is there.")
            }
        }
        let slug = folder.lastPathComponent.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let name = (call.option("name") ?? folder.lastPathComponent.replacingOccurrences(of: "-", with: " ").capitalized(with: nil))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let id = call.option("id") ?? "local.\(slug.isEmpty ? "plugin" : slug)"
        guard PluginManifest.isValidID(id) else {
            throw AgentCommandError.usage("“\(id)” is not a plugin id: use 3 to 64 lowercase letters, digits, dots and hyphens, such as io.github.jane.\(slug.isEmpty ? "plugin" : slug).")
        }
        guard (1...40).contains(name.count), !name.contains(where: \.isNewline) else { throw AgentCommandError.usage("Give the plugin a name of 1 to 40 characters with --name.") }

        let manifest: [String: Any] = [
            "id": id, "name": name, "version": "1.0.0", "description": "What \(name) does, in one sentence.",
            "symbol": "puzzlepiece.extension", "frog": PluginVersion(AppVersion.current) != nil ? AppVersion.current : "1.0.40",
            "permissions": [String](),
            "actions": [["id": "count", "title": "Count \(name)", "effect": "write"]]
        ]
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let escaped = name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let files: [(String, Data)] = [
            ("plugin.json", json + Data("\n".utf8)),
            ("index.html", Data(PluginTemplate.page(name: escaped).utf8)),
            ("app.js", Data(PluginTemplate.script.utf8))
        ]
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, data) in files { try data.write(to: folder.appendingPathComponent(path), options: .withoutOverwriting) }
        let package = try PluginPackage.read(folder)
        let text = """
        Started \(name) (\(id)) in \(folder.path).
        Next: edit its files, run `frog plugin validate \(folder.path)`, then `frog plugin install \(folder.path)`.
        """
        return AgentResult(PackageReport(package, hints: []), text: text)
    }

    /// What would not work in Frog, though the package reads.
    private static func hints(for package: PluginPackage) -> [String] {
        var hints: [String] = []
        let manifest = package.manifest
        if let needed = manifest.frog, PluginVersion(AppVersion.current) != nil, needed.compare(AppVersion.current, options: .numeric) == .orderedDescending {
            hints.append("It needs Frog \(needed), and this Frog is \(AppVersion.current).")
        }
        if let entry = manifest.entry, let data = try? PluginPackage.readFile(package.root.appendingPathComponent(entry), maximumBytes: 2 * 1024 * 1024) {
            let page = String(decoding: data, as: UTF8.self)
            if !page.contains("/_frog/frog.css") { hints.append("\(entry) does not link /_frog/frog.css, so it will not look like Frog.") }
            if page.range(of: #"(src|href)\s*=\s*["']?(https?:)?//"#, options: .regularExpression) != nil {
                hints.append("\(entry) loads something from the web. Plugins load only their own files: copy it into the folder, or use frog.fetch with the network permission.")
            }
        }
        if manifest.permissions.contains(.network), manifest.hosts.isEmpty { hints.append("It asks for network but lists no hosts, so frog.fetch can reach nothing.") }
        if !manifest.hosts.isEmpty, !manifest.permissions.contains(.network) { hints.append("It lists hosts but does not ask for the network permission.") }
        if !manifest.scripts.isEmpty, !manifest.permissions.contains(.scripts) { hints.append("It lists scripts but does not ask for the scripts permission.") }
        if manifest.entry == nil, manifest.commands.isEmpty { hints.append("It has neither a page nor commands, so nothing can open it.") }
        if !manifest.actions.isEmpty {
            let code = package.files.filter { $0.path.hasSuffix(".js") || $0.path.hasSuffix(".html") }.compactMap {
                try? PluginPackage.readFile(package.root.appendingPathComponent($0.path), maximumBytes: 2 * 1024 * 1024)
            }.map { String(decoding: $0, as: UTF8.self) }
            if !code.contains(where: { $0.contains("frog.action(") }) {
                hints.append("It lists actions, but no file calls frog.action(\"<id>\", handler) to answer them.")
            }
        }
        return hints
    }

    // MARK: Installing

    private static func install(_ call: AgentCall) async throws -> AgentResult {
        let model = call.model
        let runtime = model.plugins
        let given = try call.argument(0, "folder, file, link or id")
        let sha256 = call.option("sha256")
        if let url = URL(string: given), url.scheme?.lowercased() == "https" {
            try await runtime.openLink(url, sha256: sha256)
            return opened(runtime, model: model, fallback: url.lastPathComponent)
        }
        let source = call.path(given)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isFolder) else {
            guard PluginManifest.isValidID(given) else { throw AgentCommandError.failed("Nothing is at \(source.path).") }
            return try await installListed(given, call: call)
        }
        guard isFolder.boolValue else {
            guard source.pathExtension.lowercased() == PluginArchive.fileExtension else {
                throw AgentCommandError.usage("Give a plugin's folder, a .frogplugin file, an https link to one or a directory id.")
            }
            let data = try PluginPackage.readFile(source, maximumBytes: PluginArchive.maximumArchiveBytes)
            if let sha256, PluginPackage.sha256(data) != sha256.lowercased() {
                throw AgentCommandError.failed("\(source.lastPathComponent) is not the file --sha256 names. Nothing was installed.")
            }
            try await runtime.openArchive(data, source: .file(source.path))
            return opened(runtime, model: model, fallback: source.lastPathComponent)
        }
        let item = try runtime.installFolder(source)
        let entry = PluginEntry(item, loaded: runtime.loadedHost(item.id) != nil)
        let text: String
        if item.needsReview {
            try runtime.reviewInstalled(item.id)
            showPlugins(model)
            let first = item.record.approved == nil
            text = """
            Installed \(item.name) \(entry.version ?? "") for review. \(first ? "It is new, so it" : "This version asks for more access, so it") runs once the user approves it in Frog's window, which shows the review now.
            Ask the user to approve it, then check with `frog plugin list`.
            """
        } else if let problem = item.problem {
            throw AgentCommandError.failed(problem)
        } else if !item.record.enabled {
            text = "Installed \(item.name) \(entry.version ?? ""). It is turned off in Frog → Community plugins; ask the user to turn it on."
        } else {
            text = "Installed \(item.name) \(entry.version ?? ""). It runs\(entry.loaded ? ", and its page reloaded" : "")."
        }
        return AgentResult(entry, text: text)
    }

    /// A plugin from the signed directory, always through its review: an agent never installs one on its own.
    private static func installListed(_ id: String, call: AgentCall) async throws -> AgentResult {
        let runtime = call.model.plugins
        await runtime.loadRegistry()
        if let error = runtime.registryError { throw AgentCommandError.failed(error) }
        guard let entry = runtime.registry.first(where: { $0.id == id }) else {
            throw AgentCommandError.failed("The plugin directory lists no “\(id)”. See what it lists with `frog plugin list --directory`.")
        }
        try await runtime.install(entry, oneClick: false)
        return opened(runtime, model: call.model, fallback: entry.name)
    }

    private static func opened(_ runtime: PluginRuntime, model: AppModel, fallback: String) -> AgentResult {
        showPlugins(model)
        let name = runtime.review?.package.manifest.name ?? fallback
        return AgentResult(["state": "review"], text: "Opened the review of \(name) in Frog. Nothing is installed until the user approves it there.")
    }

    private static func showPlugins(_ model: AppModel) {
        model.toolkit.select(.feature(.plugins))
        model.showSettings()
        NSApp?.activate(ignoringOtherApps: true)
    }

    /// The installed plugin the first argument names, by id or name.
    private static func installed(_ call: AgentCall) throws -> PluginItem {
        let runtime = call.model.plugins
        runtime.refresh()
        return try item(named: try call.argument(0, "id"), in: runtime.items, kind: "plugin", list: "frog plugin list",
                        id: { $0.id }, title: { $0.name })
    }

    /// An installed plugin that may run now.
    private static func runnable(_ call: AgentCall) throws -> PluginItem {
        let item = try installed(call)
        if let problem = item.problem { throw AgentCommandError.failed(problem) }
        if item.needsReview { throw AgentCommandError.failed("\(item.name) waits for the user's review in Frog → Community plugins.") }
        if !item.record.enabled { throw AgentCommandError.failed("\(item.name) is turned off in Frog → Community plugins.") }
        return item
    }

    private static func snapshotFile(_ call: AgentCall, id: String) throws -> URL {
        if let output = call.option("output") {
            let file = call.path(output)
            guard file.pathExtension.lowercased() == "png" else { throw AgentCommandError.usage("--output takes a .png file.") }
            return file
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Frog plugin snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(id).png")
    }

    // MARK: Publishing

    private static func publish(_ call: AgentCall) throws -> AgentResult {
        let given = try call.argument(0, "folder or id")
        let path = call.path(given)
        var isFolder: ObjCBool = false
        let package: PluginPackage
        let nextTo: URL
        if FileManager.default.fileExists(atPath: path.path, isDirectory: &isFolder), isFolder.boolValue {
            package = try PluginPackage.read(path)
            nextTo = path.deletingLastPathComponent()
        } else if PluginManifest.isValidID(given), let installed = try? call.model.plugins.store.package(given) {
            package = installed
            nextTo = call.directory ?? FileManager.default.temporaryDirectory
        } else {
            throw AgentCommandError.failed("“\(given)” is neither a plugin's folder nor the id of an installed plugin.")
        }
        let manifest = package.manifest
        let fileName = "\(manifest.id)-\(manifest.version).\(PluginArchive.fileExtension)"
        let file = call.option("output").map(call.path) ?? nextTo.appendingPathComponent(fileName)
        guard file.pathExtension.lowercased() == PluginArchive.fileExtension else {
            throw AgentCommandError.usage("--output takes a .\(PluginArchive.fileExtension) file.")
        }
        let root = package.root.standardizedFileURL.path + "/"
        guard !file.standardizedFileURL.path.hasPrefix(root) else {
            throw AgentCommandError.usage("Write the file outside the plugin's folder; inside it, it would be packed into the next version.")
        }
        let data = try PluginArchive.create(package)
        try data.write(to: file, options: .atomic)
        let entry = DirectoryEntry(manifest, sha256: PluginPackage.sha256(data), fileName: fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let json = try encoder.encode(entry)
        let text = """
        Packed \(manifest.name) \(manifest.version) into \(file.path) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))).
        SHA-256: \(entry.sha256)

        The entry for the plugin directory:
        \(String(decoding: json, as: UTF8.self))

        To list it, open an issue at \(publishIssues) titled “Plugin: \(manifest.name) \(manifest.version)” with this entry \
        and the file attached. The directory checks the file, signs the entry and lists it.
        To share it yourself, host the file over https; the install link is frog://plugins/install?url=<its https URL>&sha256=\(entry.sha256)
        """
        return AgentResult(Published(path: file.path, bytes: data.count, entry: entry), text: text)
    }

    // MARK: Answers

    private struct PackageReport: Encodable {
        let id: String
        let name: String
        let version: String
        let permissions: [String]
        let hosts: [String]
        let scripts: [String]
        let commands: [String]
        let actions: [String]
        let page: String?
        let files: Int
        let bytes: Int
        let hints: [String]

        init(_ package: PluginPackage, hints: [String]) {
            let manifest = package.manifest
            id = manifest.id; name = manifest.name; version = manifest.version
            permissions = manifest.permissions.map(\.rawValue).sorted()
            hosts = manifest.hosts
            scripts = manifest.scripts.keys.sorted()
            commands = manifest.commands.map(\.id)
            actions = manifest.actions.map { "\($0.id) (\($0.effect.rawValue))" }
            page = manifest.entry
            files = package.files.count
            bytes = package.size
            self.hints = hints
        }

        var summary: String {
            AgentTable.render([
                ["Plugin", "\(name) \(version) (\(id))"],
                ["Page", page ?? "none, commands only"],
                ["Commands", commands.isEmpty ? "none" : commands.joined(separator: ", ")],
                ["Actions", actions.isEmpty ? "none" : actions.joined(separator: ", ")],
                ["Permissions", permissions.isEmpty ? "none" : permissions.joined(separator: ", ")],
                ["Hosts", hosts.isEmpty ? "none" : hosts.joined(separator: ", ")],
                ["Files", "\(files), \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"]
            ] + (scripts.isEmpty ? [] : [["Scripts", scripts.joined(separator: ", ")]]))
        }
    }

    private struct PluginEntry: Encodable {
        let id: String
        let name: String
        let version: String?
        /// running, needs-review, off or broken.
        let state: String
        let loaded: Bool
        let source: String
        let permissions: [String]
        let problem: String?

        init(_ item: PluginItem, loaded: Bool) {
            id = item.id; name = item.name; version = item.manifest?.version
            state = item.problem != nil ? "broken" : item.needsReview ? "needs-review" : item.record.enabled ? "on" : "off"
            self.loaded = loaded
            source = item.record.source.label
            permissions = (item.manifest?.permissions ?? []).map(\.rawValue).sorted()
            problem = item.problem
        }
    }

    private struct LogEntry: Encodable {
        let time: String
        let level: String
        let text: String
        init(_ line: PluginLogLine) {
            time = line.date.formatted(date: .omitted, time: .standard)
            level = line.level
            text = line.text
        }
    }

    /// What the website's content/plugins.json lists for a plugin; the website adds the signature.
    struct DirectoryEntry: Encodable {
        let id: String
        let name: String
        let version: String
        let description: String
        var author = ""
        let symbol: String?
        let homepage: String?
        let frog: String?
        let permissions: [String]
        let hosts: [String]
        let actions: [String]
        let download: String
        let sha256: String

        init(_ manifest: PluginManifest, sha256: String, fileName: String) {
            id = manifest.id; name = manifest.name; version = manifest.version
            description = manifest.description
            author = manifest.author ?? ""
            symbol = manifest.symbol; homepage = manifest.homepage; frog = manifest.frog
            permissions = manifest.permissions.map(\.rawValue).sorted()
            hosts = manifest.hosts
            actions = manifest.actions.map { "\($0.id) (\($0.effect.rawValue))" }
            download = "https://frog.beffa.xyz/plugins/files/\(fileName)"
            self.sha256 = sha256
        }
    }

    private struct Published: Encodable {
        let path: String
        let bytes: Int
        let entry: DirectoryEntry
    }
}

/// The files `frog plugin new` starts a plugin with: a page that uses Frog's stylesheet and the `frog` object.
enum PluginTemplate {
    static func page(name: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="color-scheme" content="light dark">
          <title>\(name)</title>
          <link rel="stylesheet" href="/_frog/frog.css">
        </head>
        <body>
          <main class="frog-page">
            <header class="frog-header">
              <div>
                <h1>\(name)</h1>
                <p class="frog-subtitle">What this page is for, in one line.</p>
              </div>
              <button id="add" class="frog-primary">Count</button>
            </header>
            <p id="error" class="frog-error" role="alert" hidden></p>
            <section class="frog-card frog-stack">
              <div class="frog-stat"><strong id="count">0</strong><span>Times counted</span></div>
            </section>
          </main>
          <script src="app.js"></script>
        </body>
        </html>

        """
    }

    static let script = """
    // Runs inside Frog. `frog` is Frog's API; every call returns a promise. See `frog plugin guide`.
    const $ = (id) => document.getElementById(id);
    let count = 0;

    function showError(error) {
      $("error").textContent = error?.message ?? String(error);
      $("error").hidden = false;
    }

    async function add() {
      count += 1;
      $("count").textContent = count;
      await frog.storage.set("count", count);
    }

    $("add").addEventListener("click", () => add().catch(showError));

    // The "count" action in plugin.json: the command bar, a shortcut and `frog run community.<id>.count` call it.
    // Its answer is what they show; return text, or { text, ...data } for agents. Register at once, so none is missed.
    frog.action("count", async () => {
      await add();
      return { text: `Counted ${count} times.`, count };
    });

    frog.storage.get("count").then((saved) => {
      count = saved ?? 0;
      $("count").textContent = count;
    }).catch(showError);

    """
}
