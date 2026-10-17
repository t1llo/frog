import AppKit
import ApplicationServices
import FrogCore

/// Reads another app's selection through Accessibility only. It never copies, never touches the clipboard and never
/// sends key events, so it can run without the person asking.
protocol SelectionReading: Sendable {
    func read(pid: pid_t, maxCharacters: Int, includeContext: Bool) async -> SelectionReadResult
    /// Asks the app to expose its text to Accessibility. Chrome, Chromium browsers such as Helium and Arc, and
    /// Electron apps such as Slack and VS Code keep their text hidden until an assistive app asks, so the bubble
    /// found no selection there. True when the app took the request.
    func exposeText(pid: pid_t) async -> Bool
}

extension SelectionReading {
    func exposeText(pid: pid_t) async -> Bool { false }
}

/// The Accessibility calls a selection read makes. The live source hands out `AXUIElement`s; tests hand out their own
/// objects, so elements are opaque here.
struct SelectionAXSource: @unchecked Sendable {
    typealias Element = AnyObject
    /// Every element below gets the same messaging timeout as the application it came from.
    var application: @Sendable (pid_t) -> Element?
    var focused: @Sendable (Element) -> Element?
    var window: @Sendable (Element) -> Element?
    var parent: @Sendable (Element) -> Element?
    var role: @Sendable (Element) -> String?
    var subrole: @Sendable (Element) -> String?
    var string: @Sendable (Element, String) -> String?
    var attribute: @Sendable (Element, String) -> CFTypeRef?
    var range: @Sendable (Element) -> CFRange?
    var count: @Sendable (Element) -> Int?
    /// Only the given part of the element's text.
    var substring: @Sendable (Element, CFRange) -> String?
    /// Accessibility coordinates: origin at the top left of the primary display.
    var bounds: @Sendable (Element, CFRange) -> CGRect?
    var parameterized: @Sendable (Element, String, CFTypeRef) -> CFTypeRef?
    var url: @Sendable (Element, String) -> URL?
    var hash: @Sendable (Element) -> Int
    var isEditable: @Sendable (Element) -> Bool
    var bundleID: @Sendable (pid_t) -> String?
    var applicationName: @Sendable (pid_t) -> String?
    /// Screen frames in Cocoa coordinates, read once on the main actor before a read.
    var screens: @MainActor @Sendable () -> [CGRect]
    /// The primary display's height, which is safe to ask for off the main thread.
    var primaryHeight: @Sendable () -> CGFloat
}

extension SelectionAXSource {
    /// Longest wait for one answer from the other app. A read runs after a gesture or a shortcut, so a busy app
    /// costs a quarter of a second per call at most instead of the system's much longer default.
    static let timeout: Float = 0.25

    static let live = SelectionAXSource(
        application: { pid in
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, timeout)
            return application
        },
        focused: { derived($0, kAXFocusedUIElementAttribute) },
        window: { derived($0, kAXFocusedWindowAttribute) },
        parent: { derived($0, kAXParentAttribute) },
        role: { AXRead.string(ax($0), kAXRoleAttribute) },
        subrole: { AXRead.string(ax($0), kAXSubroleAttribute) },
        string: { AXRead.string(ax($0), $1) },
        attribute: { AXRead.attribute(ax($0), $1) },
        range: { AXRead.range(ax($0)) },
        count: { AXRead.numberOfCharacters(ax($0)) },
        substring: { AXRead.string(ax($0), range: $1) },
        bounds: { AXRead.bounds(ax($0), range: $1) },
        parameterized: { element, name, parameter in
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(ax(element), name as CFString, parameter, &result) == .success
            else { return nil }
            return result
        },
        url: { AXRead.url(ax($0), $1) },
        hash: { Int(bitPattern: CFHash(ax($0))) },
        isEditable: { AXRead.isEditable(ax($0)) },
        bundleID: { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier },
        applicationName: { NSRunningApplication(processIdentifier: $0)?.localizedName },
        screens: { NSScreen.screens.map(\.frame) },
        primaryHeight: { CGDisplayBounds(CGMainDisplayID()).height })

    private static func ax(_ element: Element) -> AXUIElement { element as! AXUIElement }

    private static func derived(_ element: Element, _ name: String) -> Element? {
        AXRead.element(ax(element), name, timeout: timeout)
    }
}

/// Reads on its own serial queue, never on the main thread: an Accessibility call waits for the other app.
final class SelectionReader: SelectionReading {
    private let source: SelectionAXSource
    private let queue: DispatchQueue

    init(source: SelectionAXSource = .live,
         queue: DispatchQueue = DispatchQueue(label: "frog.selection-reader", qos: .userInitiated)) {
        self.source = source
        self.queue = queue
    }

