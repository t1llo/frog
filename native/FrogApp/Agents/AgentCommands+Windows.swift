import AppKit
import FrogCore

/// Windows and apps: list, arrange, focus, open. They need Accessibility, not the Windows
/// feature: layouts move windows the way layout shortcuts do, with Windows' gaps while it is
/// on and where they always landed while it is off, and share their Restore history.
extension AgentCommands {
    /// What these commands read and change; tests give fixtures.
    static var desktop = AgentDesktop()

    static let accessibilityNeeded = "Frog needs Accessibility to see and arrange windows. "
        + "Allow Frog in System Settings → Privacy & Security → Accessibility, then try again."

    static var windows: [AgentCommand] {
        [
            AgentCommand(words: ["windows", "list"], arguments: "[--app NAME]", summary: "Open windows, front to back, with their ids.",
                         details: """
                         Lists the windows of running apps on the current Desktop, the one in front first, then minimized \
                         windows and those of hidden apps. Each has an id to pass to --window, its app, title, frame and \
                         display number. Frames are in points, with x and y measured from the top left of the main display \
                         and growing right and down; `frog windows displays` gives each display's frame the same way.

                         Example: frog windows list --app Safari --json
                         """, options: ["app"]) { call in
                try requireAccessibility()
                var apps = desktop.apps()
                if let name = call.option("app") { apps = [try runningApp(name, in: apps)] }
                let windows = await scan(apps)
                let text = windows.isEmpty ? "No windows are open." : AgentTable.render(windows.map { window in
                    let flags = [window.focused ? "focused" : nil, window.minimized ? "minimized" : nil, window.hidden ? "hidden" : nil]
                    return ["\(window.id)", window.app, shortened(window.title), AgentFrame(window.frame).text, "display \(window.display)",
                            flags.compactMap { $0 }.joined(separator: ", ")]
                })
                return AgentResult(windows, text: text)
            },
            AgentCommand(words: ["windows", "displays"], summary: "Connected displays and their frames.",
                         details: "Numbered as `frog windows list` numbers them, left to right. The usable frame leaves out the menu bar and the Dock. The main display has the menu bar; frames are measured from its top left.") { _ in
                let displays = desktop.displays().enumerated().map { index, display in
                    Display(number: index + 1, name: display.name, frame: AgentFrame(display.frame),
                            visibleFrame: AgentFrame(display.visibleFrame), main: display.frame.origin == .zero)
                }
                let text = AgentTable.render(displays.map {
                    ["\($0.number)", $0.name, $0.frame.text, "usable \($0.visibleFrame.text)", $0.main ? "main" : ""]
                })
                return AgentResult(displays, text: text)
            },
            AgentCommand(words: ["windows", "layouts"], summary: "The layouts `frog windows layout` applies.") { _ in
                let layouts = WindowAction.allCases.map { Layout(name: $0.agentName, title: $0.title) }
                return AgentResult(layouts, text: AgentTable.render(layouts.map { [$0.name, $0.title] }))
            },
            AgentCommand(words: ["windows", "layout"], arguments: "<layout> [ID | --app NAME]",
                         summary: "Arrange a window, as a layout shortcut does.",
                         details: """
                         Takes a name from `frog windows layouts`, such as left-half, top-right, left-third, maximize, \
                         centered-large, next-display or restore. Restore gives back the frame from before the last layout \
                         or move, whether it came from Frog, a shortcut or this tool.

                         Pick the window by its id from `frog windows list` (also as --window), or with --app for that \
                         app's focused window. Without either, it arranges the focused window of the app in front, which \
                         is whatever the user is looking at.

                         Examples: frog windows layout left-half --app Safari
                                   frog windows layout restore 4512
                         """, options: ["window", "app"]) { call in
                let action = try layout(call.argument(0, "layout"))
                let window = try await target(call, idAt: 1)
                let model = call.model
                var options = WindowSwitches(model.configuration.preferences).layoutOptions(desktop.macOS())
                // An agent asking twice wants the same layout twice, not the next size of a cycle.
                options.cycleSizes = false
                let manager = desktop.manager ?? model.windowLayout.manager
                try await manager.apply(action, to: window.handle, displays: desktop.displays(), options: options)
                return await moved(window, by: manager, message: sentence(action, window.name))
            },
            AgentCommand(words: ["windows", "move"], arguments: "[ID | --app NAME] [--x X] [--y Y] [--width W] [--height H]",
                         summary: "Give a window an exact position or size.",
                         details: """
                         Sets any of the window's x, y, width and height, in points, and keeps the rest. x and y place its \
                         top left corner, measured from the top left of the main display as `frog windows list` shows. Some \
                         apps keep to a minimum size or a grid; the answer gives the frame the window ended up with. \
                         `frog windows layout restore` puts it back.

                         The window is picked as for `frog windows layout`.

                         Examples: frog windows move --app Safari --x 0 --y 25 --width 1200 --height 800
                                   frog windows move 4512 --width 900
                         """, options: ["window", "app", "x", "y", "width", "height"]) { call in
                let change = FrameChange(x: try points(call, "x"), y: try points(call, "y"),
                                         width: try points(call, "width", size: true), height: try points(call, "height", size: true))
                guard !change.isEmpty else { throw AgentCommandError.usage("Give at least one of --x, --y, --width and --height. Usage: \(call.command.usage)") }
                let window = try await target(call, idAt: 0)
                let manager = desktop.manager ?? call.model.windowLayout.manager
                let applied = try await manager.place(window.handle) { change.applied(to: $0) }
                var message = "Moved \(window.name) to \(AgentFrame(applied).text)."
                let wanted = change.applied(to: window.frame)
                if !WindowGeometry.close(applied, wanted) { message += " The app did not take \(AgentFrame(wanted).text) exactly." }
                return await moved(window, by: manager, message: message)
            },
            AgentCommand(words: ["windows", "focus"], arguments: "[ID] [--app NAME]", summary: "Bring a window to the front.",
                         details: """
                         Takes a window id from `frog windows list`, also as --window, or --app for that app's focused \
                         window. A minimized window is restored.

                         Examples: frog windows focus 4512
                                   frog windows focus --app Notes
                         """, options: ["window", "app"]) { call in
                guard call.optionalArgument(0) != nil || call.option("window") != nil || call.option("app") != nil else {
                    throw AgentCommandError.usage("Give a window id from `frog windows list`, or --app NAME. Usage: \(call.command.usage)")
                }
                var window = try await target(call, idAt: 0, includingMinimized: true)
                guard await desktop.focus(window) else {
                    throw AgentCommandError.failed("macOS could not bring \(window.name) to the front. It may have closed.")
                }
                window.focused = true; window.minimized = false
                let message = "Brought \(window.name) to the front."
                return AgentResult(Moved(message: message, window: window), text: message)
            },
            AgentCommand(words: ["apps", "list"], summary: "Running apps, with their bundle ids.",
                         details: "Lists the apps you can switch to, by name. Their names and bundle ids work with --app and `frog apps open`.") { _ in
                let apps = desktop.apps().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                let text = AgentTable.render(apps.map { app in
                    [app.name, app.bundleId ?? "", "pid \(app.pid)", [app.active ? "active" : nil, app.hidden ? "hidden" : nil].compactMap { $0 }.joined(separator: ", ")]
                })
                return AgentResult(apps, text: text)
            },
            AgentCommand(words: ["apps", "open"], arguments: "<name | bundle id | path>", summary: "Open an app, or bring it to the front.",
                         details: """
                         Takes the app's name as Finder shows it, its bundle id or the path to it. An app that is running \
                         comes to the front, as when you click it in the Dock.

                         Examples: frog apps open Safari
                                   frog apps open com.apple.Notes
                                   frog apps open ~/Applications/Example.app
                         """) { call in
                let text = try call.text(from: 0, "app")
                let url = try await application(text, call: call)
                let running = desktop.apps().first { $0.url?.standardizedFileURL == url.standardizedFileURL }
                try await desktop.open(url)
                let name = running?.name ?? url.deletingPathExtension().lastPathComponent
                let message = running == nil ? "Opened \(name)." : "Brought \(name) to the front."
                return AgentResult(Opened(message: message, name: name, path: url.path), text: message)
            }
        ]
    }

