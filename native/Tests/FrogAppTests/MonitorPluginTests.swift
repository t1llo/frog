import XCTest
import FrogCore
import FrogTestSupport
import FrogUsage
@testable import FrogApp

/// System monitor and LLM usage as plugins: off means nothing runs, actions answer through the host,
/// and their settings live in config.toml.
@MainActor final class MonitorPluginTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!
    private var usage: UsageDashboardModel!
    private var usageModels = 0
    private var sampler: CountingSampler!
    private var makeSampler: (@MainActor () -> any SystemMonitorSampling)!
    private var linger: Duration!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ConfigurationStore(directory: directory).save(Configuration())
        sampler = CountingSampler()
        makeSampler = SystemMonitorPlugin.makeSampler
        let sampler = sampler!
        SystemMonitorPlugin.makeSampler = { sampler }
        linger = LLMUsagePlugin.linger
        LLMUsagePlugin.linger = .milliseconds(30)
        usage = UsageDashboardModel(defaults: temporaryDefaults(), fixtureRoot: directory.appendingPathComponent("fixtures"))
        let usage = usage!
        model = AppModel(dataDirectory: directory, registerShortcuts: false,
                         toolkit: Toolkit(makeUsage: { [unowned self] in self.usageModels += 1; return usage }, showsUsageStatusItem: false))
    }

    override func tearDown() async throws {
        model.shutdown()
        SystemMonitorPlugin.makeSampler = makeSampler
        LLMUsagePlugin.linger = linger
        try? FileManager.default.removeItem(at: directory)
    }

    private func turn(_ id: String, _ on: Bool) async throws {
        try await model.setPlugin(id, enabled: on)
        await model.pluginHost.syncAndWait()
    }

    private var configText: String {
        (try? String(contentsOf: directory.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
    }

    private func object(_ result: ActionResult) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [String: Any], result.json)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out")
    }

    // MARK: System monitor

    func testSystemMonitorOffMeansNoMonitorNoTabAndNoActions() async throws {
        try await turn("system-monitor", false)
        XCTAssertNil(model.pluginHost.running["system-monitor"])
        XCTAssertFalse(model.pluginHost.menuTabs.contains { $0.id == "system-monitor.tab" })
        do { _ = try await model.pluginHost.run("system-monitor.status", ActionInput(source: .agent)); XCTFail("The plugin is off") }
        catch { XCTAssertEqual(error.localizedDescription, ActionError.pluginOff("System monitor").localizedDescription) }
        let calls = await sampler.calls
        XCTAssertEqual(calls, 0)
    }

    func testStatusAnswersCPUGPUAndMemoryAndLeavesNothingSampling() async throws {
        try await turn("system-monitor", true)
        let plugin = try XCTUnwrap(model.pluginHost.running["system-monitor"] as? SystemMonitorPlugin)
        XCTAssertTrue(model.pluginHost.menuTabs.contains { $0.id == "system-monitor.tab" })
        let result = try await model.pluginHost.run("system-monitor.status", ActionInput(source: .agent))
        let json = try object(result)
        XCTAssertEqual(json["cpuPercent"] as? Double, 25)
        XCTAssertEqual(json["gpuPercent"] as? Double, 50)
        XCTAssertEqual((json["memory"] as? [String: Any])?["percent"] as? Double, 25)
        XCTAssertTrue(result.text.contains("CPU") && result.text.contains("25%"), result.text)
        let calls = await sampler.calls
        XCTAssertEqual(calls, 2, "Two readings a second apart, then nothing")
        XCTAssertEqual(plugin.monitor?.isSampling, false)
    }

    /// The measurement the brief asks for: with every overview closed nothing is sampled; an open one
    /// samples every two seconds.
    func testIdleWithEveryOverviewClosedSamplesNothing() async throws {
        try await turn("system-monitor", true)
        let plugin = try XCTUnwrap(model.pluginHost.running["system-monitor"] as? SystemMonitorPlugin)
        let monitor = try XCTUnwrap(plugin.monitor)
        try await Task.sleep(for: .milliseconds(300))
        var calls = await sampler.calls
        XCTAssertEqual(calls, 0, "Popup closed, no item: no sampling at all")
        XCTAssertFalse(monitor.isSampling)

        // The test runner sits in the background, where App Nap would stretch every sleep.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Timing the monitor")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        monitor.setPresented(true, for: .frogMenu)
        try await waitUntil { await self.sampler.calls >= 2 }
        let open = ContinuousClock.now
        let before = await sampler.calls
        try await Task.sleep(for: .seconds(4.1))
        calls = await sampler.calls
        let elapsed = open.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let rate = Double(calls - before) / seconds
        print("System monitor samples per second: closed 0, open \(rate)")
        XCTAssertLessThanOrEqual(rate, 0.6, "The open popup samples every two seconds")
        XCTAssertGreaterThan(calls - before, 0)
        monitor.setPresented(false, for: .frogMenu)
        XCTAssertFalse(monitor.isSampling)
    }

    func testOneRealSampleIsCheap() async {
        let sampler = NativeSystemMonitorSampler()
        _ = await sampler.sample(reset: true, full: true)
        let start = ContinuousClock.now
        for _ in 0..<20 { _ = await sampler.sample(reset: false, full: true) }
        let each = start.duration(to: .now) / 20
        print("One full system monitor sample: \(each)")
        XCTAssertLessThan(each, .milliseconds(50))
    }

    func testTheMenuBarItemActionSavesItsSettingInConfigToml() async throws {
        try await turn("system-monitor", true)
        let plugin = try XCTUnwrap(model.pluginHost.running["system-monitor"] as? SystemMonitorPlugin)
        let on = try await model.pluginHost.run("system-monitor.menu-bar-item", ActionInput(values: ["on": "true"], source: .agent))
        XCTAssertEqual(try object(on)["menuBarItem"] as? Bool, true)
        XCTAssertTrue(plugin.settings.menuBarItem)
        XCTAssertTrue(configText.contains("[system-monitor]"), configText)
        XCTAssertTrue(configText.contains("menu-bar-item = true"), configText)
        _ = try await model.pluginHost.run("system-monitor.menu-bar-item", ActionInput(source: .commandBar))
        XCTAssertFalse(plugin.settings.menuBarItem, "Without a value it toggles")
        XCTAssertNil(plugin.item, "Tests never add to the real menu bar")
    }

    func testSettingsAreSeededOnceFromTheOldPreferences() async throws {
        var preferences = model.configuration.preferences
        preferences.ensureToolkit()
        preferences.toolkit?.systemMonitor = SystemMonitorPreferences(menuBarItem: true, menuBarStyle: "bars")
        try model.savePreferences(preferences)
        try await turn("system-monitor", true)
        let plugin = try XCTUnwrap(model.pluginHost.running["system-monitor"] as? SystemMonitorPlugin)
        XCTAssertTrue(plugin.settings.menuBarItem)
        XCTAssertEqual(plugin.settings.menuBarStyle, .bars)
        XCTAssertTrue(configText.contains("menu-bar-readings = \"cpu-gpu\""), "Every key is written once, with its comment: \(configText)")
        XCTAssertTrue(configText.contains("# cpu, cpu-gpu, cpu-memory or cpu-gpu-memory"), configText)

        // An edit in the file wins; the old preferences are not read again.
        var settings = plugin.settings; settings.menuBarReadings = .cpuMemory
        try model.settingsFile.edit { try $0.update("system-monitor", settings) }
        plugin.settingsChanged()
        XCTAssertEqual(plugin.settings.menuBarReadings, .cpuMemory)
        try await turn("system-monitor", false)
        try await turn("system-monitor", true)
        let again = try XCTUnwrap(model.pluginHost.running["system-monitor"] as? SystemMonitorPlugin)
        XCTAssertEqual(again.settings.menuBarReadings, .cpuMemory)
    }

    func testASeedThatCouldNotBeWrittenStillKeepsTheOldChoices() async throws {
        var preferences = model.configuration.preferences
        preferences.ensureToolkit()
        preferences.toolkit?.systemMonitor = SystemMonitorPreferences(menuBarItem: false, menuBarStyle: "bars")
        try model.savePreferences(preferences)
        // config.toml changed outside Frog into something that does not read: nothing can be written.
        let file = directory.appendingPathComponent("config.toml")
        let valid = configText
        try "[system-monitor\n".write(to: file, atomically: true, encoding: .utf8)
        try? await model.setPlugin("system-monitor", enabled: true)
        await model.pluginHost.syncAndWait()
        let plugin = try XCTUnwrap(model.pluginHost.running["system-monitor"] as? SystemMonitorPlugin)
        XCTAssertEqual(plugin.settings.menuBarStyle, .bars, "The old choice is used although it could not be written")

        // Once the file reads again, the next choice saves the old ones with it.
        try valid.write(to: file, atomically: true, encoding: .utf8)
        _ = try await model.pluginHost.run("system-monitor.menu-bar-item", ActionInput(values: ["on": "true"], source: .agent))
        XCTAssertTrue(configText.contains("menu-bar-style = \"bars\""), configText)
        XCTAssertTrue(configText.contains("menu-bar-item = true"), configText)
    }

    // MARK: LLM usage

    func testLLMUsageOffBuildsNoModelAndReadsNothing() async throws {
        try await turn("llm-usage", false)
        XCTAssertEqual(usageModels, 0, "Off: no model, no collectors")
        XCTAssertFalse(usage.active)
        do { _ = try await model.pluginHost.run("llm-usage.status", ActionInput(source: .agent)); XCTFail("The plugin is off") }
        catch { XCTAssertEqual(error.localizedDescription, ActionError.pluginOff("LLM usage").localizedDescription) }
    }

    func testLLMUsageReadsOnlyWhileShownAndStopsAfterTheLinger() async throws {
        try await turn("llm-usage", true)
        XCTAssertEqual(usageModels, 1)
        XCTAssertFalse(usage.active, "No item and nothing on screen: nothing is read")
        usage.setPresented(true, for: .menu)
        XCTAssertTrue(usage.active, "The popup tab on screen starts reading")
        usage.setPresented(false, for: .menu)
        XCTAssertTrue(usage.active, "A scan that just began may finish")
        try await waitUntil { !self.usage.active }

        try await turn("llm-usage", false)
        usage.setActive(true)
        XCTAssertFalse(usage.active, "A late visibility callback cannot restart a plugin that is off")
    }

    func testStatusListsEachProviderOrOne() async throws {
        try await turn("llm-usage", true)
        let both = try await model.pluginHost.run("llm-usage.status", ActionInput(source: .agent))
        let providers = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(both.json.utf8)) as? [[String: Any]])
        XCTAssertEqual(providers.compactMap { $0["provider"] as? String }, ["Claude", "OpenAI"])
        XCTAssertTrue(both.text.contains("Claude") && both.text.contains("OpenAI"), both.text)
        let one = try await model.pluginHost.run("llm-usage.status", ActionInput(values: ["provider": "openai"], source: .agent))
        let only = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(one.json.utf8)) as? [[String: Any]])
        XCTAssertEqual(only.compactMap { $0["provider"] as? String }, ["OpenAI"])
        try await waitUntil { !self.usage.active }
    }

    func testChoicesMadeInAViewAndByActionsLandInConfigToml() async throws {
        try await turn("llm-usage", true)
        let plugin = try XCTUnwrap(model.pluginHost.running["llm-usage"] as? LLMUsagePlugin)
        XCTAssertTrue(configText.contains("[llm-usage]"), configText)
        usage.selectProvider("OpenAI")
        XCTAssertEqual(plugin.settings.provider, .openai)
        XCTAssertTrue(configText.contains("provider = \"openai\""), configText)

        _ = try await model.pluginHost.run("llm-usage.menu-bar-item", ActionInput(values: ["on": "false"], source: .agent))
        XCTAssertFalse(plugin.settings.menuBarItem)
        XCTAssertTrue(configText.contains("menu-bar-item = false"), configText)

        // An edit in the file reaches the model.
        var settings = plugin.settings; settings.range = .month
        try model.settingsFile.edit { try $0.update("llm-usage", settings) }
        plugin.settingsChanged()
        XCTAssertEqual(usage.preferences.range, "30d")
        let refreshed = try await model.pluginHost.run("llm-usage.refresh", ActionInput(source: .commandBar))
        XCTAssertEqual(refreshed.text, "Refreshing LLM usage.")
    }
}

/// Counts readings and gives the same load every time, so no test depends on this Mac's.
private actor CountingSampler: SystemMonitorSampling {
    private(set) var calls = 0
    func sample(reset: Bool, full: Bool) async -> SystemMonitorSnapshot {
        calls += 1
        return SystemMonitorSnapshot(cpu: .value(0.25), gpu: .value(0.5), memory: SystemMonitorMemory(used: 4, total: 16))
    }
}
