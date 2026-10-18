import XCTest
import AppKit
import SwiftUI
import FrogCore
@testable import FrogApp

/// Pictures of the real bubble panel, collapsed, hovered and expanded, in light and dark. It opens the panel on screen
/// and takes that window alone, so it runs only with `FROG_BUBBLE_SHOTS` set to the folder for the pictures.
@MainActor
final class SelectionBubbleShotsTests: XCTestCase {
    private static let shortcut = Hotkey(keyCode: 8, modifiers: 4096 | 512)
    private static let items = [
        BubbleItem(id: UUID(), title: "Explain", symbol: SelectionBubbleItems.answerSymbol, answers: true, hotkey: Hotkey(keyCode: 14, modifiers: 4096 | 2048)),
        BubbleItem(id: UUID(), title: "Define", symbol: SelectionBubbleItems.answerSymbol, answers: true),
        BubbleItem(id: UUID(), title: "Proofread", symbol: SelectionBubbleItems.writingSymbol, answers: false, hotkey: shortcut),
        BubbleItem(id: UUID(), title: "Polish email", symbol: SelectionBubbleItems.writingSymbol, answers: false),
        BubbleItem(id: UUID(), title: "Translate to German", symbol: SelectionBubbleItems.writingSymbol, answers: false,
                   hotkey: Hotkey(keyCode: 5, modifiers: 4096 | 512)),
    ]
    private static let long = [
        BubbleItem(id: UUID(), title: "Explain like I am new to this field", symbol: SelectionBubbleItems.answerSymbol, answers: true),
        BubbleItem(id: UUID(), title: "Summarize", symbol: SelectionBubbleItems.answerSymbol, answers: true),
        BubbleItem(id: UUID(), title: "Rewrite as a friendly but firm reply to a customer", symbol: SelectionBubbleItems.writingSymbol,
                   answers: false, hotkey: shortcut),
        BubbleItem(id: UUID(), title: "Shorten", symbol: SelectionBubbleItems.writingSymbol, answers: false),
    ]
    private static let many = items + (1...24).map {
        BubbleItem(id: UUID(), title: "Writing rule \($0)", symbol: SelectionBubbleItems.writingSymbol, answers: false,
                   hotkey: $0.isMultiple(of: 3) ? shortcut : nil)
    }

