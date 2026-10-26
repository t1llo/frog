import AppKit
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
        runtime.directoryURL = nil
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
            await frog.clipboard.writeText("from plugin");
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
        XCTAssertEqual(pasteboard.string(forType: .string), "from plugin")
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
        let host = try await running(try makePlugin(permissions: ["clipboard-read"]))
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
        let host = try await running(folder)
        var result = try await evaluate("return await frog.run(\"hello\", { args: [\"a\"], input: \"b\" });", in: host)
        XCTAssertEqual(result["output"] as? String, "a:b:com.example.test")
        XCTAssertEqual(result["status"] as? Int, 0)

        try Data("echo changed".utf8).write(to: runtime.store.folder(for: "com.example.test").appendingPathComponent("hello.sh"))
        result = try await evaluate("""
            try { await frog.run("hello"); return { ran: true }; } catch (error) { return { error: error.message }; }
            """, in: host)
        XCTAssertEqual(result["error"] as? String, "The script “hello” changed since you approved it. Review the plugin again.")
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
}
