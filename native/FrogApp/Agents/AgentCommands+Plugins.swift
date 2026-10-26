import AppKit
import FrogCore

/// Plugins: what an AI agent needs to build one with the user, install it for their review, test it and share it.
/// Nothing here approves a plugin; only the user does, in Frog's window.
extension AgentCommands {
    static var plugins: [AgentCommand] {
        [
            AgentCommand(words: ["plugins", "guide"], summary: "How to build a plugin: the manifest, permissions and the frog object.",
                         details: "Read it before building or changing a plugin. It is the reference for the Frog version that is running.") { _ in
                let guide = try pluginGuide()
                return AgentResult(["guide": guide], text: guide)
            },
            AgentCommand(words: ["plugins", "new"], arguments: "<folder> [--name NAME] [--id ID]", summary: "Start a plugin from a template.",
                         details: """
                         Creates the folder with a plugin.json, an index.html styled like Frog and an app.js. The folder must \
                         not exist yet, or be empty. The name defaults to the folder's; the id defaults to local.<folder>. \
                         Give a plugin you will share an id you own, such as io.github.<user>.<name>: the id never changes \
                         between versions, and its storage belongs to it.

                         Example: frog plugins new ~/Plugins/pull-requests --name "Pull requests" --id io.github.jane.pull-requests
                         """, options: ["name", "id"]) { call in
                try newPlugin(call)
            },
            AgentCommand(words: ["plugins", "check"], arguments: "<folder>", summary: "Check a plugin's manifest and files.",
                         details: "Reads the folder as installing it would, and points out what would not work in Frog.") { call in
                let package = try PluginPackage.read(call.path(try call.argument(0, "folder")))
                let report = PackageReport(package, hints: hints(for: package))
                var lines = [report.summary]
                lines += report.hints.map { "Hint: \($0)" }
                return AgentResult(report, text: lines.joined(separator: "\n"))
            },
            AgentCommand(words: ["plugins", "install"], arguments: "<folder | file.frogplugin>", summary: "Install or update a plugin, for the user's review.",
                         details: """
                         A folder installs a copy of it. The first install, and an update that asks for more access, \
                         wait for the user to approve them in Frog's window, which shows the review; an update that asks \
                         for nothing new runs at once and reloads the page. Run it again after every change to the folder.

                         A .frogplugin file opens its review in Frog; nothing is installed until the user approves it.

                         Exit code 0 means the plugin was installed; check its state in the answer or with `frog plugins list`.
                         """, feature: .plugins) { call in
                try await install(call)
            },
            AgentCommand(words: ["plugins", "list"], summary: "Installed plugins and their state.", feature: .plugins) { call in
                let runtime = call.model.plugins
                runtime.refresh()
                let entries = runtime.items.map { PluginEntry($0, loaded: runtime.loadedHost($0.id) != nil) }
                guard !entries.isEmpty else { return AgentResult(entries, text: "No plugins are installed.") }
                let text = AgentTable.render(entries.map { [$0.state, $0.id, $0.name, $0.version ?? "", $0.source] })
                return AgentResult(entries, text: text)
            },
            AgentCommand(words: ["plugins", "logs"], arguments: "<id> [--lines N]", summary: "A plugin's console messages and errors.",
                         details: "The page's console.log, errors and rejected promises, and what Frog blocked, since Frog started. The newest come last; --lines takes 1 to 500, 50 by default.",
                         options: ["lines"], feature: .plugins) { call in
                let item = try installed(call)
                let count = try call.integer("lines", default: 50, in: 1...500)
                let lines = (call.model.plugins.logs[item.id] ?? []).suffix(count).map(LogEntry.init)
                guard !lines.isEmpty else { return AgentResult(lines, text: "\(item.name) has logged nothing since Frog started.") }
                return AgentResult(Array(lines), text: lines.map { "\($0.time) \($0.level.padding(toLength: 5, withPad: " ", startingAt: 0)) \($0.text)" }.joined(separator: "\n"))
            },
            AgentCommand(words: ["plugins", "snapshot"], arguments: "<id> [--output FILE]", summary: "Save a picture of a plugin's page.",
                         details: """
                         Loads the page if it is not running and saves a PNG of it, 800 by 600 points unless the page is \
                         open in Frog's window. Look at the picture to check the layout. Without --output it goes to a \
                         temporary folder; the answer gives the path.

                         Example: frog plugins snapshot local.word-counter --output /tmp/word-counter.png
                         """, options: ["output"], feature: .plugins) { call in
                let item = try runnable(call)
                guard item.hasPage else { throw AgentCommandError.failed("\(item.name) has no page; it only has commands.") }
                let png = try await call.model.plugins.snapshot(item.id)
                let file = try snapshotFile(call, id: item.id)
                try png.write(to: file, options: .atomic)
                return AgentResult(["path": file.path], text: file.path)
            },
            AgentCommand(words: ["plugins", "run"], arguments: "<id> <command>", summary: "Run one of a plugin's commands, as the command bar does.",
                         details: "Takes a command id from the plugin's plugin.json. A command without \"show\": false also opens the page in Frog's window.",
                         feature: .plugins) { call in
                let item = try runnable(call)
                let command = try call.argument(1, "command")
                try await call.model.plugins.run(command: command, of: item.id)
                return .done("Sent “\(command)” to \(item.name).")
            },
            AgentCommand(words: ["plugins", "open"], arguments: "<id>", summary: "Show a plugin's page in Frog's window.", feature: .plugins) { call in
                let item = try runnable(call)
                guard item.hasPage else { throw AgentCommandError.failed("\(item.name) has no page; it only has commands.") }
                call.model.openPlugin(item.id)
                NSApp?.activate(ignoringOtherApps: true)
                return .done("Opened \(item.name).")
            },
            AgentCommand(words: ["plugins", "pack"], arguments: "<folder | id> [--output FILE]", summary: "Make a .frogplugin file to share, with its SHA-256.",
                         details: """
                         Packs a plugin's folder, or the installed copy of a plugin by its id. Without --output the file is \
                         <id>-<version>.frogplugin, next to the folder or in the current folder. Hidden files are left out.

                         Share the file over https, such as in a GitHub release. People install it from Frog → Plugins, or \
                         with frog://plugins/install?url=<its https URL>&sha256=<its SHA-256>.
                         """, options: ["output"]) { call in
                try pack(call)
            },
            AgentCommand(words: ["plugins", "remove"], arguments: "<id>", summary: "Remove a plugin and its storage, to the Trash.",
                         details: "Only when the user asks for it. The folder it was installed from is not touched.", feature: .plugins) { call in
                let item = try installed(call)
                call.model.plugins.remove(item.id)
                guard call.model.plugins.item(item.id) == nil else { throw AgentCommandError.failed("\(item.name) could not be removed. Frog's window says why.") }
                return .done("Removed \(item.name).")
            }
        ]
    }

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
            "permissions": [String](), "commands": [[String: Any]]()
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
        Next: edit its files, run `frog plugins check \(folder.path)`, then `frog plugins install \(folder.path)`.
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
        return hints
    }

    // MARK: Installing

    private static func install(_ call: AgentCall) async throws -> AgentResult {
        let model = call.model
        let runtime = model.plugins
        let source = call.path(try call.argument(0, "folder or file"))
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isFolder) else {
            throw AgentCommandError.failed("Nothing is at \(source.path).")
        }
        guard isFolder.boolValue else {
            guard source.pathExtension.lowercased() == PluginArchive.fileExtension else {
                throw AgentCommandError.usage("Give a plugin's folder or a .frogplugin file.")
            }
            let data = try PluginPackage.readFile(source, maximumBytes: PluginArchive.maximumArchiveBytes)
            try await runtime.openArchive(data, source: .file(source.path))
            showPlugins(model)
            let name = runtime.review?.package.manifest.name ?? source.lastPathComponent
            return AgentResult(["state": "review"], text: "Opened the review of \(name) in Frog. Nothing is installed until the user approves it there.")
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
            Ask the user to approve it, then check with `frog plugins list`.
            """
        } else if let problem = item.problem {
            throw AgentCommandError.failed(problem)
        } else if !item.record.enabled {
            text = "Installed \(item.name) \(entry.version ?? ""). It is turned off in Frog → Plugins; ask the user to turn it on."
        } else {
            text = "Installed \(item.name) \(entry.version ?? ""). It runs\(entry.loaded ? ", and its page reloaded" : "")."
        }
        return AgentResult(entry, text: text)
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
        return try item(named: try call.argument(0, "id"), in: runtime.items, kind: "plugin", list: "frog plugins list",
                        id: { $0.id }, title: { $0.name })
    }

    /// An installed plugin that may run now.
    private static func runnable(_ call: AgentCall) throws -> PluginItem {
        let item = try installed(call)
        if let problem = item.problem { throw AgentCommandError.failed(problem) }
        if item.needsReview { throw AgentCommandError.failed("\(item.name) waits for the user's review in Frog → Plugins.") }
        if !item.record.enabled { throw AgentCommandError.failed("\(item.name) is turned off in Frog → Plugins.") }
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

    // MARK: Packing

    private static func pack(_ call: AgentCall) throws -> AgentResult {
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
        let file = call.option("output").map(call.path)
            ?? nextTo.appendingPathComponent("\(manifest.id)-\(manifest.version).\(PluginArchive.fileExtension)")
        guard file.pathExtension.lowercased() == PluginArchive.fileExtension else {
            throw AgentCommandError.usage("--output takes a .\(PluginArchive.fileExtension) file.")
        }
        let root = package.root.standardizedFileURL.path + "/"
        guard !file.standardizedFileURL.path.hasPrefix(root) else {
            throw AgentCommandError.usage("Write the file outside the plugin's folder; inside it, it would be packed into the next version.")
        }
        let data = try PluginArchive.create(package)
        try data.write(to: file, options: .atomic)
        let packed = PackedPlugin(id: manifest.id, version: manifest.version, path: file.path, bytes: data.count,
                                  sha256: PluginPackage.sha256(data))
        let text = """
        Packed \(manifest.name) \(manifest.version) into \(file.path)
        SHA-256: \(packed.sha256)
        Share it over https; the install link is frog://plugins/install?url=<its https URL>&sha256=\(packed.sha256)
        """
        return AgentResult(packed, text: text)
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

    private struct PackedPlugin: Encodable {
        let id: String
        let version: String
        let path: String
        let bytes: Int
        let sha256: String
    }
}

/// The files `frog plugins new` starts a plugin with: a page that uses Frog's stylesheet and the `frog` object.
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
    // Runs inside Frog. `frog` is Frog's API; every call returns a promise. See `frog plugins guide`.
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

    // Commands from the command bar, by their id in plugin.json's "commands". Listen at once, so none is missed.
    frog.on("command", (id) => console.log("Command", id));

    frog.storage.get("count").then((saved) => {
      count = saved ?? 0;
      $("count").textContent = count;
    }).catch(showError);

    """
}