    // MARK: Targets

    private static func requireAccessibility() throws {
        guard desktop.isTrusted() else { throw AgentCommandError.failed(accessibilityNeeded) }
    }

    /// The windows of these apps, read off the main actor.
    private static func scan(_ apps: [AgentApp]) async -> [AgentWindow] {
        let read = desktop.windows, displays = desktop.displays(), frontmost = desktop.frontmost()
        return await Task.detached { read(apps, displays, frontmost) }.value
    }

    /// The window a command acts on: the one whose id is the positional argument at `index` or
    /// `--window`, the focused window of `--app`, or the focused window of the app in front. While
    /// Frog is in front, the window in front of all others. Words after the id are refused, so a
    /// mistyped id never falls back to another window.
    static func target(_ call: AgentCall, idAt index: Int, includingMinimized: Bool = false) async throws -> AgentWindow {
        if call.positional.count > index + 1 {
            throw AgentCommandError.usage("Unexpected “\(call.positional[index + 1])”. Usage: \(call.command.usage)")
        }
        let given = call.optionalArgument(index)
        if given != nil, call.option("window") != nil { throw AgentCommandError.usage("Give the window id once. Usage: \(call.command.usage)") }
        let idText = given ?? call.option("window")
        let appName = call.option("app")
        if idText != nil, appName != nil { throw AgentCommandError.usage("Pick the window by its id or --app, not both.") }
        let id = try idText.map { text in
            guard let id = UInt32(text), id > 0 else {
                throw AgentCommandError.usage("A window id is a number from `frog windows list`, not “\(text)”.")
            }
            return id
        }
        try requireAccessibility()
        let apps = desktop.apps()
        if let id {
            guard let window = await scan(apps).first(where: { $0.id == id }) else {
                throw AgentCommandError.failed("No open window has id \(id). Run `frog windows list` for the ids.")
            }
            return window
        }
        if let appName {
            let app = try runningApp(appName, in: apps)
            guard let window = frontWindow(await scan([app]), includingMinimized: includingMinimized) else {
                throw AgentCommandError.failed("\(app.name) has no window open on this Desktop.")
            }
            return window
        }
        let frontmost = desktop.frontmost()
        if let app = apps.first(where: { $0.pid == frontmost }) {
            guard let window = frontWindow(await scan([app])) else {
                throw AgentCommandError.failed("\(app.name) is in front and has no window open. Pick one with --window or --app.")
            }
            return window
        }
        guard let window = await scan(apps).first(where: { !$0.minimized && !$0.hidden }) else {
            throw AgentCommandError.failed("There is no window to arrange. Pick one with --window or --app.")
        }
        return window
    }

