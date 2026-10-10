import Darwin
import Foundation
import XCTest
import FrogCore
@testable import FrogApp

final class LocalToolClientTests: XCTestCase {
    @MainActor func testInstalledToolRunsThroughNormalRuleDeliveryWithoutFrogCredentials() async throws {
        let root = try directory()
        _ = try executable("""
        if [ "$1" = "--help" ]; then
          echo '--safe-mode --tools --strict-mcp-config --permission-prompts --setting-sources --no-session-persistence'
          exit
        fi
        for arg in "$@"; do [ "$arg" != '@default' ] || exit 9; done
        text=$(/bin/cat)
        [ "$text" = 'synthetic draft' ] || exit 9
        echo '{"type":"result","subtype":"success","result":"Revised synthetic draft."}'
        """, in: root)
        let client = LocalToolClient(discovery: .init(home: root, environment: [:], searchDirectories: [root]), temporaryRoot: root)
        var copied = ""
        let model = AppModel(dataDirectory: root, registerShortcuts: false,
            readKey: { _ in XCTFail("Coding tools must not read Frog API keys"); return nil },
            writeClipboard: { copied = $0 }, localToolClient: client)
        defer { model.shutdown() }
        try model.useLocalTool(.claudeCode, model: "")
        let provider = try XCTUnwrap(model.configuration.providers.first)
        let rule = Rule(name: "Tool rewrite", providerID: provider.id, model: LocalToolKind.defaultModelID)
        try model.saveRule(rule)
        model.processManual(text: "synthetic draft", ruleID: rule.id)
        for _ in 0..<300 where model.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isProcessing)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(copied, "Revised synthetic draft.")
        XCTAssertEqual(model.manualResult, copied)
        XCTAssertEqual(model.statistics.snapshot.allTime.ruleRuns(.cli), 1)
        XCTAssertTrue(model.history.isEmpty)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("frog-tool-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func executable(_ body: String, name: String = "claude", in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        // Fixture scripts run directly via their shebang. Production never invokes a shell.
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func testDiscoveryHandlesSpacesSymlinksAndIgnoresRelativePath() throws {
        let root = try directory(), bin = root.appendingPathComponent("a directory")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let target = try executable("exit 0", name: "actual", in: root)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("claude"), withDestinationURL: target)
        let discovery = LocalToolDiscovery(home: root, environment: ["PATH": ":.:relative:\(bin.path)"])
        XCTAssertEqual(discovery.executable(for: .claudeCode)?.path, bin.appendingPathComponent("claude").path)
        XCTAssertFalse(discovery.searchDirectories.contains { $0.path == FileManager.default.currentDirectoryPath })
        XCTAssertNil(LocalToolDiscovery(home: root, environment: [:], searchDirectories: [bin]).executable(for: .codex))
    }

