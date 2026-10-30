import Observation
import SwiftUI

/// Creates, starts and stops plugins as they are turned on and off, and collects what they contribute.
@MainActor @Observable final class PluginHost {
    let descriptors: [PluginDescriptor]
    private(set) var running: [String: any FrogPlugin] = [:]
    /// Shows a plugin's page in the main window; set by the app model, which owns navigation.
    @ObservationIgnored var openPage: ((String) -> Void)?

    @ObservationIgnored private let isEnabled: (String) -> Bool
    @ObservationIgnored private let writeEnabled: (String, Bool) async throws -> Void
    @ObservationIgnored private var makeContext: ((PluginInfo) -> PluginContext)?
    @ObservationIgnored private var syncing: Task<Void, Never>?

    init(descriptors: [PluginDescriptor], isEnabled: @escaping (String) -> Bool,
         setEnabled: @escaping (String, Bool) async throws -> Void) {
        self.descriptors = descriptors
        self.isEnabled = isEnabled
        writeEnabled = setEnabled
    }

    func attach(context: @escaping (PluginInfo) -> PluginContext) { makeContext = context }

    func descriptor(_ id: String) -> PluginDescriptor? { descriptors.first { $0.id == id } }
    func enabled(_ id: String) -> Bool { isEnabled(id) }

    /// The plugins that are on, by sidebar category, in catalog order.
    var sidebar: [(category: PluginCategory, plugins: [PluginInfo])] {
        let on = descriptors.map(\.info).filter { isEnabled($0.id) }
        return PluginCategory.allCases.compactMap { category in
            let plugins = on.filter { $0.category == category }
            return plugins.isEmpty ? nil : (category, plugins)
        }
    }

    // MARK: Lifecycle

    /// Starts plugins that were turned on and stops those turned off. Safe to call after every configuration change.
    func sync() {
        let previous = syncing
        syncing = Task { [weak self] in
            await previous?.value
            await self?.reconcile()
        }
    }

    /// Syncs and waits until every plugin that is on has started.
    func syncAndWait() async {
        sync()
        await syncing?.value
    }

    private func reconcile() async {
        for descriptor in descriptors {
            let on = isEnabled(descriptor.id)
            if on, running[descriptor.id] == nil, let makeContext {
                let plugin = descriptor.make(makeContext(descriptor.info))
                running[descriptor.id] = plugin
                await plugin.start()
            } else if !on, let plugin = running.removeValue(forKey: descriptor.id) {
                await plugin.stop()
            }
        }
    }

    /// Tells every running plugin that config.toml changed.
    func settingsChanged() {
        for descriptor in descriptors { running[descriptor.id]?.settingsChanged() }
    }

    func setEnabled(_ id: String, _ enabled: Bool) async throws {
        try await writeEnabled(id, enabled)
        sync()
        await syncing?.value
    }

    func stopAll() async {
        await syncing?.value
        for (_, plugin) in running { await plugin.stop() }
        running = [:]
    }

    /// Stops every plugin, as at quit, but returns after `timeout` even if one has not finished,
    /// so a plugin that hangs cannot keep Frog from quitting.
    func stopAll(timeout: Duration) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var resumed = false
            func finish() { if !resumed { resumed = true; done.resume() } }
            Task { @MainActor in await self.stopAll(); finish() }
            Task { @MainActor in try? await Task.sleep(for: timeout); finish() }
        }
    }

    // MARK: Navigation

    func open(_ id: String) { openPage?(id) }

    func page(for id: String) -> AnyView? { running[id]?.page() }

    // MARK: Contributions

    /// Every action of the plugins that are on, in catalog order.
    var actions: [PluginAction] {
        descriptors.flatMap { running[$0.id]?.actions ?? [] }
    }

    func action(_ id: String) -> PluginAction? { actions.first { $0.id == id } }

    func run(_ id: String, _ input: ActionInput) async throws -> ActionResult {
        guard let action = action(id) else {
            let plugin = String(id.prefix { $0 != "." })
            if let descriptor = descriptor(plugin), !isEnabled(plugin) { throw ActionError.pluginOff(descriptor.info.name) }
            throw ActionError.unknown(id)
        }
        for parameter in action.parameters where parameter.required && (input.values[parameter.name] ?? "").isEmpty {
            throw ActionError.missing(parameter.name)
        }
        for parameter in action.parameters {
            guard case .choice(let options) = parameter.kind, let value = input.values[parameter.name] else { continue }
            guard options.contains(value) else { throw ActionError.invalid(parameter.name, "one of \(options.joined(separator: ", "))") }
        }
        return try await action.run(input)
    }

    var menuRows: [MenuContribution] {
        contributions.filter { $0.placement == .row }
    }

    var menuTabs: [MenuContribution] {
        contributions.filter { $0.placement != .row }
    }

    private var contributions: [MenuContribution] {
        descriptors.flatMap { running[$0.id]?.menu ?? [] }.enumerated()
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map(\.element)
    }
}
