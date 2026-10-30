import XCTest
import SwiftUI
@testable import FrogApp

@MainActor
final class PluginHostTests: XCTestCase {
    private final class Probe: FrogPlugin {
        static let info = PluginInfo(id: "probe", name: "Probe", symbol: "circle", tint: .blue, category: .navigate, summary: "A test plugin")
        static var log: [String] = []
        init() {}
        func start() async { Self.log.append("start") }
        func stop() async { Self.log.append("stop") }
        var actions: [PluginAction] {
            [PluginAction(id: "probe.echo", title: "Echo",
                          parameters: [ActionParameter(name: "word", required: true),
                                       ActionParameter(name: "mode", kind: .choice(["loud", "quiet"]))]) { input in
                .done(try input.required("word") + (input.value("mode") == "loud" ? "!" : ""))
            }]
        }
        var menu: [MenuContribution] {
            [MenuContribution(id: "probe.tab", placement: .tab(title: "Probe", symbol: "circle"), order: 5) { AnyView(EmptyView()) },
             MenuContribution(id: "probe.row", order: 1) { AnyView(EmptyView()) }]
        }
    }

    private var enabled: Set<String> = []

    private func makeHost() -> PluginHost {
        Probe.log = []
        let host = PluginHost(descriptors: [PluginDescriptor(Probe.self) { _ in Probe() }],
                              isEnabled: { [unowned self] in self.enabled.contains($0) },
                              setEnabled: { [unowned self] id, on in if on { self.enabled.insert(id) } else { self.enabled.remove(id) } })
        let model = AppModel(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), registerShortcuts: false)
        host.attach { [unowned host] in PluginContext(info: $0, host: host, legacy: model) }
        addTeardownBlock { model.shutdown() }
        return host
    }

    func testTurningOnStartsAndTurningOffStops() async throws {
        let host = makeHost()
        await host.syncAndWait()
        XCTAssertTrue(host.actions.isEmpty)
        try await host.setEnabled("probe", true)
        XCTAssertEqual(Probe.log, ["start"])
        XCTAssertEqual(host.sidebar.map(\.category), [.navigate])
        XCTAssertEqual(host.menuRows.map(\.id), ["probe.row"])
        XCTAssertEqual(host.menuTabs.map(\.tabTitle), ["Probe"])
        // A second sync while on does not start it twice.
        await host.syncAndWait()
        XCTAssertEqual(Probe.log, ["start"])
        try await host.setEnabled("probe", false)
        XCTAssertEqual(Probe.log, ["start", "stop"])
        XCTAssertTrue(host.menuRows.isEmpty)
    }

    func testRunChecksParametersAndSaysWhenThePluginIsOff() async throws {
        let host = makeHost()
        await host.syncAndWait()
        do { _ = try await host.run("probe.echo", ActionInput(source: .agent)); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, ActionError.pluginOff("Probe").localizedDescription) }

        try await host.setEnabled("probe", true)
        do { _ = try await host.run("probe.echo", ActionInput(source: .agent)); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, ActionError.missing("word").localizedDescription) }
        do { _ = try await host.run("probe.echo", ActionInput(values: ["word": "hi", "mode": "shout"], source: .agent)); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("loud, quiet")) }
        let result = try await host.run("probe.echo", ActionInput(values: ["word": "hi", "mode": "loud"], source: .agent))
        XCTAssertEqual(result.text, "hi!")
        do { _ = try await host.run("probe.nothing", ActionInput(source: .agent)); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, ActionError.unknown("probe.nothing").localizedDescription) }
    }

    func testEveryBuiltinPluginHasAUniqueIDAndALegacySwitch() {
        let ids = BuiltinPlugins.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids where id != "history" {
            XCTAssertNotNil(BuiltinPlugins.legacyFeatures[id], "\(id) has no feature switch")
        }
        for descriptor in BuiltinPlugins.all {
            XCTAssertLessThanOrEqual(descriptor.info.summary.count, 50, "\(descriptor.id)'s summary is too long")
        }
    }
}