    private static func frontWindow(_ windows: [AgentWindow], includingMinimized: Bool = false) -> AgentWindow? {
        windows.first(where: \.appFocused) ?? windows.first { !$0.minimized } ?? (includingMinimized ? windows.first : nil)
    }

    /// A running app by name or bundle id in any case, else the one app with a word of its name
    /// starting with the text, so "code" finds Visual Studio Code but not Xcode.
    static func runningApp(_ text: String, in apps: [AgentApp]) throws -> AgentApp {
        let wanted = text.lowercased()
        if let app = apps.first(where: { $0.name.lowercased() == wanted || $0.bundleId?.lowercased() == wanted }) { return app }
        let partial = apps.filter { app in
            let name = app.name.lowercased()
            return name.hasPrefix(wanted) || name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(wanted) }
        }
        if partial.count == 1 { return partial[0] }
        guard partial.isEmpty else {
            let names = partial.map(\.name).sorted().joined(separator: ", ")
            throw AgentCommandError.failed("“\(text)” could be \(names). Give the full name.")
        }
        throw AgentCommandError.failed("No running app is named “\(text)”. Run `frog apps list` for the names.")
    }

    /// The app `frog apps open` opens: a path, a running app, or an installed one.
    private static func application(_ text: String, call: AgentCall) async throws -> URL {
        if text.contains("/") || text.hasPrefix("~") {
            let url = call.path(text)
            var folder: ObjCBool = false
            guard url.pathExtension.lowercased() == "app", FileManager.default.fileExists(atPath: url.path, isDirectory: &folder), folder.boolValue else {
                throw AgentCommandError.failed("There is no app at \(url.path).")
            }
            return url
        }
        // "Safari.app" is the name Finder shows with extensions visible.
        let name = text.lowercased().hasSuffix(".app") ? String(text.dropLast(4)) : text
        let wanted = name.lowercased()
        if let url = desktop.apps().first(where: { $0.name.lowercased() == wanted || $0.bundleId?.lowercased() == wanted })?.url { return url }
        if let url = await desktop.findApp(name) { return url }
        throw AgentCommandError.failed("No app named “\(text)” is installed. Give its name as Finder shows it, its bundle id or its path.")
    }

    // MARK: Layouts and frames

    static func layout(_ text: String) throws -> WindowAction {
        guard let action = WindowAction.agentNamed(text) else {
            throw AgentCommandError.usage("No layout named “\(text)”. Run `frog windows layouts` for the names.")
        }
        return action
    }

    /// What a layout did, for people.
    static func sentence(_ action: WindowAction, _ name: String) -> String {
        switch action {
        case .maximize: "Maximized \(name) on its display."
        case .minimize: "Minimized \(name)."
        case .center: "Centered \(name)."
        case .restore: "Restored \(name) to its previous size."
        case .nextDisplay: "Moved \(name) to the next display."
        case .previousDisplay: "Moved \(name) to the previous display."
        case .toggleFullScreen: "Switched full screen for \(name)."
        case .centeredSmall: "Centered \(name) at 50% of its display."
        case .centeredMedium: "Centered \(name) at 70% of its display."
        case .centeredLarge: "Centered \(name) at 90% of its display."
        default: "Moved \(name) to the \(action.title.lowercased())."
        }
    }

    /// The window as it is now, with what was done.
    private static func moved(_ window: AgentWindow, by manager: WindowManager, message: String) async -> AgentResult {
        var window = window
        let now = await manager.read(window.handle)
        if let frame = now.frame { window.frame = frame }
        window.minimized = now.state.minimized
        window.display = AgentDesktop.displayNumber(of: window.frame, in: desktop.displays())
        return AgentResult(Moved(message: message, window: window), text: message)
    }

    private static func points(_ call: AgentCall, _ name: String, size: Bool = false) throws -> CGFloat? {
        guard let text = call.option(name) else { return nil }
        guard let value = Double(text), value.isFinite, abs(value) <= 100_000, !size || value >= 1 else {
            throw AgentCommandError.usage(size ? "--\(name) takes a number of points from 1, such as 800." : "--\(name) takes a number of points, such as 120.")
        }
        return CGFloat(value)
    }

    /// The parts of a frame `frog windows move` was given.
    struct FrameChange: Sendable {
        var x: CGFloat?, y: CGFloat?, width: CGFloat?, height: CGFloat?
        var isEmpty: Bool { x == nil && y == nil && width == nil && height == nil }
        func applied(to frame: CGRect) -> CGRect {
            CGRect(x: x ?? frame.minX, y: y ?? frame.minY, width: width ?? frame.width, height: height ?? frame.height)
        }
    }

    private static func shortened(_ title: String) -> String { title.count > 48 ? String(title.prefix(47)) + "…" : title }

    private struct Moved: Encodable {
        var ok = true
        let message: String
        let window: AgentWindow
    }

    private struct Opened: Encodable {
        var ok = true
        let message: String
        let name: String
        let path: String
    }

    private struct Layout: Encodable {
        let name: String
        let title: String
    }

    private struct Display: Encodable {
        let number: Int
        let name: String
        let frame: AgentFrame
        let visibleFrame: AgentFrame
        let main: Bool
    }
}

extension WindowAction {
    /// The name the `frog` tool uses, such as "left-half".
    var agentName: String {
        rawValue.reduce(into: "") { name, character in
            if character.isUppercase { name += "-" + character.lowercased() } else { name.append(character) }
        }
    }

    /// A layout by its tool name or its ID, in any case; spaces count as hyphens.
    static func agentNamed(_ text: String) -> WindowAction? {
        let wanted = text.lowercased().replacingOccurrences(of: " ", with: "-")
        return allCases.first { $0.agentName == wanted || $0.rawValue.lowercased() == wanted }
    }
}