    /// The attribute Chromium and Electron read as "an assistive app is here", without the window side effects of
    /// the enhanced-interface attribute that VoiceOver sets.
    static let manualAccessibility = "AXManualAccessibility"

    func exposeText(pid: pid_t) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let application = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(application, SelectionAXSource.timeout)
                let result = AXUIElementSetAttributeValue(application, Self.manualAccessibility as CFString, kCFBooleanTrue)
                continuation.resume(returning: result == .success)
            }
        }
    }

    func read(pid: pid_t, maxCharacters: Int, includeContext: Bool) async -> SelectionReadResult {
        let source = source
        let screens = await MainActor.run { source.screens() }
        return await withCheckedContinuation { continuation in
            queue.async {
                let pass = SelectionReadPass(source: source, pid: pid, screens: screens, primaryHeight: source.primaryHeight())
                continuation.resume(returning: pass.run(maxCharacters: maxCharacters, includeContext: includeContext))
            }
        }
    }
}

/// One read, on the reader's queue.
private struct SelectionReadPass {
    typealias Element = SelectionAXSource.Element
    let source: SelectionAXSource
    let pid: pid_t
    let screens: [CGRect]
    let primaryHeight: CGFloat

    /// The most text read whole to find the context, in UTF-16 units.
    static let valueReadLimit = 200_000

    func run(maxCharacters: Int, includeContext: Bool) -> SelectionReadResult {
        guard let application = source.application(pid), let focused = source.focused(application) else { return .unavailable }
        let range = source.range(focused)
        let step = SelectionReadDecision.attributes(role: source.role(focused), subrole: source.subrole(focused),
                                                    range: range.map { (location: $0.location, length: $0.length) },
                                                    maxCharacters: maxCharacters)
        switch step {
        case .secure: return .secure
        case .empty: return .empty
        case .tooLong(let length): return .tooLong(length)
        case .tryMarkers:
            return markers(focused: focused, application: application, maxCharacters: maxCharacters, includeContext: includeContext)
        case .readAttributes:
            if let range, let snapshot = attributes(focused, range: range, application: application, includeContext: includeContext) {
                return .selection(snapshot)
            }
            // A range without readable text: a web view may still hold the selection in text markers.
            return markers(focused: focused, application: application, maxCharacters: maxCharacters, includeContext: includeContext)
        }
    }

    // MARK: Path A: text attributes

    private func attributes(_ element: Element, range: CFRange, application: Element, includeContext: Bool) -> SelectionSnapshot? {
        guard let text = selectedText(element, range: range), !text.isEmpty else { return nil }
        let union = rect(source.bounds(element, range))
        let last = rect(source.bounds(element, CFRange(location: range.location + range.length - 1, length: 1)))
        return snapshot(text: text, union: union, last: last,
                        context: includeContext ? context(element, range: range) : nil,
                        holder: element, focused: element, application: application,
                        location: range.location, length: range.length)
    }

    private func selectedText(_ element: Element, range: CFRange) -> String? {
        if let text = source.string(element, kAXSelectedTextAttribute), !text.isEmpty { return text }
        if let text = source.substring(element, range), !text.isEmpty { return text }
        // The whole value only when it is known to be small enough.
        guard let count = source.count(element), count <= Self.valueReadLimit,
              let value = source.string(element, kAXValueAttribute) else { return nil }
        return AXRead.substring(value, range: range)
    }

    /// The same window as a captured selection's context: 1,500 units on either side, or the whole value when the
    /// app cannot give a part and the value is small enough.
    private func context(_ element: Element, range: CFRange) -> String? {
        guard let count = source.count(element) else { return nil }
        let span = ContextWindow.range(selection: (range.location, range.length), count: count, margin: 1_500)
        var window: String?, start = span.location
        if span.length > 0, span.length <= Self.valueReadLimit {
            window = source.substring(element, CFRange(location: span.location, length: span.length))
        }
        if window == nil, count <= Self.valueReadLimit, let value = source.string(element, kAXValueAttribute) {
            window = value; start = 0
        }
        guard let window, range.location >= start else { return nil }
        return SurroundingText.around(selection: NSRange(location: range.location - start, length: range.length), in: window)
    }

    // MARK: Path B: text markers (WebKit, and Chromium while its accessibility is on)

