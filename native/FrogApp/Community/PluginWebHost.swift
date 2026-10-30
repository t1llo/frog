import AppKit
import FrogCore
import UniformTypeIdentifiers
import WebKit

/// One plugin's page: a web view that loads only the plugin's own files from `frog-plugin://<id>/`, keeps no
/// website data, cannot navigate away, and reaches Frog only through the `frog` message handler, whose calls
/// `PluginRuntime` checks against the approved permissions.
@MainActor final class PluginWebHost: NSObject {
    let id: String
    let manifest: PluginManifest
    let webView: WKWebView
    private weak var runtime: PluginRuntime?
    private let schemeHandler: PluginSchemeHandler
    private var loaded = false
    /// Events sent before the page finished loading.
    private var pending: [(String, Any?)] = []
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    /// A window off screen that lays out a page no Frog window shows, for a snapshot.
    private var offscreen: NSWindow?
    /// When the page last received a command; for a moment after, it acts as if it were shown.
    var lastCommand: Date?
    /// The user asked for no more dialogs from this page.
    private var dialogsStopped = false
    var commandedRecently: Bool { lastCommand.map { Date().timeIntervalSince($0) < 10 } ?? false }
    /// The effect of the action that is running; nil while none runs.
    private(set) var runningEffect: PluginManifestAction.Effect?
    /// The effect of the last action that ended, and until when it still holds: work its handler left behind, such
    /// as a timer, stays inside it for a while after the handler answers or times out.
    private var endedEffect: (effect: PluginManifestAction.Effect, until: Date)?
    static let effectGrace: TimeInterval = 30
    /// How many actions have ended, so a page loaded for one is closed only when no other ran since.
    private(set) var endedActions = 0
    /// What the page may do now: the running action's effect or, without one, a recent action's. nil is no limit.
    /// The runtime refuses calls beyond it.
    var effectLimit: PluginManifestAction.Effect? {
        if let runningEffect { return runningEffect }
        guard let endedEffect, endedEffect.until > Date() else { return nil }
        return endedEffect.effect
    }

    /// Whether the page is on screen; the page hears `show` and `hide`.
    var isShowing = false {
        didSet { if isShowing != oldValue { emit(isShowing ? "show" : "hide") } }
    }

