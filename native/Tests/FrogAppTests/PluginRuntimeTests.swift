import AppKit
import CryptoKit
import FrogCore
import WebKit
import XCTest
@testable import FrogApp

/// A real plugin page in a web view, calling Frog through `window.frog`, so the checks are the ones a plugin meets.
@MainActor final class PluginRuntimeTests: XCTestCase {
    private var root: URL!
    private var runtime: PluginRuntime!
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("frog-plugin-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("frog-plugin-test-\(UUID().uuidString)"))
        runtime = PluginRuntime(store: PluginStore(directory: root.appendingPathComponent("Plugins", isDirectory: true)))
        runtime.pasteboard = pasteboard
        runtime.registryURL = nil
        runtime.configure(enabled: true)
    }

    override func tearDown() async throws {
        runtime.stop()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    private func makePlugin(permissions: [String], extra: [String: Any] = [:], html: String = "<!doctype html><title>Test</title><p>Hi</p>") throws -> URL {
        let folder = root.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest: [String: Any] = ["id": "com.example.test", "name": "Test", "version": "1.0.0", "description": "A test.", "permissions": permissions]
        for (key, value) in extra { manifest[key] = value }
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("plugin.json"))
        try Data(html.utf8).write(to: folder.appendingPathComponent("index.html"))
        return folder
    }

    /// Installs and approves the plugin, and returns its loaded page.
    private func running(_ folder: URL) async throws -> PluginWebHost {
        let package = try PluginPackage.read(folder)
        try runtime.store.install(package, source: .folder(folder.path), approving: true)
        runtime.refresh()
        let host = try await runtime.host(for: package.manifest.id)
        await host.waitUntilLoaded()
        return host
    }

