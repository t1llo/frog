import AppKit
import FrogAgent

/// `frog`: sends its words to the running Frog app, which parses and answers them.
/// It starts Frog when it is not running, and says when agent access is off.
enum FrogCommandLine {
    static let bundleIdentifier = "xyz.beffa.frog"

    static func run(_ words: [String]) -> Int32 {
        var json = false
        var readsInput = false
        var arguments: [String] = []
        for word in words {
            switch word {
            case "--json": json = true
            case "--stdin": readsInput = true
            default: arguments.append(word)
            }
        }
        if arguments == ["--version"] || arguments == ["-v"] {
            print("frog \(containingApp().flatMap(version) ?? "unknown")")
            return 0
        }
        if arguments.isEmpty || arguments == ["-h"] || arguments == ["--help"] { arguments = ["help"] }
        var input: String?
        if readsInput {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else {
                FileHandle.standardError.write(Data("frog: standard input is not UTF-8 text.\n".utf8))
                return AgentExit.usage
            }
            input = text
        }
        let request = AgentRequest(arguments: arguments, json: json, directory: FileManager.default.currentDirectoryPath, input: input)
        let socket = AgentSocketPath.socket()
        do {
            return output(try send(request, socket: socket))
        } catch {
            FileHandle.standardError.write(Data("frog: \(error.localizedDescription)\n".utf8))
            return (error as? AgentSocketError) == .unavailable ? AgentExit.unavailable : AgentExit.failure
        }
    }

    private static func send(_ request: AgentRequest, socket: URL) throws -> AgentResponse {
        do { return try AgentClient.send(request, to: socket) }
        catch AgentSocketError.unavailable {
            guard !frogIsRunning else { throw Unavailable.accessOff }
            guard launchFrog() else { throw Unavailable.notInstalled }
            // A freshly started Frog opens its socket once it has read its settings.
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.2)
                do { return try AgentClient.send(request, to: socket) }
                catch AgentSocketError.unavailable { continue }
            }
            throw Unavailable.accessOff
        }
    }

    private enum Unavailable: LocalizedError {
        case accessOff, notInstalled
        var errorDescription: String? {
            switch self {
            case .accessOff: "Frog is running, but agent access is off. Turn it on in Frog → Settings → Agents."
            case .notInstalled: "Frog is not running and could not be started. Install it from https://github.com/t1llo/frog/releases."
            }
        }
    }

    private static func output(_ response: AgentResponse) -> Int32 {
        if !response.output.isEmpty {
            FileHandle.standardOutput.write(Data((response.output.hasSuffix("\n") ? response.output : response.output + "\n").utf8))
        }
        if !response.error.isEmpty {
            FileHandle.standardError.write(Data("frog: \(response.error)\n".utf8))
        }
        return response.exitCode
    }

    private static var frogIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// The Frog.app this tool ships in (`Frog.app/Contents/Helpers/frog`), also when called through a link.
    static func containingApp() -> URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app", Bundle(url: app)?.bundleIdentifier == bundleIdentifier else { return nil }
        return app
    }

    private static func version(_ app: URL) -> String? {
        Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Starts Frog in the background without bringing it to the front.
    private static func launchFrog() -> Bool {
        guard let app = containingApp() ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return false }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-a", app.path]
        do { try open.run() } catch { return false }
        open.waitUntilExit()
        return open.terminationStatus == 0
    }
}

exit(FrogCommandLine.run(Array(CommandLine.arguments.dropFirst())))
