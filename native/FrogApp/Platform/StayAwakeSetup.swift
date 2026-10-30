import AppKit
import FrogCore

enum StayAwakeSetup {
    enum Mode: String { case setup, reset }
    enum Result: String { case success, cancelled, failed }
    struct Session {
        let folder: URL
        var launcher: URL { folder.appendingPathComponent("Frog Stay Awake.terminal") }
        var resultFile: URL { folder.appendingPathComponent("result") }
        /// The guide writes its process id here when it starts.
        var processFile: URL { folder.appendingPathComponent("result.pid") }

        /// The guide has no time limit: reading it and editing with visudo take as long as they
        /// take. The wait ends with its result, with its process, or when the task is cancelled.
        func waitForResult() async throws -> Result {
            var guide: (pid: pid_t, started: Int64?)?
            while true {
                try Task.checkCancellation()
                if let result { return result }
                if guide == nil, let pid = process { guide = (pid, LidClosedSleep.processStart(pid)) }
                // A guide that was killed never reports. One that ends in order writes its
                // result first, so a last look after its process is gone cannot miss it.
                if let guide, guide.started == nil || LidClosedSleep.processStart(guide.pid) != guide.started {
                    return result ?? .failed
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        private var result: Result? {
            (try? String(contentsOf: resultFile, encoding: .utf8))
                .flatMap { Result(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        private var process: pid_t? {
            (try? String(contentsOf: processFile, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.flatMap { $0 > 0 ? $0 : nil }
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