    /// Runs `body`, an async function body, in the page and returns what it returns, as JSON.
    private func evaluate(_ body: String, in host: PluginWebHost) async throws -> [String: Any] {
        let value = try await host.webView.callAsyncJavaScript("return JSON.stringify(await (async () => { \(body) })())",
                                                                arguments: [:], in: nil, contentWorld: .page)
        let text = try XCTUnwrap(value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testThePageReachesOnlyWhatItWasGranted() async throws {
        let host = try await running(try makePlugin(permissions: ["clipboard-read", "clipboard-write"]))
        pasteboard.clearContents()
        pasteboard.setString("copied", forType: .string)

        let result = try await evaluate("""
            const out = {};
            const attempt = async (name, work) => { try { out[name] = await work(); } catch (error) { out[name] = "error: " + error.message; } };
            await frog.storage.set("count", { value: 3 });
            out.stored = await frog.storage.get("count");
            out.keys = await frog.storage.keys();
            await attempt("hiddenRead", () => frog.clipboard.readText());
            await attempt("hiddenWrite", () => frog.clipboard.writeText("from plugin"));
            await attempt("show", () => frog.show());
            out.confirm = confirm("Allow?");
            out.prompt = prompt("Your password?");
            // An empty frame gets fresh copies of what the bridge removes, so WebKit itself has them off.
            const frame = document.createElement("iframe");
            document.body.append(frame);
            out.frame = ["RTCPeerConnection", "WebTransport", "Notification"].map((name) => typeof frame.contentWindow[name]);
            out.frameClipboard = typeof frame.contentWindow.navigator.clipboard;
            out.clipboardAPI = typeof navigator.clipboard;
            await attempt("frogFetch", () => frog.fetch("https://example.com"));
            await attempt("ai", () => frog.ai("Say hi"));
            await attempt("script", () => frog.run("anything"));
            await attempt("link", () => frog.openURL("https://example.com"));
            await attempt("unknown", () => window.webkit.messageHandlers.frog.postMessage({ name: "secret", args: {} }));
            out.direct = await fetch("https://example.com").then(() => "reached", () => "blocked");
            out.image = await new Promise((resolve) => { const image = new Image(); image.onload = () => resolve("reached"); image.onerror = () => resolve("blocked"); image.src = "https://example.com/x.png"; });
            out.webrtc = typeof RTCPeerConnection;
            out.frogFrozen = Object.isFrozen(frog);
            out.css = await fetch("/_frog/frog.css").then((response) => response.status);
            out.outside = await fetch("/%2e%2e/%2e%2e/plugins.json").then((response) => response.status, () => "blocked");
            return out;
            """, in: host)

        XCTAssertEqual(result["stored"] as? [String: Int], ["value": 3])
        XCTAssertEqual(result["keys"] as? [String], ["count"])
        XCTAssertEqual(result["hiddenRead"] as? String, "error: A plugin reads the clipboard only while its page is open or right after one of its commands.")
        XCTAssertEqual(result["hiddenWrite"] as? String, "error: A plugin writes the clipboard only while its page is open or right after one of its commands.")
        XCTAssertEqual(pasteboard.string(forType: .string), "copied")
        XCTAssertEqual(result["show"] as? String, "error: A plugin shows its page only right after one of its commands.")
        XCTAssertEqual(result["confirm"] as? Bool, false, "A hidden page's dialog is answered without asking the user")
        XCTAssertTrue(result["prompt"] is NSNull)
        XCTAssertEqual(result["frame"] as? [String], ["undefined", "undefined", "undefined"])
        XCTAssertEqual(result["frameClipboard"] as? String, "undefined")
        XCTAssertEqual(result["clipboardAPI"] as? String, "undefined")
        for name in ["frogFetch", "ai", "script", "link"] {
            XCTAssertTrue((result[name] as? String)?.contains("permission in plugin.json") == true, "\(name): \(result[name] ?? "nil")")
        }
        XCTAssertEqual(result["unknown"] as? String, "error: Frog has no “secret”.")
        XCTAssertEqual(result["direct"] as? String, "blocked")
        XCTAssertEqual(result["image"] as? String, "blocked")
        XCTAssertEqual(result["webrtc"] as? String, "undefined")
        XCTAssertEqual(result["frogFrozen"] as? Bool, true)
        XCTAssertEqual(result["css"] as? Int, 200)
        XCTAssertNotEqual(result["outside"] as? Int, 200)
    }

    func testClipboardReadsWhileShownAndNeverConcealedText() async throws {
        let host = try await running(try makePlugin(permissions: ["clipboard-read", "clipboard-write"]))
        host.isShowing = true
        pasteboard.clearContents()
        pasteboard.setString("visible", forType: .string)
        var result = try await evaluate("return { text: await frog.clipboard.readText() };", in: host)
        XCTAssertEqual(result["text"] as? String, "visible")

        let item = NSPasteboardItem()
        item.setString("secret", forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        result = try await evaluate("return { text: await frog.clipboard.readText() };", in: host)
        XCTAssertTrue(result["text"] is NSNull, "\(result)")

        _ = try await evaluate("await frog.clipboard.writeText(\"from plugin\"); return {};", in: host)
        XCTAssertEqual(pasteboard.string(forType: .string), "from plugin")
    }

    func testWebKitHasTheFeaturesPastTheBridgeOff() {
        let preferences = WKPreferences()
        // Older WebKit, such as CI's, has no LinkDNSPrefetchEnabled; the older DNS prefetching setting covers it there.
        XCTAssertEqual(PluginPageSource.restrict(preferences).union(["LinkDNSPrefetchEnabled"]), PluginPageSource.disabledFeatures,
                       "Every feature is one this WebKit knows and now has off; update the list when WebKit renames one")
        if preferences.responds(to: Selector(("_dnsPrefetchingEnabled"))) {
            XCTAssertEqual(preferences.value(forKey: "_dnsPrefetchingEnabled") as? Bool, false)
        }
    }

    func testACommandsOnlyPluginRunsInFrogsOwnPage() async throws {
        let host = try await running(try makePlugin(permissions: [], extra: ["entry": NSNull(), "commands": [["id": "go", "title": "Go"]]]))
        let result = try await evaluate("return { url: location.href, frog: typeof frog, direct: await fetch(\"https://example.com\").then(() => \"reached\", () => \"blocked\") };", in: host)
        XCTAssertEqual(result["url"] as? String, "frog-plugin://com.example.test/_frog/blank.html")
        XCTAssertEqual(result["frog"] as? String, "object")
        XCTAssertEqual(result["direct"] as? String, "blocked")
    }

    func testCommandsWaitForTheirListenerAndHiddenPagesClose() async throws {
        let host = try await running(try makePlugin(permissions: [], extra: ["commands": [["id": "start", "title": "Start", "show": false]]]))
        try await runtime.run(command: "start", of: "com.example.test")
        let result = try await evaluate("return { command: await new Promise((resolve) => frog.on(\"command\", resolve)) };", in: host)
        XCTAssertEqual(result["command"] as? String, "start")
        _ = try await evaluate("await frog.close(); return {};", in: host)
        XCTAssertNil(runtime.loadedHost("com.example.test"))
    }

    func testAnUpdateAskingForMoreStopsUntilReviewedAndApprovalMatchesTheReview() async throws {
        let first = try makePlugin(permissions: [])
        _ = try await running(first)
        let wider = try makePlugin(permissions: ["clipboard-read"])
        let item = try runtime.installFolder(wider)
        XCTAssertTrue(item.needsReview)
        XCTAssertNil(runtime.loadedHost(item.id))
        do { _ = try await runtime.host(for: item.id); XCTFail("An update asking for more ran before review.") } catch {}

        try runtime.reviewInstalled(item.id)
        let review = try XCTUnwrap(runtime.review)
        XCTAssertEqual(review.additions.permissions, [.clipboardRead])
        // The plugin asks for still more while the review is open: approving what was shown is refused.
        _ = try runtime.installFolder(try makePlugin(permissions: ["clipboard-read", "clipboard-write"]))
        XCTAssertThrowsError(try runtime.approve(review))
        XCTAssertTrue(runtime.item(item.id)?.needsReview == true)
    }

    func testAScriptRunsAsApprovedAndNotOnceItsFileChanged() async throws {
        let folder = try makePlugin(permissions: ["scripts"], extra: ["scripts": ["hello": "hello.sh"]])
        try Data("printf '%s:%s:%s' \"$1\" \"$FROG_INPUT\" \"$(basename \"$PWD\")\"".utf8).write(to: folder.appendingPathComponent("hello.sh"))
        try Data("echo helper".utf8).write(to: folder.appendingPathComponent("helper.sh"))
        let host = try await running(folder)
        var result = try await evaluate("return await frog.run(\"hello\", { args: [\"a\"], input: \"b\" });", in: host)
        XCTAssertEqual(result["output"] as? String, "a:b:com.example.test")
        XCTAssertEqual(result["status"] as? Int, 0)

        // A file the script could run changed: that needs the user's review as much as the script itself.
        try Data("echo changed".utf8).write(to: runtime.store.folder(for: "com.example.test").appendingPathComponent("helper.sh"))
        result = try await evaluate("""
            try { await frog.run("hello"); return { ran: true }; } catch (error) { return { error: error.message }; }
            """, in: host)
        XCTAssertEqual(result["error"] as? String, "The script “hello” changed since you approved it. Review the plugin again.")

        try Data("echo changed".utf8).write(to: runtime.store.folder(for: "com.example.test").appendingPathComponent("hello.sh"))
        result = try await evaluate("""
            try { await frog.run("hello"); return { ran: true }; } catch (error) { return { error: error.message }; }
            """, in: host)
        XCTAssertEqual(result["error"] as? String, "The script “hello” changed since you approved it. Review the plugin again.")
    }

    func testAFileWithAnInstalledPluginsIdFromElsewhereIsReviewedAsNew() async throws {
        let folder = try makePlugin(permissions: ["clipboard-read"])
        let package = try PluginPackage.read(folder)
        try runtime.store.install(package, source: .link("https://github.com/jane/test/v1.frogplugin"), approving: true)
        runtime.refresh()

        try await runtime.openArchive(try PluginArchive.create(package), source: .file("/tmp/test.frogplugin"))
        let review = try XCTUnwrap(runtime.review)
        XCTAssertNil(review.approved, "Every permission shows as new")
        XCTAssertEqual(review.replacing, .link("https://github.com/jane/test/v1.frogplugin"))

        try await runtime.openArchive(try PluginArchive.create(package), source: .link("https://github.com/jane/test/v2.frogplugin"))
        XCTAssertNotNil(runtime.review?.approved)
        XCTAssertNil(runtime.review?.replacing)
    }

    func testALinkThatDoesNotMatchItsHashIsRefusedBeforeDownloading() async {
        do {
            try await runtime.openLink(URL(string: "http://example.com/a.frogplugin")!, sha256: nil)
            XCTFail("A plain http link was accepted.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Plugins install only from https links.")
        }
        do {
            try await runtime.openLink(URL(string: "https://example.com/a.frogplugin")!, sha256: "not-a-hash")
            XCTFail("An invalid hash was accepted.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The link's SHA-256 is not valid.")
        }
    }

    // MARK: Actions

    private static let actionPage = """
    <!doctype html><title>Test</title><script>
    frog.action("echo", async (params, input) => ({ text: `${params.word} ${params.times} ${input ?? ""}`.trim(), params }));
    frog.action("store", async () => { await frog.storage.set("k", 1); return "stored"; });
    frog.action("peek", async () => { await frog.storage.set("k", 2); return "wrote"; });
    frog.action("fail", async () => { throw new Error("Nope"); });
    frog.action("later", async () => {
      setTimeout(async () => {
        try { await frog.storage.set("k", 3); window.late = "wrote"; } catch (error) { window.late = String(error.message || error); }
      }, 200);
      return "scheduled";
    });
    </script>
    """

    func testActionsRunInThePageWithTypedParametersAndKeepToTheirEffect() async throws {
        let actions: [[String: Any]] = [
            ["id": "echo", "title": "Echo", "effect": "read", "input": true,
             "parameters": [["name": "word", "type": "text", "required": true], ["name": "times", "type": "integer"]]],
            ["id": "store", "title": "Store", "effect": "write"],
            ["id": "peek", "title": "Peek", "effect": "read"],
            ["id": "fail", "title": "Fail", "effect": "read"],
            ["id": "later", "title": "Later", "effect": "read"],
        ]
        let host = try await running(try makePlugin(permissions: [], extra: ["actions": actions], html: Self.actionPage))

        let echo = try await runtime.perform("echo", of: "com.example.test", values: ["word": "hi", "times": "3"], text: "there")
        XCTAssertEqual(echo.text, "hi 3 there")
        let params = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(echo.json.utf8)) as? [String: Any])?["params"] as? [String: Any])
        XCTAssertEqual(params["times"] as? Int, 3, "An integer parameter reaches the page as a number")

        XCTAssertNil(host.lastCommand, "A read action does not open the window a command opens for writing the clipboard or showing")
        let stored = try await runtime.perform("store", of: "com.example.test", values: [:], text: nil)
        XCTAssertEqual(stored.text, "stored")
        XCTAssertNotNil(host.lastCommand)
        do {
            _ = try await runtime.perform("peek", of: "com.example.test", values: [:], text: nil)
            XCTFail("A read action cannot write storage")
        } catch { XCTAssertTrue(error.localizedDescription.contains("effect"), error.localizedDescription) }
        do {
            _ = try await runtime.perform("fail", of: "com.example.test", values: [:], text: nil)
            XCTFail("A handler that throws fails the action")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Nope"), error.localizedDescription) }
        do {
            _ = try await runtime.perform("echo", of: "com.example.test", values: ["word": "hi", "times": "many"], text: nil)
            XCTFail("An integer parameter takes a whole number")
        } catch {}

        // Work a read action leaves behind stays inside its effect after the handler has answered.
        let later = try await runtime.perform("later", of: "com.example.test", values: [:], text: nil)
        XCTAssertEqual(later.text, "scheduled")
        try await Task.sleep(for: .milliseconds(600))
        let late = try await evaluate("return { late: window.late ?? null };", in: host)
        XCTAssertTrue((late["late"] as? String)?.contains("effect") == true, "\(late)")
        XCTAssertEqual(host.effectLimit, .read)
    }

    func testAnswersBecomeTextAndJSON() {
        XCTAssertEqual(PluginRuntime.result(#""plain""#).text, "plain")
        XCTAssertEqual(PluginRuntime.result(#"{"text":"Shown","n":1}"#).text, "Shown")
        XCTAssertEqual(PluginRuntime.result(nil).text, "Done.")
        XCTAssertEqual(PluginRuntime.effect(of: "storage.get"), .read)
        XCTAssertEqual(PluginRuntime.effect(of: "clipboard.write"), .write)
        XCTAssertEqual(PluginRuntime.effect(of: "fetch"), .network)
    }

    // MARK: Directory

    private func signedEntry(for folder: URL, key: Curve25519.Signing.PrivateKey, archive: Data, download: String) throws -> PluginRegistryEntry {
        let manifest = try PluginPackage.read(folder).manifest
        var entry = PluginRegistryEntry(id: manifest.id, name: manifest.name, summary: manifest.description, version: manifest.version,
                                        author: "Tester", permissions: manifest.permissions.map(\.rawValue),
                                        manifest: "https://example.com/plugins/files/test.json", download: download,
                                        sha256: PluginPackage.sha256(archive))
        entry.signature = try key.signature(for: entry.signedMessage).base64EncodedString()
        return entry
    }

    private func serve(_ files: [String: Data]) {
        runtime.download = { url, _ in
            guard let data = files[url.absoluteString] else { throw FrogError.message("No file at \(url)") }
            return data
        }
    }

    func testTheDirectoryInstallsOnlySignedFilesAndAPluginWithoutPermissionsInOneClick() async throws {
        let key = Curve25519.Signing.PrivateKey()
        runtime.registryKeys = [key.publicKey.rawRepresentation.base64EncodedString()]
        runtime.registryURL = URL(string: "https://example.com/plugins/registry.json")
        let folder = try makePlugin(permissions: [])
        let archive = try PluginArchive.create(try PluginPackage.read(folder))
        let good = try signedEntry(for: folder, key: key, archive: archive, download: "https://example.com/plugins/files/test.frogplugin")
        var forged = good
        forged.id = "com.example.forged"
        let stranger = try signedEntry(for: folder, key: Curve25519.Signing.PrivateKey(), archive: archive, download: good.download)
        let registry = try JSONEncoder().encode(PluginRegistry(plugins: [good, forged, stranger]))
        serve(["https://example.com/plugins/registry.json": registry, good.download: archive])

        await runtime.loadRegistry()
        XCTAssertNil(runtime.registryError)
        XCTAssertEqual(runtime.registry.map(\.id), ["com.example.test"])
        XCTAssertEqual(runtime.registryRejected, 2, "A changed entry and one signed by another key are left out")

        let installed = try await runtime.install(good)
        XCTAssertTrue(installed, "A plugin that asks for no permissions installs at once")
        XCTAssertNil(runtime.review)
        XCTAssertEqual(runtime.item("com.example.test")?.record.sha256, good.sha256)
        XCTAssertTrue(runtime.isListed(good.sha256))
    }

    func testTheDirectoryRefusesAFileThatIsNotTheSignedOneAndReviewsOneThatAsksForAccess() async throws {
        let key = Curve25519.Signing.PrivateKey()
        runtime.registryKeys = [key.publicKey.rawRepresentation.base64EncodedString()]
        runtime.registryURL = URL(string: "https://example.com/plugins/registry.json")
        let folder = try makePlugin(permissions: ["clipboard-read"])
        let archive = try PluginArchive.create(try PluginPackage.read(folder))
        let entry = try signedEntry(for: folder, key: key, archive: archive, download: "https://example.com/plugins/files/test.frogplugin")
        serve(["https://example.com/plugins/registry.json": try JSONEncoder().encode(PluginRegistry(plugins: [entry])),
               entry.download: archive + Data([0])])
        await runtime.loadRegistry()
        do {
            try await runtime.install(entry)
            XCTFail("A file whose SHA-256 is not the signed one is refused")
        } catch { XCTAssertTrue(error.localizedDescription.contains("SHA-256"), error.localizedDescription) }
        XCTAssertNil(runtime.item("com.example.test"))

        serve(["https://example.com/plugins/registry.json": try JSONEncoder().encode(PluginRegistry(plugins: [entry])), entry.download: archive])
        let installed = try await runtime.install(entry)
        XCTAssertFalse(installed, "A plugin that asks for access waits for its review")
        XCTAssertEqual(runtime.review?.package.manifest.id, "com.example.test")
        XCTAssertNil(runtime.item("com.example.test"), "Nothing is installed before the user approves it")
    }

    /// Serves `entries` as the signed directory, each with its archive, and reads it.
    private func publish(_ folders: [URL], key: Curve25519.Signing.PrivateKey) async throws -> [PluginRegistryEntry] {
        var files: [String: Data] = [:], entries: [PluginRegistryEntry] = []
        for folder in folders {
            let manifest = try PluginPackage.read(folder).manifest
            let archive = try PluginArchive.create(try PluginPackage.read(folder))
            let download = "https://example.com/plugins/files/\(manifest.id)-\(manifest.version).frogplugin"
            entries.append(try signedEntry(for: folder, key: key, archive: archive, download: download))
            files[download] = archive
        }
        files["https://example.com/plugins/registry.json"] = try JSONEncoder().encode(PluginRegistry(plugins: entries))
        serve(files)
        await runtime.loadRegistry()
        return entries
    }

    private func directory() -> Curve25519.Signing.PrivateKey {
        let key = Curve25519.Signing.PrivateKey()
        runtime.registryKeys = [key.publicKey.rawRepresentation.base64EncodedString()]
        runtime.registryURL = URL(string: "https://example.com/plugins/registry.json")
        return key
    }

    func testTheDirectoryNeverRollsAPluginBackAndReviewsAnActionThatDoesMore() async throws {
        let key = directory()
        let reads: [[String: Any]] = [["id": "go", "title": "Go", "effect": "read"]]
        let writes: [[String: Any]] = [["id": "go", "title": "Go", "effect": "write"]]
        let first = try await publish([try makePlugin(permissions: [], extra: ["actions": reads], html: Self.actionPage)], key: key)
        let firstInstalled = try await runtime.install(first[0])
        XCTAssertTrue(firstInstalled)

        let raised = try await publish([try makePlugin(permissions: [], extra: ["version": "1.1.0", "actions": writes], html: Self.actionPage)], key: key)
        let raisedInstalled = try await runtime.install(raised[0])
        XCTAssertFalse(raisedInstalled, "An update whose action does more than before waits for its review")
        XCTAssertEqual(runtime.review?.package.manifest.version, "1.1.0")
        XCTAssertEqual(runtime.item("com.example.test")?.manifest?.version, "1.0.0")
        try runtime.approve(try XCTUnwrap(runtime.review))

        let older = try await publish([try makePlugin(permissions: [], extra: ["actions": writes], html: Self.actionPage)], key: key)
        do {
            try await runtime.install(older[0])
            XCTFail("An older version never replaces a newer one")
        } catch { XCTAssertTrue(error.localizedDescription.contains("newer"), error.localizedDescription) }
        XCTAssertEqual(runtime.item("com.example.test")?.manifest?.version, "1.1.0")
        XCTAssertEqual(PluginRuntime.raisedEffects(try PluginPackage.read(try makePlugin(permissions: [], extra: ["actions": writes])).manifest, over: nil).map(\.id), ["go"],
                       "A new action that changes things counts as doing more")
    }

    func testADirectoryInstallLeavesAnOpenReviewAlone() async throws {
        let key = directory()
        let other = try makePlugin(permissions: ["clipboard-read"], extra: ["id": "com.example.other"])
        try await runtime.openArchive(try PluginArchive.create(try PluginPackage.read(other)), source: .link("https://elsewhere.example/other.frogplugin"))
        let open = try XCTUnwrap(runtime.review)

        let entries = try await publish([try makePlugin(permissions: [])], key: key)
        let installed = try await runtime.install(entries[0])
        XCTAssertTrue(installed)
        XCTAssertEqual(runtime.review?.id, open.id, "The review that was open stays open")
        XCTAssertTrue(FileManager.default.fileExists(atPath: open.package.root.path), "and keeps its unpacked files")
        try runtime.approve(open)
        XCTAssertNotNil(runtime.item("com.example.other"))
    }
}
