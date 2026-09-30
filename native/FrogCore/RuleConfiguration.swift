import Foundation

/// A concrete choice, also used to remember the most recently added compatible models.
/// A nil provider identifies a model downloaded inside Frog.
public struct RuleModelSelection: Codable, Hashable, Sendable {
    public var providerID: UUID?
    public var modelID: String
    public var category: ProviderModel.Category
    public init(providerID: UUID? = nil, modelID: String, category: ProviderModel.Category) {
        self.providerID = providerID; self.modelID = modelID; self.category = category
    }
    public func apply(to rule: inout Rule) {
        if rule.action == nil { rule.action = RuleAction(category: rule.category) }
        if category == .audio {
            rule.action?.audioModelID = modelID; rule.action?.audioProviderID = providerID
            rule.action?.transcriptionLanguage = nil
        } else {
            rule.providerID = providerID
            rule.model = providerID == nil ? "" : modelID
            rule.action?.localTextModelID = providerID == nil ? modelID : nil
        }
    }
}

extension Configuration {
    /// Reconcile a draft against the current inventory without overwriting its other edits.
    public func reconcilingModels(in rule: Rule, installed: Set<String>) -> Rule {
        var draft = self
        draft.rules = [rule]
        draft.reconcileUnavailableModels(installed: installed)
        return draft.rules[0]
    }

    /// Recover saved selections whose downloads disappeared between app launches.
    /// An intentionally empty selection is never filled by this reconciliation.
    public mutating func reconcileUnavailableModels(installed: Set<String>) {
        let unavailable = rules.flatMap { rule -> [RuleModelSelection] in
            let audio = rule.action?.audioModelID.map { RuleModelSelection(providerID: rule.action?.audioProviderID, modelID: $0, category: .audio) }
            let text = rule.action?.localTextModelID.map { RuleModelSelection(modelID: $0, category: .text) }
                ?? rule.providerID.flatMap { id in rule.model.isEmpty ? nil : RuleModelSelection(providerID: id, modelID: rule.model, category: .text) }
            return [audio, text].compactMap { $0 }.filter { !selectionAvailable($0, installed: installed) }
        }
        guard !unavailable.isEmpty else { return }
        modelsRemoved(unavailable, installed: installed)
    }

    /// Materialize legacy defaults once. Later additions never reroute an existing selection.
    public mutating func adoptExplicitRuleSettings(installed: Set<String>) {
        guard explicitRuleModels != true else { return }
        let workflow = preferences.workflowSettings
        for index in rules.indices {
            guard !rules[index].category.isShortcut else { continue }
            if rules[index].action == nil { rules[index].action = RuleAction() }
            if rules[index].category == .audio {
                if rules[index].action?.audioModelID == nil, installed.contains(workflow.audioModelID) {
                    rules[index].action?.audioModelID = workflow.audioModelID
                }
                var action = rules[index].action ?? RuleAction(category: .audio)
                action.recordingMode = action.recordingMode ?? workflow.recordingMode
                action.output = action.output ?? workflow.output
                action.showRecordingPopup = action.showRecordingPopup ?? workflow.showDictationPopup
                action.transcriptionLanguage = action.transcriptionLanguage ?? workflow.transcriptionLanguage
                rules[index].action = action
                if rules[index].preset, rules[index].name == "Dictate", rules[index].hotkey == nil,
                   !rules.contains(where: { $0.enabled && $0.hotkey == Rule.dictationPreset.hotkey }) {
                    rules[index].hotkey = Rule.dictationPreset.hotkey
                }
                if rules[index].action?.cleanup != true { continue }
            }
            if rules[index].action?.localTextModelID != nil { continue }
            if rules[index].providerID == nil, rules[index].category == .audio {
                if installed.contains(workflow.cleanupModelID) { rules[index].action?.localTextModelID = workflow.cleanupModelID }
            } else if rules[index].providerID == nil, workflow.effectiveTextSource == .frog {
                let id = workflow.defaultLocalTextModelID ?? "qwen-0.6b"
                if installed.contains(id) { rules[index].action?.localTextModelID = id }
            } else if let provider = providers.first(where: { $0.id == (rules[index].providerID ?? defaultProviderID) }) {
                rules[index].providerID = provider.id
                if rules[index].model.isEmpty { rules[index].model = provider.model }
            }
        }
        explicitRuleModels = true
        var appearance = preferences.appearance ?? AppearancePreferences()
        if appearance.mode == nil || appearance.mode == .system { appearance.mode = .dark }
        preferences.appearance = appearance
        // Historical addition order is unavailable for downloads; use stable catalog order once.
        recentModels = modelCatalog.filter { installed.contains($0.id) }.map {
            RuleModelSelection(modelID: $0.id, category: $0.kind == .audio ? .audio : .text)
        } + providers.flatMap { provider in provider.models.map {
            RuleModelSelection(providerID: provider.id, modelID: $0.id, category: $0.category)
        } }
    }

