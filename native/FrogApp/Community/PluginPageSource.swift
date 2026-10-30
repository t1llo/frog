import AppKit
import FrogCore
import SwiftUI
import WebKit

/// What Frog adds to every plugin page: the content policy, the `window.frog` bridge, and the
/// theme's colours as CSS variables.
enum PluginPageSource {
    static let scheme = "frog-plugin"

    /// Only the plugin's own files load. Remote requests go through `frog.fetch`, which Frog checks.
    static func contentSecurityPolicy(for id: String) -> String {
        let own = "'self' \(scheme)://\(id)"
        return [
            "default-src 'none'",
            "script-src \(own) 'unsafe-inline' 'unsafe-eval'",
            "style-src \(own) 'unsafe-inline'",
            "img-src \(own) data: blob:",
            "font-src \(own) data:",
            "media-src \(own) data: blob:",
            "connect-src \(own)",
            "worker-src \(own) blob:",
            "frame-src 'none'", "child-src 'none'", "object-src 'none'", "manifest-src 'none'",
            "base-uri 'none'", "form-action 'none'"
        ].joined(separator: "; ")
    }

    /// Blocks every load that is not the plugin's own, data or blob, in case anything gets past the policy.
    /// WebKit's filters take no alternation, so each scheme has its own rule.
    static let contentRules = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^frog-plugin:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}}]
    """

    /// WebKit features a plugin page has in no frame: ways past `window.frog` to the network, the clipboard or the user.
    /// The policy and the bridge cover the main frame, but an empty frame the page adds gets fresh copies of them,
    /// and DNS prefetching names hosts that neither the policy nor the content rules see.
    static let disabledFeatures: Set<String> = [
        "PeerConnectionEnabled", "WebTransportEnabled", "LinkDNSPrefetchEnabled", "LinkPreconnect", "LinkPreconnectEarlyHintsEnabled",
        "AsyncClipboardAPIEnabled", "DOMPasteAccessRequestsEnabled", "GeolocationAPIEnabled", "NotificationsEnabled",
        "NotificationEventEnabled", "DeclarativeWebPush", "ServiceWorkersEnabled", "SpeechRecognitionEnabled", "WebShareEnabled",
        "WebShareFileAPIEnabled"
    ]

    /// Switches `disabledFeatures` off and returns the ones this WebKit has and now has off. WebKit offers the
    /// switches as SPI only; a macOS without one keeps the policy, the content rules and the bridge's own removals.
    @discardableResult
    static func restrict(_ preferences: WKPreferences) -> Set<String> {
        switchOffDNSPrefetching(preferences)
        let list = Selector(("_features")), set = Selector(("_setEnabled:forFeature:")), get = Selector(("_isEnabledForFeature:"))
        guard (WKPreferences.self as AnyObject).responds(to: list),
              let setMethod = class_getInstanceMethod(WKPreferences.self, set), let getMethod = class_getInstanceMethod(WKPreferences.self, get),
              let features = (WKPreferences.self as AnyObject).perform(list)?.takeUnretainedValue() as? [NSObject] else { return [] }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        typealias Getter = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let setEnabled = unsafeBitCast(method_getImplementation(setMethod), to: Setter.self)
        let isEnabled = unsafeBitCast(method_getImplementation(getMethod), to: Getter.self)
        var off: Set<String> = []
        for feature in features {
            guard let key = feature.value(forKey: "key") as? String, disabledFeatures.contains(key) else { continue }
            setEnabled(preferences, set, false, feature)
            if !isEnabled(preferences, get, feature) { off.insert(key) }
        }
        return off
    }

    /// WebKit's older DNS prefetching setting. A macOS whose WebKit has no `LinkDNSPrefetchEnabled` feature still has
    /// this one, so DNS prefetching is off there too.
    static func switchOffDNSPrefetching(_ preferences: WKPreferences) {
        let set = Selector(("_setDNSPrefetchingEnabled:"))
        guard let method = class_getInstanceMethod(WKPreferences.self, set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(preferences, set, false)
    }

    /// `info` is the JSON of `frog.info`.
    static func bridge(info: String) -> String {
        """
        (() => {
          "use strict";
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.frog;
          if (!handler) return;
          const post = handler.postMessage.bind(handler);
          const call = (name, args) => post({ name, args: args || {} });
          const describe = (value) => {
            if (value instanceof Error) return value.stack || String(value);
            if (typeof value === "string") return value;
            try { return JSON.stringify(value); } catch { return String(value); }
          };
          const log = (level, text) => { try { post({ name: "log", args: { level, text: String(text).slice(0, 4000) } }); } catch {} };
          for (const level of ["log", "info", "warn", "error", "debug"]) {
            const original = console[level].bind(console);
            console[level] = (...values) => { log(level, values.map(describe).join(" ")); original(...values); };
          }
          window.addEventListener("error", (event) => log("error", `${event.message} (${event.filename || "page"}:${event.lineno || 0})`));
          window.addEventListener("unhandledrejection", (event) => log("error", "Unhandled rejection: " + describe(event.reason)));

          // Events wait for their first listener, so a command that opened the page is not lost.
          const listeners = new Map();
          const waiting = new Map();
          const emit = (event, value) => {
            const handlers = listeners.get(event);
            if (!handlers || handlers.size === 0) {
              const queue = waiting.get(event) || [];
              if (queue.length < 20) queue.push(value);
              waiting.set(event, queue);
              return;
            }
            for (const handler of [...handlers]) {
              try { const result = handler(value); if (result && result.catch) result.catch((error) => log("error", describe(error))); }
              catch (error) { log("error", describe(error)); }
            }
          };
          Object.defineProperty(window, "__frogEmit", { value: emit, writable: false, configurable: false, enumerable: false });

          const fetchText = async (url, options = {}) => {
            const as = options.as || "text";
            const response = await call("fetch", {
              url: String(url), method: String(options.method || "GET"),
              headers: Object.fromEntries(Object.entries(options.headers || {}).map(([k, v]) => [String(k), String(v)])),
              body: options.body == null ? null : String(options.body), as: as === "base64" ? "base64" : "text"
            });
            if (as === "json") response.body = JSON.parse(response.body);
            return response;
          };

          const frog = Object.freeze({
            info: Object.freeze(\(info)),
            storage: Object.freeze({
              get: async (key) => { const text = await call("storage.get", { key: String(key) }); return text == null ? null : JSON.parse(text); },
              set: async (key, value) => { await call("storage.set", { key: String(key), json: JSON.stringify(value === undefined ? null : value) }); },
              remove: async (key) => { await call("storage.remove", { key: String(key) }); },
              keys: () => call("storage.keys")
            }),
            clipboard: Object.freeze({
              readText: async () => { const text = await call("clipboard.read"); return text == null ? null : text; },
              writeText: async (text) => { await call("clipboard.write", { text: String(text) }); }
            }),
            notify: (title, body = "", options = {}) => call("notify", {
              title: String(title), body: String(body),
              at: options.at == null ? null : Number(options.at instanceof Date ? options.at.getTime() : options.at),
              id: options.id == null ? null : String(options.id)
            }),
            cancelNotification: async (id) => { await call("notify.cancel", { id: String(id) }); },
            openURL: async (url) => { await call("openURL", { url: String(url) }); },
            fetch: fetchText,
            ai: (instructions, text = "") => call("ai", { instructions: String(instructions), text: String(text) }),
            run: (name, options = {}) => call("run", {
              name: String(name), args: (options.args || []).map(String), input: options.input == null ? null : String(options.input)
            }),
            on: (event, handler) => {
              if (typeof handler !== "function") throw new TypeError("frog.on needs a function");
              const name = String(event);
              if (!listeners.has(name)) listeners.set(name, new Set());
              listeners.get(name).add(handler);
              const queued = waiting.get(name);
              if (queued) { waiting.delete(name); setTimeout(() => queued.forEach((value) => emit(name, value)), 0); }
              return () => listeners.get(name).delete(handler);
            },
            show: async () => { await call("show"); },
            close: async () => { await call("close"); }
          });
          Object.defineProperty(window, "frog", { value: frog, writable: false, configurable: false, enumerable: true });

          // Peer connections reach the network without asking Frog, so the page has none. WebKit has them switched off
          // in every frame; this covers a WebKit without that switch, in the main frame.
          for (const name of ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel", "RTCRtpSender", "RTCRtpReceiver"]) {
            try { Object.defineProperty(window, name, { value: undefined, writable: false, configurable: false }); } catch {}
          }
        })();
        """
    }

    /// The theme's colours for light and dark, on :root so they win over the stylesheet's defaults.
    @MainActor static func themeStyle() -> String {
        func hex(_ color: Color, dark: Bool) -> String {
            var resolved = NSColor(color)
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
            }
            let red = Int((resolved.redComponent * 255).rounded()), green = Int((resolved.greenComponent * 255).rounded())
            let blue = Int((resolved.blueComponent * 255).rounded())
            return String(format: "#%02x%02x%02x", red, green, blue)
        }
        let roles: [(String, Color)] = [
            ("ink", FrogStyle.ink), ("muted", FrogStyle.muted), ("canvas", FrogStyle.opaqueCanvas), ("surface", FrogStyle.panelSurface),
            ("inset", FrogStyle.opaqueInset), ("border", FrogStyle.border), ("accent", FrogStyle.accent),
            ("good", FrogStyle.good), ("warning", FrogStyle.warning), ("critical", FrogStyle.critical)
        ]
        func block(dark: Bool) -> String {
            roles.map { "--frog-\($0.0):\(hex($0.1, dark: dark));" }.joined()
                + "--frog-font:-apple-system,BlinkMacSystemFont,\"Helvetica Neue\",sans-serif;"
        }
        return ":root{\(block(dark: false))color-scheme:light dark}@media (prefers-color-scheme: dark){:root{\(block(dark: true))}}"
    }

    /// Puts the theme's style into the page, replacing an earlier one.
    static func applyTheme(_ css: String) -> String {
        let literal = (try? String(data: JSONEncoder().encode(css), encoding: .utf8)) ?? "\"\""
        return """
        (() => {
          const apply = () => {
            let style = document.getElementById("frog-theme");
            if (!style) { style = document.createElement("style"); style.id = "frog-theme"; (document.head || document.documentElement).prepend(style); }
            style.textContent = \(literal);
          };
          if (document.documentElement) apply(); else document.addEventListener("readystatechange", apply, { once: true });
        })();
        """
    }

    /// Frog's own files under `/_frog/`.
    static func builtInFile(_ path: String) -> (data: Data, type: String)? {
        switch path {
        case "frog.css":
            guard let url = FrogResources.bundle.url(forResource: "frog-plugin", withExtension: "css"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return (data, "text/css")
        case "blank.html":
            // The page of a plugin with commands only, served like any other so it has the same policy.
            return (Data("<!doctype html><meta charset=\"utf-8\"><title></title>".utf8), "text/html")
        default: return nil
        }
    }

    static func mimeType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": "text/html"
        case "js", "mjs": "text/javascript"
        case "css": "text/css"
        case "json", "map": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "ico": "image/x-icon"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        case "txt", "md", "sh": "text/plain"
        case "wasm": "application/wasm"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "mp4": "video/mp4"
        default: "application/octet-stream"
        }
    }
}
