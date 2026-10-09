import AppKit
import FrogCore

enum StayAwakeSetup {
    enum Mode: String { case setup, reset }
    enum Result: String { case success, cancelled, failed }
    struct Session {
        let folder: URL
        var launcher: URL { folder.appendingPathComponent("Frog Stay Awake.terminal") }
        var resultFile: URL { folder.appendingPathComponent("result") }

        func waitForResult() async throws -> Result {
            while true {
                try Task.checkCancellation()
                if let value = try? String(contentsOf: resultFile, encoding: .utf8),
                   let result = Result(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines)) { return result }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    @MainActor static func open(_ mode: Mode) async throws -> Session {
        let session = try prepare(mode)
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            session.remove(); throw FrogError.message("Terminal is required to configure stay-awake access.")
        }
        do {
            let configuration = NSWorkspace.OpenConfiguration(); configuration.addsToRecentItems = false
            _ = try await NSWorkspace.shared.open([session.launcher], withApplicationAt: terminal, configuration: configuration)
            return session
        } catch { session.remove(); throw error }
    }

    static func prepare(_ mode: Mode, directory: URL = FileManager.default.temporaryDirectory) throws -> Session {
        guard let source = FrogResources.bundle.url(forResource: "StayAwakeSetup", withExtension: "command") else {
            throw FrogError.message("The stay-awake setup guide is missing from this build.")
        }
        let folder = directory.appendingPathComponent("Frog-power-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let script = folder.appendingPathComponent("StayAwakeSetup.command")
        try FileManager.default.copyItem(at: source, to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let session = Session(folder: folder)
        let command = "exec " + ["/bin/bash", script.path, mode.rawValue, session.resultFile.path].map(shellQuote).joined(separator: " ")
        // A session-only Terminal profile closes this window on success, without
        // changing the user's default profile or closing other Terminal windows.
        // Terminal's direct-command mode does not parse shell quoting. Run through
        // the shell, then exec the guide so its exit still closes this session.
        let profile: [String: Any] = ["name": "Frog Stay Awake", "type": "Window Settings",
            "CommandString": command, "RunCommandAsShell": false, "shellExitAction": 0,
            "rowCount": 24, "columnCount": 100]
        let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        try data.write(to: session.launcher, options: .atomic)
        return session
    }

    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