    public func selectionAvailable(_ selection: RuleModelSelection, installed: Set<String>) -> Bool {
        if let id = selection.providerID {
            return providers.first(where: { $0.id == id })?.models.contains(where: { $0.id == selection.modelID && $0.category == selection.category }) == true
        }
        return installed.contains(selection.modelID) && localModel(selection.modelID)?.kind == (selection.category == .audio ? .audio : .text)
    }

    public mutating func modelAdded(_ selection: RuleModelSelection) {
        var recent = recentModels ?? []
        recent.removeAll { $0 == selection }; recent.append(selection); recentModels = recent
        // Only untouched, unconfigured factory rules receive their first compatible model.
        for index in rules.indices where rules[index].preset {
            if selection.category == .audio, rules[index].category == .audio, rules[index].action?.audioModelID == nil {
                selection.apply(to: &rules[index])
            } else if selection.category == .text, rules[index].category == .text,
                      rules[index].providerID == nil, rules[index].model.isEmpty, rules[index].action?.localTextModelID == nil {
                selection.apply(to: &rules[index])
            }
        }
    }

    /// Replace only deleted selections. Local rules stay local; external rules prefer
    /// another model from the same provider, then an installed local alternative.
    public mutating func modelsRemoved(_ removed: [RuleModelSelection], installed: Set<String>) {
        let removed = Set(removed)
        let local = modelCatalog.filter { installed.contains($0.id) }.map {
            RuleModelSelection(modelID: $0.id, category: $0.kind == .audio ? .audio : .text)
        }
        let external = providers.flatMap { provider in provider.models.map {
            RuleModelSelection(providerID: provider.id, modelID: $0.id, category: $0.category)
        } }
        let available = (Array((recentModels ?? []).reversed()) + local + external).filter {
            !removed.contains($0) && selectionAvailable($0, installed: installed)
        }
        func replacement(for selection: RuleModelSelection) -> RuleModelSelection? {
            let compatible = available.filter { $0.category == selection.category }
            if let sameSource = compatible.first(where: { $0.providerID == selection.providerID }) { return sameSource }
            guard selection.providerID != nil else { return nil }
            return compatible.first(where: { $0.providerID == nil }) ?? compatible.first
        }
        for index in rules.indices {
            if let id = rules[index].action?.audioModelID {
                let selection = RuleModelSelection(providerID: rules[index].action?.audioProviderID, modelID: id, category: .audio)
                if removed.contains(selection) {
                    rules[index].action?.audioModelID = nil; rules[index].action?.audioProviderID = nil
                    replacement(for: selection)?.apply(to: &rules[index])
                    rules[index].preset = false
                }
            }
            let selection = rules[index].action?.localTextModelID.map { RuleModelSelection(modelID: $0, category: .text) }
                ?? rules[index].providerID.map { RuleModelSelection(providerID: $0, modelID: rules[index].model, category: .text) }
            if let selection, removed.contains(selection) {
                rules[index].providerID = nil; rules[index].model = ""; rules[index].action?.localTextModelID = nil
                replacement(for: selection)?.apply(to: &rules[index])
                rules[index].preset = false
            }
        }
        recentModels?.removeAll { removed.contains($0) }
    }

    public func newRule(category: RuleCategory, installed: Set<String>) -> Rule {
        var rule = category == .audio ? Rule.dictationPreset : Rule()
        rule.id = UUID(); rule.preset = false; rule.hotkey = nil
        rule.name = category == .audio ? "New audio rule" : category == .application ? "Open application" : "New text rule"
        rule.action = RuleAction(category: category)
        rule.action?.recordingMode = .toggle; rule.action?.output = .copy; rule.action?.showRecordingPopup = true
        if category.isShortcut { rule.instructions = ""; return rule }
        let kind: ProviderModel.Category = category == .audio ? .audio : .text
        if let selection = recentModels?.last(where: { $0.category == kind && selectionAvailable($0, installed: installed) }) {
            selection.apply(to: &rule)
        }
        return rule
    }
}

extension ProviderKind {
    public var supportsTranscription: Bool { [.openAI, .gemini, .compatible].contains(self) }
}