    func testTheBubbleInEachState() async throws {
        let folder = try Self.folder()
        let items = Self.items
        let few = Array(items.prefix(3))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
            let name = appearance == .aqua ? "light" : "dark"
            let controller = SelectionBubbleController()
            let anchor = CGRect(x: 400, y: 500, width: 0, height: 16)
            controller.show(visible: few, more: [], anchor: anchor, pointer: anchor.origin)
            try await shoot(controller, "\(folder)/\(name)-bar.png")
            controller.hover.location = CGPoint(x: 100, y: 17)
            try await shoot(controller, "\(folder)/\(name)-bar-hover.png")
            controller.show(visible: Array(items.prefix(3)), more: Array(items.dropFirst(3)), anchor: anchor, pointer: anchor.origin)
            try await shoot(controller, "\(folder)/\(name)-bar-more.png")
            controller.expand()
            controller.hover.location = CGPoint(x: 60, y: 80)
            try await shoot(controller, "\(folder)/\(name)-list.png")
            controller.show(visible: Array(Self.long.prefix(3)), more: Array(Self.long.dropFirst(3)), anchor: anchor, pointer: anchor.origin)
            try await shoot(controller, "\(folder)/\(name)-long-bar.png")
            controller.expand()
            try await shoot(controller, "\(folder)/\(name)-long-list.png")
            controller.show(visible: Array(Self.many.prefix(3)), more: Array(Self.many.dropFirst(3)), anchor: anchor, pointer: anchor.origin)
            controller.expand()
            controller.hover.location = CGPoint(x: 60, y: 200)
            try await shoot(controller, "\(folder)/\(name)-many-list.png")
            controller.hide()
        }
        NSApplication.shared.appearance = nil
    }

    /// Near each edge of the display the list stays on it, grows away from the selection and never covers it, also
    /// when the selection has several lines.
    func testTheListStaysOnScreenBesideTheSelection() async throws {
        let folder = try Self.folder()
        let screen = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let controller = SelectionBubbleController()
        let anchors = [
            "bottom": CGRect(x: screen.midX, y: screen.minY + 30, width: 0, height: 16),
            "top": CGRect(x: screen.midX, y: screen.maxY - 30, width: 0, height: 16),
            "right": CGRect(x: screen.maxX - 20, y: screen.midY, width: 0, height: 16),
            "middle": CGRect(x: screen.midX, y: screen.midY, width: 0, height: 16),
            // Six lines, as `SelectionAnchor.end` spans them.
            "lines-bottom": CGRect(x: screen.midX, y: screen.minY + 200, width: 0, height: 96),
            "lines-top": CGRect(x: screen.midX, y: screen.maxY - 130, width: 0, height: 96),
        ]
        for (name, anchor) in anchors.sorted(by: { $0.key < $1.key }) {
            for (count, items) in [("few", Self.items), ("many", Self.many)] {
                controller.show(visible: Array(items.prefix(3)), more: Array(items.dropFirst(3)), anchor: anchor, pointer: anchor.origin)
                let bar = try XCTUnwrap(controller.frame)
                controller.expand()
                let list = try XCTUnwrap(controller.frame)
                XCTAssertTrue(screen.contains(list), "\(name) \(count): \(list) leaves \(screen)")
                XCTAssertFalse(list.intersects(anchor), "\(name) \(count): \(list) covers the selection")
                XCTAssertTrue(bar.minY >= anchor.maxY || bar.maxY <= anchor.minY, "\(name) \(count): \(bar) covers the selection")
                XCTAssertLessThanOrEqual(list.height, SelectionBubbleController.listMaxHeight + 0.5)
                if count == "many" { try await shoot(controller, "\(folder)/edge-\(name).png") }
            }
        }
        controller.hide()
    }

    /// A click on a row reaches it while another app stays active, in a list that scrolls as in one that does not.
    func testAClickOnAListRowChoosesIt() async throws {
        _ = try Self.folder()
        let controller = SelectionBubbleController()
        var chosen: [String] = []
        controller.onSelect = { chosen.append($0.title) }
        let anchor = CGRect(x: 400, y: 600, width: 0, height: 16)
        for items in [Self.items, Self.many] {
            controller.show(visible: Array(items.prefix(3)), more: Array(items.dropFirst(3)), anchor: anchor, pointer: anchor.origin)
            controller.expand()
            try await Task.sleep(for: .milliseconds(300))
            let window = try XCTUnwrap(NSApplication.shared.windows.first { $0.windowNumber == controller.windowNumber })
            XCTAssertFalse(window.isKeyWindow)
            let wasActive = NSApplication.shared.isActive
            // The first row under the Answer heading, Explain.
            let point = CGPoint(x: 60, y: window.frame.height - 44)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                window.sendEvent(event)
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertFalse(window.isKeyWindow, "the bubble never becomes key")
            XCTAssertEqual(NSApplication.shared.isActive, wasActive, "choosing a row does not activate Frog")
        }
        XCTAssertEqual(chosen, ["Explain", "Explain"])
        controller.hide()
    }

    /// The Explain page with the bubble on, drawn without a window: the rule left out of the bubble marked in its row,
    /// in light and dark.
    func testTheExplainPageWithTheBubbleOn() async throws {
        let folder = try Self.folder()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await Self.explainModel(directory: directory, accessibility: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: ExplainView().environmentObject(model).frame(width: 760, height: 2_400)
                .background(FrogStyle.opaqueCanvas))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 2_400)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let name = appearance == .aqua ? "light" : "dark"
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "\(folder)/\(name)-explain-page.png"))
        }
    }

    // MARK: Explain

    private static let longAnswer = """
    **Idempotent** means that doing something more than once has the same effect as doing it once. In this context it \
    describes an API request: if the connection drops and the app sends the same request again, the server does not \
    create a second order or charge the card twice.

    For example, setting a value to 5 is idempotent, while adding 5 to it is not. Developers make retries safe by \
    sending a unique request ID that the server remembers.
    """
    private static let shortAnswer = """
    Doing it again changes nothing: a request sent twice has the same effect as one. Here it makes retries safe, so a \
    dropped connection never creates a second order.
    """

    /// The answer panel in each state, from fixture answers, drawn without a window in light and dark. Runs only with
    /// `FROG_EXPLAIN_SHOTS` set to the folder for the pictures.
    func testTheAnswerPanelInEachState() async throws {
        let folder = try Self.folder("FROG_EXPLAIN_SHOTS")
        func session(_ change: (inout AnswerSession) throws -> Void) rethrows -> AnswerSession {
            var session = AnswerSession(rule: Rule.explainPreset, modelName: "gpt-5-mini", modelLabel: "gpt-5-mini · OpenAI",
                                        selection: "Requests must be idempotent so that retries are safe.", context: nil,
                                        application: "Safari", source: nil, replyLanguage: "English")
            try change(&session)
            return session
        }
        func answered(_ text: String) -> (inout AnswerSession) -> Void {
            { $0.apply(.text(text)); $0.complete() }
        }
        let states: [(String, AnswerSession, (AnswerPanelModel) -> Void)] = [
            ("answer", session(answered(Self.longAnswer)), { $0.offersNotes = true; $0.canSaveNote = true }),
            ("short", session(answered(Self.shortAnswer)), { _ in }),
            ("streaming", session { $0.apply(.text(String(Self.shortAnswer.prefix(70)))) }, { _ in }),
            ("waiting", session { _ in }, { _ in }),
            ("failed", session { $0.fail("Ollama is not running. Start it and try again.") }, { $0.recovery = .retry }),
            ("follow-up", try session { session in
                answered(Self.shortAnswer)(&session)
                try session.beginFollowUp("Is a GET request idempotent?", instructions: Rule.explainInstructions)
                session.apply(.text("Yes. A GET only reads, so sending it twice leaves everything as it was."))
                session.complete()
            }, { $0.offersNotes = true; $0.canSaveNote = true; $0.noteState = .saved; $0.copied = true; $0.pinned = true }),
        ]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let name = appearance == .aqua ? "light" : "dark"
            for (state, session, configure) in states {
                let model = AnswerPanelModel()
                model.session = session
                configure(model)
                var height: CGFloat = 0
                model.heightChanged = { height = $0 }
                // Measured once, then drawn at the height the panel asks for.
                _ = try await render(AnswerPanelView(model: model), width: AnswerPanelController.width, height: 700,
                                     appearance: appearance)
                let png = try await render(AnswerPanelView(model: model), width: AnswerPanelController.width,
                                           height: max(height, 60), appearance: appearance)
                try png.write(to: URL(fileURLWithPath: "\(folder)/panel-\(state)-\(name).png"))
            }
        }
    }

    /// The Explain page with the bubble on, with and without Accessibility and with its Options open, drawn without a
    /// window in light and dark. Runs only with `FROG_EXPLAIN_SHOTS` set to the folder for the pictures.
    func testTheExplainPage() async throws {
        let folder = try Self.folder("FROG_EXPLAIN_SHOTS")
        for (state, trusted, options) in [("page", true, false), ("page-no-access", false, false), ("page-options", true, true)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let model = try await Self.explainModel(directory: directory, accessibility: trusted)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let name = appearance == .aqua ? "light" : "dark"
                let page = ExplainView(showsBubbleOptions: options).environmentObject(model)
                let png = try await render(page, width: 760, height: options ? 940 : 620, appearance: appearance)
                try png.write(to: URL(fileURLWithPath: "\(folder)/\(state)-\(name).png"))
            }
        }
    }

    /// The editor of a Writing rule left out of the bubble, with its switch, drawn without a window in light and dark.
    /// Runs only with `FROG_EXPLAIN_SHOTS` set to the folder for the pictures.
    func testTheRuleEditorChoosesItsPlaceInTheBubble() async throws {
        let folder = try Self.folder("FROG_EXPLAIN_SHOTS")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await Self.explainModel(directory: directory, accessibility: true)
        let hidden = try XCTUnwrap(model.configuration.preferences.explainSettings.bubbleHiddenRules.first)
        let rule = try XCTUnwrap(model.configuration.rules.first { $0.id == hidden })
        XCTAssertTrue(model.ruleLeftOutOfBubble(rule))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let name = appearance == .aqua ? "light" : "dark"
            let png = try await render(RuleEditor(rule: rule).environmentObject(model), width: 520, height: 460, appearance: appearance)
            try png.write(to: URL(fileURLWithPath: "\(folder)/editor-\(name).png"))
        }
    }

    /// An isolated model with Explain on, an Explain rule on a local server, an answer rule without a model, the bubble on
    /// and one Writing rule left out of it.
    private static func explainModel(directory: URL, accessibility: Bool) async throws -> AppModel {
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil }, readAccessibility: { accessibility },
                             selectionWatcher: StubSelectionWatcher(), systemStatusTick: { try await Task.sleep(for: .seconds(3_600)) })
        try model.saveProvider(ProviderConfiguration(kind: .ollama), apiKey: nil, clearKey: false)
        try await model.setFeature(.explain, enabled: true)
        var explain = try XCTUnwrap(model.configuration.rules.first { $0.answersInPanel })
        explain.providerID = model.configuration.providers[0].id
        try model.saveRule(explain)
        var define = Rule(name: "Define", instructions: "Define the selected term.")
        define.action = RuleAction(category: .text)
        define.action?.textOutput = .panel
        try model.saveRule(define)
        let writing = model.configuration.rules.filter { $0.enabled && $0.category == .text && !$0.answersInPanel }
        try model.updateToolkit { toolkit in
            var settings = toolkit.explain ?? ExplainSettings()
            settings.selectionBubble = true
            settings.bubbleHiddenRules = Array(writing.prefix(1).map(\.id))
            toolkit.explain = settings
        }
        return model
    }

    /// Draws a view into a bitmap without a window, on a plain backdrop so a panel's edge shows.
    private func render<Content: View>(_ view: Content, width: CGFloat, height: CGFloat, appearance: NSAppearance.Name) async throws -> Data {
        let margin: CGFloat = 16
        let size = NSSize(width: width + margin * 2, height: height + margin * 2)
        let host = NSHostingView(rootView: view.frame(width: width, height: height).padding(margin)
            .background(appearance == .aqua ? Color(white: 0.86) : Color(white: 0.16)))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private static func folder(_ variable: String = "FROG_BUBBLE_SHOTS") throws -> String {
        guard let folder = ProcessInfo.processInfo.environment[variable] else {
            throw XCTSkip("Set \(variable) to a folder to take these pictures")
        }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return folder
    }

    private func shoot(_ controller: SelectionBubbleController, _ path: String) async throws {
        try await Task.sleep(for: .milliseconds(400))
        let number = try XCTUnwrap(controller.windowNumber)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l\(number)", path]
        try capture.run()
        capture.waitUntilExit()
        XCTAssertEqual(capture.terminationStatus, 0)
    }
}

@MainActor
private final class StubSelectionWatcher: SelectionWatching {
    private(set) var isRunning = false
    func start() { isRunning = true }
    func stop() { isRunning = false }
    func dismiss() {}
}
