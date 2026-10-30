import FrogAgent
import FrogCore
import XCTest
@testable import FrogApp

/// The window and app commands, through fixture windows and apps: nothing on the Mac moves,
/// opens or comes forward.
@MainActor final class AgentWindowCommandsTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!
    private var access: FixtureWindowAccess!
    private var trusted = true
    private var frontmost: pid_t? = 102
    private var focused: [UInt32] = []
    private var opened: [URL] = []

    /// A 1440×900 display with a 25 pt menu bar, and one to its right.
    private let laptop = WindowDisplay(id: "laptop", name: "Built-in Display", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                       visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 875))
    private let monitor = WindowDisplay(id: "monitor", name: "Studio Display", frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440),
                                        visibleFrame: CGRect(x: 1440, y: 25, width: 2560, height: 1415))
    private let safari = AgentApp(name: "Safari", bundleId: "com.apple.Safari", pid: 101, active: false, hidden: false,
                                  url: URL(fileURLWithPath: "/Applications/Safari.app"))
    private let terminal = AgentApp(name: "Terminal", bundleId: "com.apple.Terminal", pid: 102, active: true, hidden: false,
                                    url: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    private let docs = WindowKey(pid: 101, number: 4512)
    private let mail = WindowKey(pid: 101, number: 4513)
    private let shell = WindowKey(pid: 102, number: 7001)
    private let docsFrame = CGRect(x: 100, y: 100, width: 800, height: 600)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try makeModel(Configuration())
        access = FixtureWindowAccess()
        access.add(mail, frame: CGRect(x: 300, y: 300, width: 700, height: 500))
        access.add(docs, frame: docsFrame)
        access.add(shell, frame: CGRect(x: 1600, y: 100, width: 900, height: 700))
        AgentCommands.desktop = fixtureDesktop()
    }

    override func tearDown() async throws {
        AgentCommands.desktop = AgentDesktop()
        model.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel(_ configuration: Configuration) throws {
        model?.shutdown()
        try ConfigurationStore(directory: directory).save(configuration)
        // config.toml decides which plugins are on once it exists; start from the configuration given.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("config.toml"))
        model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil })
    }

    /// Safari's "Docs" is focused in Safari, in front of "Mail"; Terminal's window is on the second display.
    private func fixtureDesktop() -> AgentDesktop {
        let access = access!, displays = [laptop, monitor]
        let windows: [(app: AgentApp, key: WindowKey, title: String, appFocused: Bool)] = [
            (terminal, shell, "zsh", true), (safari, docs, "Docs", true), (safari, mail, "Mail", false)
        ]
        var desktop = AgentDesktop()
        desktop.isTrusted = { [unowned self] in trusted }
        desktop.apps = { [unowned self] in [safari, terminal] }
        desktop.frontmost = { [unowned self] in frontmost }
        desktop.windows = { apps, displays, frontmost in
            windows.filter { entry in apps.contains { $0.pid == entry.app.pid } }.compactMap { entry in
                let handle = WindowHandle(key: entry.key, element: nil)
                guard let frame = access.frame(of: handle) else { return nil }
                return AgentWindow(app: entry.app.name, title: entry.title, frame: frame,
                                   display: AgentDesktop.displayNumber(of: frame, in: displays), minimized: access.state(of: handle).minimized,
                                   hidden: entry.app.hidden, focused: entry.appFocused && entry.app.pid == frontmost, appFocused: entry.appFocused,
                                   handle: handle, number: entry.key.number)
            }
        }
        desktop.displays = { displays }
        desktop.macOS = { MacWindowManagerSettings() }
        desktop.manager = WindowManager(access: access)
        desktop.focus = { [unowned self] window in focused.append(window.id); return true }
        desktop.findApp = { $0.lowercased() == "notes" ? URL(fileURLWithPath: "/System/Applications/Notes.app") : nil }
        desktop.open = { [unowned self] url in opened.append(url) }
        return desktop
    }

    private func run(_ words: String..., json: Bool = false) async -> AgentResponse {
        await AgentCommands.run(AgentRequest(arguments: words, json: json, directory: directory.path), model: model)
    }

    private func object(_ response: AgentResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.output.utf8)) as? [String: Any], response.error)
    }

    func testLayoutNamesRoundTrip() async throws {
        for action in WindowAction.allCases {
            XCTAssertEqual(WindowAction.agentNamed(action.agentName), action)
            XCTAssertEqual(WindowAction.agentNamed(action.rawValue), action)
            XCTAssertFalse(action.agentName.contains(where: \.isUppercase))
        }
        XCTAssertEqual(WindowAction.leftHalf.agentName, "left-half")
        XCTAssertEqual(WindowAction.topRight.agentName, "top-right")
        XCTAssertEqual(WindowAction.centeredLarge.agentName, "centered-large")
        XCTAssertEqual(WindowAction.nextDisplay.agentName, "next-display")
        XCTAssertEqual(WindowAction.agentNamed("Left Half"), .leftHalf)
        let layouts = await run("windows", "layouts", json: true)
        let names = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(layouts.output.utf8)) as? [[String: String]])
        XCTAssertEqual(names.compactMap { $0["name"] }, WindowAction.allCases.map(\.agentName))
    }

    func testWrongArgumentsAreUsageErrors() async {
        for words in [["windows", "layout", "sideways"], ["windows", "layout"],
                      ["windows", "layout", "left-half", "--window", "4512", "--app", "Safari"],
                      ["windows", "layout", "left-half", "--window", "four"], ["windows", "layout", "left-half", "--window", "-3"],
                      ["windows", "move", "--app", "Safari"], ["windows", "move", "--x", "left"], ["windows", "move", "--width", "0"],
                      ["windows", "move", "--height", "nan"], ["windows", "focus"], ["windows", "focus", "4512", "--window", "4513"],
                      // A mistyped id must not fall back to the window in front.
                      ["windows", "layout", "left-half", "4512", "extra"], ["windows", "move", "4512", "10", "--x", "5"],
                      ["windows", "layout", "left-half", "4512", "--window", "4513"], ["windows", "focus", "4512", "4513"],
                      ["apps", "open"]] {
            let response = await AgentCommands.run(AgentRequest(arguments: words), model: model)
            XCTAssertEqual(response.exitCode, AgentExit.usage, "\(words): \(response.error)")
        }
        XCTAssertEqual(access.writes, [])
        XCTAssertEqual(focused, [])
    }

    func testWithoutAccessibilityTheCommandsSayWhereToAllowIt() async {
        trusted = false
        for words in [["windows", "list"], ["windows", "layout", "left-half"], ["windows", "focus", "4512"]] {
            let response = await AgentCommands.run(AgentRequest(arguments: words), model: model)
            XCTAssertEqual(response.exitCode, AgentExit.failure, "\(words)")
            XCTAssertTrue(response.error.contains("Privacy & Security → Accessibility"), response.error)
        }
        XCTAssertEqual(access.writes, [])
    }

    func testListGivesIdsFramesDisplaysAndFocus() async throws {
        let text = await run("windows", "list")
        XCTAssertEqual(text.exitCode, 0, text.error)
        XCTAssertTrue(text.output.contains("4512  Safari"), text.output)
        XCTAssertTrue(text.output.contains("800×600 at 100, 100"), text.output)
        let json = await run("windows", "list", "--app", "safari", json: true)
        let windows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [[String: Any]])
        XCTAssertEqual(windows.compactMap { $0["id"] as? Int }, [4512, 4513])
        let first = try XCTUnwrap(windows.first)
        XCTAssertEqual(Set(first.keys), ["id", "app", "pid", "title", "frame", "display", "minimized", "hidden", "focused"])
        XCTAssertEqual(first["frame"] as? [String: Int], ["x": 100, "y": 100, "width": 800, "height": 600])
        XCTAssertEqual(first["focused"] as? Bool, false, "Terminal is in front")
        let all = await run("windows", "list", json: true)
        let terminalWindow = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(all.output.utf8)) as? [[String: Any]])?.first { $0["id"] as? Int == 7001 })
        XCTAssertEqual(terminalWindow["display"] as? Int, 2)
        XCTAssertEqual(terminalWindow["focused"] as? Bool, true)
    }

    func testWindowsAreOrderedFrontToBackWithUnlistedOnesLast() {
        func window(_ number: CGWindowID) -> AgentWindow {
            AgentWindow(app: "App", title: "\(number)", frame: docsFrame, display: 1, minimized: false, hidden: false,
                        handle: WindowHandle(key: WindowKey(pid: 1, number: number), element: nil), number: number)
        }
        let ordered = AgentDesktop.frontToBack([window(1), window(2), window(3), window(4)], order: [3: 0, 1: 5])
        XCTAssertEqual(ordered.map(\.id), [3, 1, 2, 4])
        XCTAssertEqual(AgentDesktop.displayNumber(of: CGRect(x: 2000, y: 200, width: 400, height: 300), in: [laptop, monitor]), 2)
    }

    func testLayoutArrangesTheFocusedWindowOfTheAppInFrontAndRestoreReturnsIt() async throws {
        frontmost = 101
        let moved = await run("windows", "layout", "left-half")
        XCTAssertEqual(moved.exitCode, 0, moved.error)
        XCTAssertEqual(moved.output, "Moved Safari — “Docs” to the left half.")
        XCTAssertEqual(access.frame(of: WindowHandle(key: docs, element: nil)), CGRect(x: 0, y: 25, width: 720, height: 875))
        XCTAssertEqual(access.frame(of: WindowHandle(key: mail, element: nil)), CGRect(x: 300, y: 300, width: 700, height: 500))
        let restored = await run("windows", "layout", "restore", json: true)
        XCTAssertEqual(try object(restored)["message"] as? String, "Restored Safari — “Docs” to its previous size.")
        XCTAssertEqual(access.frame(of: WindowHandle(key: docs, element: nil)), docsFrame)
    }

    func testWindowAndAppOptionsPickTheirWindow() async throws {
        let byID = await run("windows", "layout", "right-half", "--window", "4513", json: true)
        let window = try XCTUnwrap(try object(byID)["window"] as? [String: Any])
        XCTAssertEqual(window["frame"] as? [String: Int], ["x": 720, "y": 25, "width": 720, "height": 875])
        let byApp = await run("windows", "layout", "maximize", "--app", "saf")
        XCTAssertEqual(byApp.output, "Maximized Safari — “Docs” on its display.")
        XCTAssertEqual(access.frame(of: WindowHandle(key: docs, element: nil)), laptop.visibleFrame)
        let otherDisplay = await run("windows", "layout", "maximize")
        XCTAssertEqual(otherDisplay.output, "Maximized Terminal — “zsh” on its display.")
        XCTAssertEqual(access.frame(of: WindowHandle(key: shell, element: nil)), monitor.visibleFrame)
        let positional = await run("windows", "layout", "left-half", "4513")
        XCTAssertEqual(positional.output, "Moved Safari — “Mail” to the left half.")
        let moved = await run("windows", "move", "4513", "--x", "40")
        XCTAssertTrue(moved.output.hasPrefix("Moved Safari — “Mail”"), moved.output)
        let missing = await run("windows", "layout", "center", "--window", "999")
        XCTAssertEqual(missing.exitCode, AgentExit.failure)
        XCTAssertTrue(missing.error.contains("frog windows list"), missing.error)
        let unknownApp = await run("windows", "layout", "center", "--app", "Mosaic")
        XCTAssertEqual(unknownApp.exitCode, AgentExit.failure)
        XCTAssertTrue(unknownApp.error.contains("frog apps list"), unknownApp.error)
    }

    func testWithFrogInFrontTheWindowInFrontOfTheOthersIsArranged() async {
        frontmost = ProcessInfo.processInfo.processIdentifier
        let moved = await run("windows", "layout", "left-half")
        XCTAssertEqual(moved.output, "Moved Terminal — “zsh” to the left half.")
    }

    func testLayoutsKeepTheWindowsGapWhileWindowsIsOn() async throws {
        var configuration = Configuration()
        configuration.preferences.ensureToolkit()
        configuration.preferences.setFeature(.windows, enabled: true)
        var settings = WindowPreferences()
        settings.gap = 10
        settings.cycleSizes = true
        configuration.preferences.toolkit?.windows = settings
        try makeModel(configuration)
        _ = await run("windows", "layout", "left-half", "--app", "Safari")
        XCTAssertEqual(access.frame(of: WindowHandle(key: docs, element: nil)), CGRect(x: 10, y: 35, width: 705, height: 855))
        // Asked again, the same half: an agent is not cycling sizes.
        _ = await run("windows", "layout", "left-half", "--app", "Safari")
        XCTAssertEqual(access.frame(of: WindowHandle(key: docs, element: nil)), CGRect(x: 10, y: 35, width: 705, height: 855))
    }

    func testMoveSetsTheGivenPartsOfTheFrameAndRestoreUndoesIt() async throws {
        let moved = await run("windows", "move", "--window", "4512", "--x", "10", "--width=500")
        XCTAssertEqual(moved.output, "Moved Safari — “Docs” to 500×600 at 10, 100.")
        XCTAssertEqual(access.frame(of: WindowHandle(key: docs, element: nil)), CGRect(x: 10, y: 100, width: 500, height: 600))
        access.windows[mail]?.minimumSize = CGSize(width: 400, height: 300)
        let small = await run("windows", "move", "--window", "4513", "--width", "200", "--height", "100")
        XCTAssertTrue(small.output.contains("did not take"), small.output)
        _ = await run("windows", "layout", "restore", "--window", "4512")
        XCTAssertEqual(access.frame(of: WindowHandle(key: docs, element: nil)), docsFrame)
    }

    func testFocusBringsTheChosenWindowForward() async throws {
        let byID = await run("windows", "focus", "4513")
        XCTAssertEqual(byID.output, "Brought Safari — “Mail” to the front.")
        _ = await run("windows", "focus", "--app", "Terminal")
        XCTAssertEqual(focused, [4513, 7001])
        AgentCommands.desktop.focus = { _ in false }
        let refused = await run("windows", "focus", "--window", "4512")
        XCTAssertEqual(refused.exitCode, AgentExit.failure)
        XCTAssertEqual(access.writes, [])
    }

    // MARK: Plugin actions

    private func startWindowsPlugin() async throws {
        var configuration = Configuration()
        configuration.preferences.ensureToolkit()
        configuration.preferences.setFeature(.windows, enabled: true)
        try makeModel(configuration)
        await model.pluginHost.syncAndWait()
    }

    private func action(_ id: String, _ values: [String: String] = [:]) async throws -> ActionResult {
        try await model.pluginHost.run(id, ActionInput(values: values, source: .agent))
    }

    func testWindowsListActionGivesTheWindowsAsJSON() async throws {
        try await startWindowsPlugin()
        let all = try await action("windows.list")
        let windows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(all.json.utf8)) as? [[String: Any]])
        XCTAssertEqual(Set(windows.compactMap { $0["id"] as? Int }), [4512, 4513, 7001])
        let safari = try await action("windows.list", ["app": "safari"])
        XCTAssertTrue(safari.text.contains("4512\tSafari"), safari.text)
        XCTAssertFalse(safari.text.contains("7001"), safari.text)
        trusted = false
        do { _ = try await action("windows.list"); XCTFail("Without Accessibility the list fails") } catch {
            XCTAssertTrue(error.localizedDescription.contains("Accessibility"), error.localizedDescription)
        }
    }

    func testWindowsFocusActionFindsTheWindowByAppOrTitle() async throws {
        try await startWindowsPlugin()
        let byTitle = try await action("windows.focus", ["title": "mail"])
        XCTAssertEqual(byTitle.text, "Brought Safari — “Mail” to the front.")
        _ = try await action("windows.focus", ["app": "Terminal"])
        XCTAssertEqual(focused, [4513, 7001])
        do { _ = try await action("windows.focus", ["title": "nowhere"]); XCTFail("An unknown title fails") } catch {}
        XCTAssertEqual(access.writes, [])
    }

    func testWindowsMoveActionAppliesTheLayoutToTheChosenWindow() async throws {
        try await startWindowsPlugin()
        let moved = try await action("windows.move", ["to": "left-half", "app": "Safari"])
        XCTAssertEqual(moved.text, "Moved Safari — “Docs” to the left half.")
        XCTAssertEqual(access.frame(of: WindowHandle(key: docs, element: nil)), CGRect(x: 0, y: 25, width: 720, height: 875))
        _ = try await action("windows.move", ["to": "right-half", "title": "Mail"])
        XCTAssertEqual(access.frame(of: WindowHandle(key: mail, element: nil)), CGRect(x: 720, y: 25, width: 720, height: 875))
        do { _ = try await action("windows.move", ["to": "sideways"]); XCTFail("An unknown layout is refused") } catch ActionError.invalid {}
        do { _ = try await action("windows.move"); XCTFail("--to is required") } catch ActionError.missing("to") {}
    }

    func testLayoutActionsExistAndTheSwitcherSaysWhyItCannotShow() async throws {
        try await startWindowsPlugin()
        let ids = Set(model.pluginHost.actions.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["windows.left-half", "windows.maximize-on-display", "windows.move-to-next-display", "windows.list",
                                          "windows.focus", "windows.move"]), "\(ids.sorted())")
        // Shortcuts are not registered in tests, so the switcher holds no event tap and cannot show.
        if ids.contains("window-switcher.show") {
            do { _ = try await action("window-switcher.show"); XCTFail("No tap, no list") } catch ActionError.failed {}
        }
    }

    func testAppsAreListedAndOpened() async throws {
        let list = await run("apps", "list", json: true)
        let apps = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(list.output.utf8)) as? [[String: Any]])
        XCTAssertEqual(apps.compactMap { $0["bundleId"] as? String }, ["com.apple.Safari", "com.apple.Terminal"])
        XCTAssertEqual(Set(apps[0].keys), ["name", "bundleId", "pid", "active", "hidden"])
        let running = await run("apps", "open", "com.apple.safari")
        XCTAssertEqual(running.output, "Brought Safari to the front.")
        let installed = await run("apps", "open", "Notes")
        XCTAssertEqual(installed.output, "Opened Notes.")
        XCTAssertEqual(opened.map(\.path), ["/Applications/Safari.app", "/System/Applications/Notes.app"])
        let unknown = await run("apps", "open", "Mosaic")
        XCTAssertEqual(unknown.exitCode, AgentExit.failure)
        let named = await run("apps", "open", "Notes.app")
        XCTAssertEqual(named.output, "Opened Notes.")
        let noBundle = await run("apps", "open", "./Missing.app")
        XCTAssertEqual(noBundle.exitCode, AgentExit.failure)
        XCTAssertTrue(noBundle.error.contains(directory.lastPathComponent), noBundle.error)
        XCTAssertEqual(opened.count, 3)
    }

    func testAppNamesMatchWholeNamesOrTheStartOfAWord() throws {
        func app(_ name: String) -> AgentApp { AgentApp(name: name, bundleId: nil, pid: 1, active: false, hidden: false, url: nil) }
        let apps = [app("Xcode"), app("Visual Studio Code"), app("Safari")]
        XCTAssertEqual(try AgentCommands.runningApp("code", in: apps).name, "Visual Studio Code")
        XCTAssertEqual(try AgentCommands.runningApp("XCODE", in: apps).name, "Xcode")
        XCTAssertEqual(try AgentCommands.runningApp("saf", in: apps).name, "Safari")
        XCTAssertThrowsError(try AgentCommands.runningApp("ode", in: apps))
    }

    func testHelpListsTheWindowAndAppCommands() async {
        let windows = await run("help", "windows")
        let apps = await run("apps")
        for command in AgentCommands.windows {
            let usage = String(command.usage.dropFirst("frog ".count))
            XCTAssertTrue((command.words[0] == "windows" ? windows : apps).output.contains(usage), usage)
            XCTAssertFalse(command.summary.isEmpty)
            XCTAssertNil(command.feature, "\(usage) needs Accessibility, not a feature")
        }
        let layout = await run("help", "windows", "layout")
        XCTAssertTrue(layout.output.hasPrefix("frog windows layout <layout> [ID | --app NAME]"), layout.output)
    }
}
