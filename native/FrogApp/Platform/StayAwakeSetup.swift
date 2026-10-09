import AppKit
import FrogCore

enum StayAwakeSetup {
    @MainActor static func open() throws {
        guard let source = FrogResources.bundle.url(forResource: "StayAwakeSetup", withExtension: "command") else {
            throw FrogError.message("The stay-awake setup guide is missing from this build.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Frog-power-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let script = folder.appendingPathComponent("StayAwakeSetup.command")
        try FileManager.default.copyItem(at: source, to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        guard NSWorkspace.shared.open(script) else { throw FrogError.message("Open Terminal to run the stay-awake setup guide.") }
    }
}