    private func markers(focused: Element, application: Element, maxCharacters: Int, includeContext: Bool) -> SelectionReadResult {
        guard let (holder, markerRange) = selectedMarkers(from: focused) else { return .unavailable }
        let text = source.parameterized(holder, "AXStringForTextMarkerRange", markerRange) as? String
        if let decided = SelectionReadDecision.markers(textLength: text.map { ($0 as NSString).length },
                                                       maxCharacters: maxCharacters) {
            return decided
        }
        guard let text else { return .unavailable }
        let union = rect(markerBounds(holder, markerRange))
        // Without a last-character range, the bottom right corner of the selection.
        let last = rect(lastCharacterBounds(holder, markerRange))
            ?? union.map { CGRect(x: $0.maxX, y: $0.minY, width: 0, height: 0) }
        return .selection(snapshot(text: text, union: union, last: last,
                                   context: includeContext ? markerContext(holder, range: markerRange, text: text) : nil,
                                   holder: holder, focused: focused, application: application,
                                   location: 0, length: (text as NSString).length))
    }

    /// The selected marker range of the focused element, or of its nearest web area within eight parents.
    private func selectedMarkers(from focused: Element) -> (Element, CFTypeRef)? {
        if let range = source.attribute(focused, "AXSelectedTextMarkerRange") { return (focused, range) }
        var current = focused
        for _ in 0..<8 {
            guard let parent = source.parent(current) else { return nil }
            if source.role(parent) == "AXWebArea" {
                return source.attribute(parent, "AXSelectedTextMarkerRange").map { (parent, $0) }
            }
            current = parent
        }
        return nil
    }

    private func markerBounds(_ holder: Element, _ range: CFTypeRef) -> CGRect? {
        source.parameterized(holder, "AXBoundsForTextMarkerRange", range).flatMap(Self.rectValue)
    }

    private func lastCharacterBounds(_ holder: Element, _ range: CFTypeRef) -> CGRect? {
        guard let end = source.parameterized(holder, "AXEndTextMarkerForTextMarkerRange", range),
              let previous = source.parameterized(holder, "AXPreviousTextMarkerForTextMarker", end),
              let last = source.parameterized(holder, "AXTextMarkerRangeForUnorderedTextMarkers", [previous, end] as CFArray)
        else { return nil }
        return markerBounds(holder, last)
    }

    /// The paragraph where the selection starts, when the app can give it.
    private func markerContext(_ holder: Element, range: CFTypeRef, text: String) -> String? {
        guard let start = source.parameterized(holder, "AXStartTextMarkerForTextMarkerRange", range),
              let paragraphRange = source.parameterized(holder, "AXParagraphTextMarkerRangeForTextMarker", start),
              let paragraph = source.parameterized(holder, "AXStringForTextMarkerRange", paragraphRange) as? String,
              (paragraph as NSString).length <= Self.valueReadLimit else { return nil }
        let found = (paragraph as NSString).range(of: text)
        guard found.location != NSNotFound else { return nil }
        return SurroundingText.around(selection: found, in: paragraph)
    }

    // MARK: Snapshot

    private func snapshot(text: String, union: CGRect?, last: CGRect?, context: String?, holder: Element, focused: Element,
                          application: Element, location: Int, length: Int) -> SelectionSnapshot {
        SelectionSnapshot(
            text: text, bounds: SelectionAnchor.choose(union: union, last: last, screenHeight: screenHeight(showing: union)),
            endBounds: last, context: context, source: address(holder, application: application),
            isEditable: source.isEditable(focused), pid: pid, bundleID: source.bundleID(pid),
            applicationName: source.applicationName(pid),
            fingerprint: SelectionFingerprint(pid: pid, element: source.hash(holder), location: location, length: length,
                                              textHash: text.hashValue))
    }

    /// The focused window's document, else the address of the web area that holds the selection.
    private func address(_ element: Element, application: Element) -> String? {
        if let window = source.window(application), let document = source.url(window, kAXDocumentAttribute),
           let address = SourceAddress.clean(document) {
            return address
        }
        var current: Element? = element
        for _ in 0...8 {
            guard let candidate = current else { return nil }
            if source.role(candidate) == "AXWebArea" { return source.url(candidate, "AXURL").flatMap(SourceAddress.clean) }
            current = source.parent(candidate)
        }
        return nil
    }

    private func rect(_ axRect: CGRect?) -> CGRect? {
        axRect.flatMap { AXGeometry.cocoaRect($0, primaryHeight: primaryHeight, screens: screens) }
    }

    /// The height of the screen that shows most of the selection.
    private func screenHeight(showing union: CGRect?) -> CGFloat {
        let screen = union.flatMap { union in
            screens.max { lhs, rhs in
                let a = lhs.intersection(union), b = rhs.intersection(union)
                return a.width * a.height < b.width * b.height
            }
        }
        return screen?.height ?? primaryHeight
    }

    private static func rectValue(_ raw: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        var rect = CGRect.zero
        return AXValueGetType(value) == .cgRect && AXValueGetValue(value, .cgRect, &rect) ? rect : nil
    }
}
