import XCTest
@testable import FrogApp

/// Rehearses the stages of the Terminal guide. The guide runs as it is, except that stand-ins
/// take the place of sudo, of the power setting and of the sudoers file, so nothing here is
/// privileged or changes the Mac.
@MainActor
final class StayAwakeGuideTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDown() {
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        folders = []
    }

    func testAResetIsAnnouncedAsAResetNotAsASetup() async throws {
        let guide = try rehearsal()
        try (guide.rule + "\n").write(to: guide.ruleFile, atomically: true, encoding: .utf8)
        let run = try await guide.run("reset", answers: "y\n")
        XCTAssertEqual(run.result, "success", run.output)
        XCTAssertTrue(run.output.contains("✓ Reset complete"), run.output)
        XCTAssertFalse(run.output.contains("Setup complete"), "Nothing was set up: \(run.output)")
        XCTAssertTrue(run.output.contains("Passwordless stay-awake access is removed."), run.output)
        XCTAssertEqual(try String(contentsOf: guide.ruleFile, encoding: .utf8), "", "The reset empties Frog's own file")
    }

    private func rehearsal() throws -> Rehearsal {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return try Rehearsal(folder: folder)
    }
}

private struct Rehearsal {
    let folder: URL
    /// Stands in for /etc/sudoers.d/frog-awake.
    var ruleFile: URL { folder.appendingPathComponent("frog-awake") }
    /// The exact line the guide asks for.
    let rule = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
    private var script: URL { folder.appendingPathComponent("StayAwakeSetup.command") }
    private var resultFile: URL { folder.appendingPathComponent("result") }

    init(folder: URL) throws {
        self.folder = folder
        // Answers the way sudo would for the guide's commands, without any privilege: the
        // policy listing follows the file "allowed", and visudo -f saves the file "edit".
        let sudo = try stand(in: "sudo", """
            #!/bin/bash
            here=$(/usr/bin/dirname "$0")
            case "$1" in
                -n)
                    [[ -e "$here/allowed" ]] || { echo "sudo: a password is required" >&2; exit 1; }
                    printf 'Sudoers entry:\\n    RunAsUsers: root\\n    Options: !authenticate\\n    Commands:\\n\\t%s\\n' "${*:4}" ;;
                /usr/sbin/visudo)
                    if [[ "$2" == -f && -e "$here/edit" ]]; then /bin/cp "$here/edit" "$3"; fi ;;
                /bin/mkdir) ;;
                /bin/test|/usr/bin/tee|/usr/bin/grep) "$@" ;;
                *) echo "The rehearsal does not know: $*" >&2; exit 64 ;;
            esac

            """)
        let pmset = try stand(in: "pmset", """
            #!/bin/bash
            printf 'System-wide power settings:\\n SleepDisabled\\t\\t0\\nCurrently in use:\\n sleep\\t\\t1\\n'

            """)
        let source = try XCTUnwrap(FrogResources.bundle.url(forResource: "StayAwakeSetup", withExtension: "command"))
        var text = try String(contentsOf: source, encoding: .utf8)
        for (real, rehearsed) in [("/usr/bin/sudo", quote(sudo)), ("/usr/bin/pmset -g", quote(pmset) + " -g"),
                                  ("RULE_FILE=/etc/sudoers.d/frog-awake", "RULE_FILE=" + quote(ruleFile))] {
            guard text.contains(real) else { throw Unrehearsable(reason: "The guide no longer contains \(real)") }
            text = text.replacingOccurrences(of: real, with: rehearsed)
        }
        // The real sudo, pmset and sudoers file must be out of reach before anything runs.
        for real in ["/usr/bin/sudo", "/usr/bin/pmset -g", "=/etc/sudoers.d"] where text.contains(real) {
            throw Unrehearsable(reason: "The rehearsal would still use \(real)")
        }
        try text.write(to: script, atomically: true, encoding: .utf8)
    }

    /// The effective policy allows both power commands without a password.
    func allowAccess() throws { try "".write(to: folder.appendingPathComponent("allowed"), atomically: true, encoding: .utf8) }
    /// What the person saves in visudo. Without it, they leave the editor without saving.
    func edit(saving rules: String) throws { try rules.write(to: folder.appendingPathComponent("edit"), atomically: true, encoding: .utf8) }

    /// Runs the guide as Terminal would, without a window, up to the result it reports to Frog.
    func run(_ mode: String, answers: String) async throws -> (result: String?, output: String) {
        let input = folder.appendingPathComponent("answers"), output = folder.appendingPathComponent("output")
        try answers.write(to: input, atomically: true, encoding: .utf8)
        try "".write(to: output, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: resultFile)
        let guide = Process()
        guide.executableURL = URL(fileURLWithPath: "/bin/bash")
        guide.arguments = [script.path, mode, resultFile.path]
        guide.standardInput = try FileHandle(forReadingFrom: input)
        let written = try FileHandle(forWritingTo: output)
        guide.standardOutput = written; guide.standardError = written
        try guide.run()
        // The guide reports before it says goodbye, so its last two seconds are not waited for.
        defer { if guide.isRunning { kill(guide.processIdentifier, SIGKILL) } }
        var waited = 0
        while guide.isRunning, !FileManager.default.fileExists(atPath: resultFile.path), waited < 2000 {
            try await Task.sleep(for: .milliseconds(10)); waited += 1
        }
        let result = (try? String(contentsOf: resultFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (result, try String(contentsOf: output, encoding: .utf8))
    }

    private func stand(in name: String, _ text: String) throws -> URL {
        let file = folder.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    private func quote(_ file: URL) -> String { "'" + file.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    struct Unrehearsable: Error { let reason: String }
}