    init(package: PluginPackage, contentRules: WKContentRuleList?, runtime: PluginRuntime, inspectable: Bool) {
        id = package.manifest.id
        manifest = package.manifest
        self.runtime = runtime
        schemeHandler = PluginSchemeHandler(id: package.manifest.id, folder: package.root)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: PluginPageSource.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        // A page that runs commands while hidden, such as a timer, keeps running at full speed.
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.upgradeKnownHostsToHTTPS = true
        PluginPageSource.restrict(configuration.preferences)
        if let contentRules { configuration.userContentController.add(contentRules) }
        let info: [String: Any] = ["id": manifest.id, "name": manifest.name, "version": manifest.version,
                                   "permissions": manifest.permissions.map(\.rawValue), "frog": AppVersion.current]
        let infoJSON = (try? JSONSerialization.data(withJSONObject: info)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        configuration.userContentController.addUserScript(WKUserScript(source: PluginPageSource.bridge(info: infoJSON), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(source: PluginPageSource.applyTheme(PluginPageSource.themeStyle()), injectionTime: .atDocumentStart, forMainFrameOnly: true))

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.customUserAgent = "Frog/\(AppVersion.current) Plugin/\(manifest.id)"
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.isInspectable = inspectable
        webView.underPageBackgroundColor = .clear
        super.init()
        configuration.userContentController.addScriptMessageHandler(PluginMessageProxy(host: self), contentWorld: .page, name: "frog")
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func load() {
        // A plugin with commands only still gets a page to run them in.
        guard let url = URL(string: "\(PluginPageSource.scheme)://\(id)/\(manifest.entry ?? "_frog/blank.html")") else { return }
        webView.load(URLRequest(url: url))
    }

    func reload() {
        loaded = false
        load()
    }

    /// Sends an event to the page's `frog.on` listeners, after it has loaded.
    func emit(_ event: String, _ value: Any? = nil) {
        guard loaded else { pending.append((event, value)); return }
        webView.callAsyncJavaScript("if (window.__frogEmit) window.__frogEmit(event, value);", arguments: ["event": event, "value": value ?? NSNull()],
                                    in: nil, in: .page) { _ in }
    }

    /// Runs one of the manifest's actions in the page and returns what its handler returned, as JSON, or nil.
    /// One action runs at a time; it gets `seconds` to answer.
    func perform(_ action: PluginManifestAction, values: [String: Any], text: String?, seconds: Double = 60) async throws -> String? {
        guard runningEffect == nil else { throw FrogError.message("\(manifest.name) is still running another action.") }
        runningEffect = action.effect
        // An action that changes things may write the clipboard or show the page, as a command may; one that only
        // reads may not.
        if action.effect > .read { lastCommand = Date() }
        defer {
            runningEffect = nil
            // Two ended actions in the grace: the smaller effect holds, since either may have left work behind.
            let held = endedEffect.flatMap { $0.until > Date() ? $0.effect : nil }
            endedEffect = (min(action.effect, held ?? action.effect), Date().addingTimeInterval(Self.effectGrace))
            endedActions += 1
        }
        await waitUntilLoaded()
        guard loaded else { throw FrogError.message("\(manifest.name)'s page did not load.") }
        let answer = PerformAnswer()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
            answer.continuation = continuation
            webView.callAsyncJavaScript("return await window.__frogPerform(name, params, text);",
                                        arguments: ["name": action.id, "params": values, "text": text ?? NSNull()],
                                        in: nil, in: .page) { result in
                switch result {
                case .success(let value): answer.finish(.success(value as? String))
                case .failure(let error):
                    let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                    answer.finish(.failure(FrogError.message(message)))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                answer.finish(.failure(FrogError.message("\(manifest.name) did not answer “\(action.title)” within \(Int(seconds)) seconds.")))
            }
        }
    }

    func refreshTheme() {
        webView.evaluateJavaScript(PluginPageSource.applyTheme(PluginPageSource.themeStyle())) { _, _ in }
    }

    /// Waits until the page has loaded, at most `seconds`.
    func waitUntilLoaded(seconds: Double = 10) async {
        guard !loaded else { return }
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.releaseWaiters()
        }
        await withCheckedContinuation { loadWaiters.append($0) }
        timeout.cancel()
    }

    private func releaseWaiters() {
        let waiters = loadWaiters
        loadWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// A PNG of the page. A page no window shows is laid out off screen at 800 × 600 points first.
    func snapshot() async throws -> Data {
        if webView.window == nil {
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            window.contentView?.addSubview(webView)
            window.orderBack(nil)
            offscreen = window
        }
        defer {
            if let offscreen {
                if webView.window === offscreen { webView.removeFromSuperview() }
                offscreen.orderOut(nil)
                self.offscreen = nil
            }
        }
        await waitUntilLoaded()
        try? await Task.sleep(for: .milliseconds(300))
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw FrogError.message("Could not make a picture of the page.") }
        return png
    }

    func stop() {
        releaseWaiters()
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.removeFromSuperview()
        pending = []
    }

    fileprivate func receive(_ message: WKScriptMessage) async -> (Any?, String?) {
        // Only the plugin's own top-level page speaks for it.
        guard message.webView === webView, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == PluginPageSource.scheme, message.frameInfo.securityOrigin.host == id,
              let body = message.body as? [String: Any], let name = body["name"] as? String else {
            return (nil, "Frog only answers the plugin's own page.")
        }
        let arguments = body["args"] as? [String: Any] ?? [:]
        guard let runtime else { return (nil, "Frog is shutting down.") }
        do { return (try await runtime.handle(name, arguments, from: self), nil) }
        catch { return (nil, error.localizedDescription) }
    }

    fileprivate func finishedLoading() {
        loaded = true
        releaseWaiters()
        let events = pending
        pending = []
        if isShowing { emit("show") }
        for (event, value) in events where event != "show" && event != "hide" { emit(event, value) }
    }
}

/// Passes the bridge's messages to the host without the content controller keeping the host alive.
private final class PluginMessageProxy: NSObject, WKScriptMessageHandlerWithReply {
    weak var host: PluginWebHost?
    init(host: PluginWebHost) { self.host = host }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        MainActor.assumeIsolated {
            guard let host else { replyHandler(nil, "The plugin was closed."); return }
            Task { @MainActor in
                let (value, error) = await host.receive(message)
                replyHandler(value, error)
            }
        }
    }
}

extension PluginWebHost: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if navigationAction.shouldPerformDownload { decisionHandler(.cancel); return }
        if url?.scheme == PluginPageSource.scheme, url?.host == id, navigationAction.targetFrame?.isMainFrame != false {
            decisionHandler(.allow); return
        }
        decisionHandler(.cancel)
        if let url, navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
            runtime?.followLink(url, from: self)
        } else if let url {
            runtime?.log(id, level: "warn", "Blocked a page load: \(url.absoluteString.prefix(200))")
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishedLoading() }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        runtime?.log(id, level: "error", "The page failed to load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        runtime?.log(id, level: "error", "The page failed to load: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        runtime?.log(id, level: "error", "The page stopped unexpectedly and was loaded again.")
        reload()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { runtime?.followLink(url, from: self) }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    // Dialogs and file panels are sheets on the plugin's own page, only while the user looks at it, and say which
    // plugin asks. A hidden page gets the answer a closed dialog gives, and the user can stop a page's dialogs.

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable () -> Void) {
        dialog(message, buttons: ["OK"]) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        dialog(message, buttons: ["OK", "Cancel"]) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        dialog(prompt, buttons: ["OK", "Cancel"], accessory: field) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    /// Files the user picks are the only files a page can read.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        guard isShowing, let window = webView.window, window.attachedSheet == nil else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.message = "The plugin “\(manifest.name)” asks for a file."
        panel.beginSheetModal(for: window) { response in completionHandler(response == .OK ? panel.urls : nil) }
    }

    private func dialog(_ message: String, buttons: [String], accessory: NSView? = nil,
                        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        guard isShowing, !dialogsStopped, let window = webView.window, window.attachedSheet == nil else {
            runtime?.log(id, level: "warn", "Answered a dialog the user could not see: \(message.prefix(200))")
            completion(.alertSecondButtonReturn)
            return
        }
        let alert = NSAlert()
        alert.messageText = "The plugin “\(manifest.name)” says"
        alert.informativeText = String(message.prefix(2_000))
        for button in buttons { alert.addButton(withTitle: button) }
        alert.accessoryView = accessory
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t show more dialogs from this plugin"
        alert.beginSheetModal(for: window) { [weak self] response in
            if alert.suppressionButton?.state == .on { self?.dialogsStopped = true }
            completion(response)
        }
    }
}