    func testInvocationNeverPlacesSelectedTextOrInstructionsInArgumentsAndDisablesTools() throws {
        let workspace = try LocalToolWorkspace(root: directory())
        defer { workspace.remove() }
        let request = try LocalToolRequest(kind: .claudeCode, model: "sonnet", instructions: "Private instruction", text: "$(touch /nope); \"quoted\"\ntext")
        let invocation = try LocalToolInvocation.make(request, workspace: workspace)
        XCTAssertFalse(invocation.arguments.joined().contains(request.text))
        XCTAssertFalse(invocation.arguments.joined().contains(request.instructions))
        XCTAssertEqual(String(decoding: invocation.input, as: UTF8.self), request.text)
        XCTAssertEqual(invocation.arguments[invocation.arguments.firstIndex(of: "--tools")! + 1], "")
        XCTAssertTrue(invocation.arguments.contains("--safe-mode"))
        XCTAssertFalse(invocation.arguments.contains("--bare"))
        XCTAssertTrue(invocation.arguments.contains("--no-session-persistence"))
        XCTAssertTrue(invocation.arguments.contains("--strict-mcp-config"))
        let open = try LocalToolInvocation.make(.init(kind: .opencode, instructions: "translate", text: request.text), workspace: workspace)
        XCTAssertTrue(open.arguments.contains("--standalone"))
        XCTAssertFalse(open.arguments.contains("--auto"))
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: workspace.directory.appendingPathComponent("config/opencode/opencode.json"))) as! [String: Any]
        let agents = config["agents"] as! [String: [String: Any]]
        XCTAssertEqual(agents["frog-text"]?["steps"] as? Int, 1)
        XCTAssertEqual((agents["frog-text"]?["permissions"] as? [[String: String]])?.first?["effect"], "deny")
    }

    func testCompletionIgnoresReasoningAndLogsPreservesWhitespaceRejectsFailuresAndTools() throws {
        XCTAssertEqual(try LocalToolOutput.completion(Data(#"{"type":"result","subtype":"success","is_error":false,"result":"  final\n"}"#.utf8), kind: .claudeCode), "  final\n")
        let stream = """
        {"type":"step_start","part":{}}
        {"type":"reasoning","part":{"text":"private reasoning"}}
        {"type":"text","part":{"type":"text","text":"  final\\n"}}
        {"type":"step_finish","part":{"reason":"stop"}}
        """
        XCTAssertEqual(try LocalToolOutput.completion(Data(stream.utf8), kind: .opencode), "  final\n")
        for extra in ["{\"type\":\"error\"}", "{\"type\":\"tool_use\"}", "not json"] {
            XCTAssertThrowsError(try LocalToolOutput.completion(Data((stream + "\n" + extra).utf8), kind: .opencode))
        }
        XCTAssertThrowsError(try LocalToolOutput.completion(Data("{\"type\":\"text\",\"part\":{\"type\":\"text\",\"text\":\"partial\"}}".utf8), kind: .opencode))
        XCTAssertThrowsError(try LocalToolOutput.completion(Data(#"{"type":"result","subtype":"error_max_turns","result":"partial"}"#.utf8), kind: .claudeCode))
    }

    func testStatusKeepsInstalledLoginAndSupportDistinctWithoutLeakingAccounts() async throws {
        let root = try directory()
        _ = try executable("""
        if [ "$1" = "--help" ]; then
          echo '--safe-mode --tools --strict-mcp-config --permission-prompts --setting-sources --no-session-persistence'
        elif [ "$1" = "auth" ]; then
          echo '{"loggedIn":false,"email":"private@example.invalid"}'
          exit 1
        fi
        """, in: root)
        let client = LocalToolClient(discovery: .init(home: root, environment: [:], searchDirectories: [root]), temporaryRoot: root)
        let status = await client.status(for: .claudeCode)
        XCTAssertTrue(status.installed)
        XCTAssertTrue(status.supportsTextTransforms)
        XCTAssertEqual(status.authentication, .signedOut)
        XCTAssertFalse(status.detail.contains("private@"))
        let missing = await client.status(for: .opencode)
        XCTAssertFalse(missing.installed)
        XCTAssertEqual(missing.authentication, .notChecked)
        _ = try executable("echo 'Logged in using ChatGPT'", name: "codex", in: root)
        let codex = await client.status(for: .codex)
        XCTAssertTrue(codex.installed)
        XCTAssertEqual(codex.authentication, .signedIn)
        XCTAssertFalse(codex.supportsTextTransforms)
    }

    func testFakeCLIEndToEndStdinEnvironmentAndWorkspaceCleanup() async throws {
        let root = try directory()
        _ = try executable("""
        if [ "$1" = "--help" ]; then
          echo '--safe-mode --tools --strict-mcp-config --permission-prompts --setting-sources --no-session-persistence'
          exit
        fi
        [ -z "$NODE_OPTIONS" ] || exit 9
        [ -z "$ANTHROPIC_API_KEY" ] || exit 9
        [ "$PWD" != "$HOME" ] || exit 9
        text=$(/bin/cat)
        [ "$text" = '$(do not execute); private input' ] || exit 9
        echo '{"type":"result","subtype":"success","result":"fixture completion"}'
        """, in: root)
        let client = LocalToolClient(discovery: .init(home: root, environment: ["NODE_OPTIONS": "bad", "ANTHROPIC_API_KEY": "secret"], searchDirectories: [root]), temporaryRoot: root)
        let value = try await client.complete(.init(kind: .claudeCode, instructions: "rewrite", text: "$(do not execute); private input"))
        XCTAssertEqual(value, "fixture completion")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["claude"])
    }

    func testDuplexLargeInputAndSeparateOutputAvoidDeadlock() async throws {
        let root = try directory()
        let tool = try executable("/usr/bin/head -c 131072 /dev/zero >&2\n/bin/cat", in: root)
        let input = Data(repeating: 65, count: 400_000)
        let result = try await LocalToolProcess.run(executable: tool, arguments: [], input: input, environment: [:], directory: root, timeout: 4)
        XCTAssertEqual(result.stdout, input)
        XCTAssertEqual(result.stderr.count, 131072)
        XCTAssertEqual(result.status, 0)
    }

    func testOpenCodeFixtureUsesIsolatedConfigurationAndExistingDataLocation() async throws {
        let root = try directory()
        _ = try executable("""
        if [ "$1" = "run" ] && [ "$2" = "--help" ]; then
          echo '--standalone --format --agent'; exit
        fi
        if [ "$1" = "--version" ]; then echo 'opencode v2.0.26'; exit; fi
        [ "$HOME" = "$PWD" ] || exit 8
        [ "$OPENCODE_DISABLE_PROJECT_CONFIG" = '1' ] || exit 8
        [ "$OPENCODE_DISABLE_MODELS_FETCH" = '1' ] || exit 8
        [ -f "$XDG_CONFIG_HOME/opencode/opencode.json" ] || exit 8
        [ "$XDG_DATA_HOME" != "$HOME/.local/share" ] || exit 8
        case "$XDG_DATA_HOME" in /*) ;; *) exit 8 ;; esac
        case "$XDG_CACHE_HOME" in /*) ;; *) exit 8 ;; esac
        if [ "$1" = 'auth' ]; then
          echo '[{"id":"openai","connections":[{"label":"private@example.invalid"}]}]'; exit
        fi
        if [ "$1" = 'models' ]; then echo 'openai/fixture-model'; exit; fi
        /bin/cat >/dev/null
        echo '{"type":"text","part":{"type":"text","text":"clean output"}}'
        echo '{"type":"step_finish","part":{"reason":"stop"}}'
        """, name: "opencode", in: root)
        let client = LocalToolClient(discovery: .init(home: root, environment: ["XDG_DATA_HOME": "relative", "XDG_CACHE_HOME": ""], searchDirectories: [root]), temporaryRoot: root)
        let status = await client.status(for: .opencode)
        XCTAssertEqual(status.authentication, .signedIn)
        XCTAssertTrue(status.supportsTextTransforms)
        XCTAssertFalse(status.detail.contains("private@"))
        let models = try await client.models(for: .opencode)
        XCTAssertEqual(models.map(\.id), ["", "openai/fixture-model"])
        let output = try await client.complete(.init(kind: .opencode, instructions: "Rewrite", text: "input"))
        XCTAssertEqual(output, "clean output")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["opencode"])
    }

    func testChildClosingStdinDoesNotDeliverSIGPIPEToFrog() async throws {
        let root = try directory()
        let tool = try executable("exec 0<&-\n/bin/sleep 0.05\necho done", in: root)
        let result = try await LocalToolProcess.run(executable: tool, arguments: [], input: Data(repeating: 65, count: 500_000), environment: [:], directory: root)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "done\n")
    }

    func testCodexUsesDenyReadWriteProfileInsteadOfLegacyReadOnlyAndPreservesLoginLocation() async throws {
        let root = try directory()
        _ = try executable("""
        if [ "$1" = '--version' ]; then echo 'codex-cli 0.159.0'; exit; fi
        if [ "$1" = 'exec' ] && [ "$2" = '--help' ]; then
          echo '--strict-config --ignore-user-config --ignore-rules --ephemeral --json'; exit
        fi
        [ "$HOME" = "$PWD" ] || exit 8
        [ "$CODEX_HOME" != "$HOME/.codex" ] || exit 8
        [ "$RUST_LOG" = 'codex_core::tools::router=error' ] || exit 8
        /bin/cat >/dev/null
        echo '{"type":"item.completed","item":{"type":"reasoning","text":"not output"}}'
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"codex fixture"}}'
        echo '{"type":"turn.completed"}'
        """, name: "codex", in: root)
        let client = LocalToolClient(discovery: .init(home: root, environment: [:], searchDirectories: [root]), temporaryRoot: root)
        let status = await client.status(for: .codex, checkAuthentication: false)
        XCTAssertTrue(status.supportsTextTransforms)
        let output = try await client.complete(.init(kind: .codex, instructions: "Rewrite", text: "selected text"))
        XCTAssertEqual(output, "codex fixture")
        let workspace = try LocalToolWorkspace(root: root)
        defer { workspace.remove() }
        let invocation = try LocalToolInvocation.make(.init(kind: .codex, instructions: "Rewrite", text: "private input"), workspace: workspace)
        XCTAssertTrue(invocation.arguments.contains("permissions.frog-text.filesystem={\":root\"=\"deny\"}"))
        XCTAssertTrue(invocation.arguments.contains("permissions.frog-text.network.enabled=false"))
        XCTAssertFalse(invocation.arguments.contains("--sandbox"))
        XCTAssertFalse(invocation.arguments.contains(where: { $0.hasPrefix("sandbox_mode=") }))
        XCTAssertFalse(invocation.arguments.joined().contains("private input"))
        XCTAssertFalse(invocation.arguments.joined().contains("\\/"), "JSON slash escapes are invalid in TOML paths")
        XCTAssertEqual(invocation.arguments.last, "-")
    }

    func testCodexRejectsDeniedToolAttemptsMissingFromJSONL() async throws {
        let root = try directory()
        _ = try executable("""
        if [ "$1" = '--version' ]; then echo 'codex-cli 0.159.0'; exit; fi
        if [ "$2" = '--help' ]; then echo '--strict-config --ignore-user-config --ignore-rules --ephemeral --json'; exit; fi
        /bin/cat >/dev/null
        echo 'ERROR codex_core::tools::router: error=apply_patch verification failed: private fixture path' >&2
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"must not insert"}}'
        echo '{"type":"turn.completed"}'
        """, name: "codex", in: root)
        let client = LocalToolClient(discovery: .init(home: root, environment: [:], searchDirectories: [root]), temporaryRoot: root)
        do {
            _ = try await client.complete(.init(kind: .codex, instructions: "Rewrite", text: "text"))
            XCTFail("A denied tool attempt must reject even successful final text")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("disabled tool"))
            XCTAssertFalse(error.localizedDescription.contains("private fixture"))
        }
        let toolEvent = """
        {"type":"item.completed","item":{"type":"file_change","changes":[]}}
        {"type":"item.completed","item":{"type":"agent_message","text":"must not insert"}}
        {"type":"turn.completed"}
        """
        XCTAssertThrowsError(try LocalToolOutput.completion(Data(toolEvent.utf8), kind: .codex))
    }

    func testCodexNewMinorVersionNeedsPermissionContractVerification() async throws {
        let root = try directory()
        _ = try executable("""
        if [ "$1" = '--version' ]; then echo 'codex-cli 0.160.0'; exit; fi
        echo '--strict-config --ignore-user-config --ignore-rules --ephemeral --json'
        """, name: "codex", in: root)
        let client = LocalToolClient(discovery: .init(home: root, environment: [:], searchDirectories: [root]), temporaryRoot: root)
        let status = await client.status(for: .codex, checkAuthentication: false)
        XCTAssertTrue(status.installed)
        XCTAssertFalse(status.supportsTextTransforms)
        XCTAssertTrue(status.detail.contains("0.159.x"))
    }

    func testOutputLimitAndTimeoutAreBounded() async throws {
        let root = try directory()
        let noisy = try executable("while :; do /usr/bin/head -c 8192 /dev/zero; done", in: root)
        do {
            _ = try await LocalToolProcess.run(executable: noisy, arguments: [], environment: [:], directory: root, timeout: 3, outputLimit: 1024)
            XCTFail("Expected output limit")
        } catch { XCTAssertTrue(error.localizedDescription.contains("output limit")) }
        let sleeping = try executable("/bin/sleep 30", name: "sleeping", in: root)
        let start = ContinuousClock.now
        do {
            _ = try await LocalToolProcess.run(executable: sleeping, arguments: [], environment: [:], directory: root, timeout: 0.1)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("time limit")) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testCancellationKillsOnlyOwnedGroup() async throws {
        let root = try directory()
        let tool = try executable("echo $$ > pids\n/bin/sleep 30 &\necho $! >> pids\nwait", in: root)
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["30"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() }; unrelated.waitUntilExit() }
        let task = Task { try await LocalToolProcess.run(executable: tool, arguments: [], environment: [:], directory: root) }
        defer { task.cancel() }
        var pids: [Int32] = []
        for _ in 0..<200 {
            pids = ((try? String(contentsOf: root.appendingPathComponent("pids"), encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
            if pids.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(pids.count, 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        for _ in 0..<100 where pids.contains(where: { kill($0, 0) == 0 }) { try await Task.sleep(for: .milliseconds(10)) }
        for pid in pids { XCTAssertEqual(kill(pid, 0), -1) }
        XCTAssertTrue(unrelated.isRunning)
    }

    func testErrorsNeverExposeRawStderrOrStdoutAndModelListIsValidated() {
        let result = LocalToolProcessResult(stdout: Data("private prompt".utf8), stderr: Data("401 Bearer secret /Users/private".utf8), status: 1)
        let error = LocalToolOutput.failure(result, kind: .claudeCode).localizedDescription
        XCTAssertFalse(error.contains("secret")); XCTAssertFalse(error.contains("private"))
        XCTAssertTrue(error.contains("login"))
        XCTAssertEqual(LocalToolOutput.models(Data("openai/model\nlog message\nopenai/model\n--bad/model\n".utf8)).map(\.id), ["openai/model"])
    }

    func testFixtureProcessOverheadBenchmark() async throws {
        let root = try directory()
        let tool = try executable("echo '{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"ok\"}'", in: root)
        var samples: [Double] = []
        for _ in 0..<12 {
            let start = ContinuousClock.now
            let result = try await LocalToolProcess.run(executable: tool, arguments: [], environment: [:], directory: root)
            XCTAssertEqual(try LocalToolOutput.completion(result.stdout, kind: .claudeCode), "ok")
            let elapsed = start.duration(to: .now).components
            samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        samples.sort()
        print("LocalTool fixture spawn+parse: median \(samples[6]) ms; max \(samples.last!) ms (12 runs; no model/network)")
    }
}