/// Serves the plugin's folder at `frog-plugin://<id>/`, with the content policy on every response, and Frog's
/// stylesheet at `/_frog/frog.css`. Nothing outside the folder is reachable.
final class PluginSchemeHandler: NSObject, WKURLSchemeHandler {
    let id: String
    let folder: URL
    init(id: String, folder: URL) { self.id = id; self.folder = folder }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.scheme == PluginPageSource.scheme, url.host == id else {
            respond(task, url: task.request.url, status: 403, data: Data("Forbidden".utf8), type: "text/plain"); return
        }
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty || path.hasSuffix("/") { path += "index.html" }
        if path.hasPrefix("_frog/") {
            if let file = PluginPageSource.builtInFile(String(path.dropFirst("_frog/".count))) {
                respond(task, url: url, status: 200, data: file.data, type: file.type)
            } else {
                respond(task, url: url, status: 404, data: Data("Not found".utf8), type: "text/plain")
            }
            return
        }
        guard PluginPath.isSafe(path), let data = try? PluginPackage.readFile(folder.appendingPathComponent(path), maximumBytes: PluginPackage.maximumBytes) else {
            respond(task, url: url, status: 404, data: Data("Not found".utf8), type: "text/plain"); return
        }
        respond(task, url: url, status: 200, data: data, type: PluginPageSource.mimeType(for: path))
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func respond(_ task: any WKURLSchemeTask, url: URL?, status: Int, data: Data, type: String) {
        let url = url ?? URL(string: "\(PluginPageSource.scheme)://\(id)/")!
        let textual = type.hasPrefix("text/") || type == "application/json" || type == "image/svg+xml"
        let headers = [
            "Content-Type": textual ? "\(type); charset=utf-8" : type,
            "Content-Length": String(data.count),
            "Content-Security-Policy": PluginPageSource.contentSecurityPolicy(for: id),
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "no-store",
            "Referrer-Policy": "no-referrer"
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}

/// The answer to one `perform`: the page's or the timeout's, whichever comes first.
@MainActor private final class PerformAnswer {
    var continuation: CheckedContinuation<String?, Error>?
    func finish(_ result: Result<String?, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
