import AppKit
import FrogCore
import SwiftUI

/// What is installed of the `frog` command and the agents' skill, read again after every change.
@MainActor final class AgentInstallation: ObservableObject {
    let installer: AgentInstaller
    @Published private(set) var tool: AgentInstaller.ToolState = .notInstalled
    @Published private(set) var skills: [String: AgentInstaller.SkillState] = [:]
    @Published private(set) var detected: Set<CodingAgent> = []
    @Published private(set) var shellFindsTool = true
    @Published var issue: String?

    init(installer: AgentInstaller = .live) {
        self.installer = installer
        refresh()
    }

    func refresh() {
        tool = installer.toolState()
        skills = Dictionary(uniqueKeysWithValues: AgentInstaller.skillFolders.map { ($0.id, installer.skillState($0)) })
        detected = installer.detectedAgents()
        shellFindsTool = installer.shellFindsLocalBin()
    }

    func state(_ folder: AgentInstaller.SkillFolder) -> AgentInstaller.SkillState { skills[folder.id] ?? .notInstalled }
    /// Whether one of the agents that read this folder is on this Mac.
    func found(_ folder: AgentInstaller.SkillFolder) -> Bool { !detected.isDisjoint(with: folder.agents) }

    func perform(_ action: () throws -> Void) {
        do { try action(); issue = nil } catch { issue = error.localizedDescription }
        refresh()
    }
}

/// Settings → Agents.
struct AgentSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var server: AgentServer
    @StateObject private var installation: AgentInstallation

    init(server: AgentServer, installer: AgentInstaller = .live) {
        self.server = server
        _installation = StateObject(wrappedValue: AgentInstallation(installer: installer))
    }

    private var access: Bool { model.configuration.preferences.toolkitSettings.agentAccess == true }

    var body: some View {
        SettingsSection(title: "Agents") {
            CompactRow(title: "Let AI agents use Frog", detail: access && server.isListening ? "Listening for the frog command." : nil) {
                Toggle("Let AI agents use Frog", isOn: Binding(get: { access }, set: { value in
                    do { try model.setAgentAccess(value) } catch { model.report(error) }
                })).labelsHidden()
            }
            if access, let issue = server.issue { Text(issue).font(.caption).foregroundStyle(FrogStyle.warning).fixedSize(horizontal: false, vertical: true) }
            Divider()
            AgentToolRow(installation: installation)
            ForEach(AgentInstaller.skillFolders) { folder in
                Divider()
                AgentSkillRow(installation: installation, folder: folder)
            }
            if let issue = installation.issue { InlineIssue(message: issue) }
            Divider()
            Text("Try it in Terminal: `frog status`").font(.caption).foregroundStyle(FrogStyle.muted)
        }.onAppear { installation.refresh() }
    }
}

private struct AgentToolRow: View {
    @ObservedObject var installation: AgentInstallation
    private var installer: AgentInstaller { installation.installer }

    var body: some View {
        CompactRow(title: "Command line tool", detail: detail) {
            HStack(spacing: 10) {
                switch installation.tool {
                case .unavailable: EmptyView()
                case .notInstalled:
                    Button("Install") { installation.perform(installer.installTool) }
                case .installed:
                    AgentInstalledLabel()
                    Button("Remove") { installation.perform(installer.removeTool) }
                case .otherCopy:
                    Button("Relink") { installation.perform(installer.installTool) }
                    Button("Remove") { installation.perform(installer.removeTool) }
                case .blocked:
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([installer.linkURL]) }
                }
            }
        }
        if installation.tool == .installed, !installation.shellFindsTool {
            let path = AgentInstaller.pathLine(shell: AgentInstaller.loginShell)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("If Terminal can’t find frog, add this line to \(path.file):").font(.caption).foregroundStyle(FrogStyle.muted)
                    Text(path.line).font(FrogType.mono).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                IconAction(title: "Copy line", symbol: "doc.on.doc") { ViewActions.copy(path.line) }
            }
        }
    }

    private var detail: String {
        switch installation.tool {
        case .unavailable(let reason): reason
        case .notInstalled, .installed: installer.linkDisplayPath
        case .otherCopy(let path): "Links to another Frog: \((path as NSString).abbreviatingWithTildeInPath)"
        case .blocked: "\(installer.linkDisplayPath) is not Frog’s."
        }
    }
}

private struct AgentSkillRow: View {
    @ObservedObject var installation: AgentInstallation
    let folder: AgentInstaller.SkillFolder
    private var installer: AgentInstaller { installation.installer }

    var body: some View {
        CompactRow(title: folder.title, detail: detail) {
            HStack(spacing: 10) {
                switch installation.state(folder) {
                case .notInstalled:
                    if !installation.found(folder) { Text("Not found").font(.system(size: 11)).foregroundStyle(FrogStyle.muted) }
                    Button("Install") { installation.perform { try installer.installSkill(folder) } }
                case .installed:
                    AgentInstalledLabel()
                    Button("Remove") { installation.perform { try installer.removeSkill(folder) } }
                case .outdated:
                    Button("Update") { installation.perform { try installer.installSkill(folder) } }
                    Button("Remove") { installation.perform { try installer.removeSkill(folder) } }
                case .blocked:
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([installer.skillFolderURL(folder)]) }
                }
            }
        }
    }

    private var detail: String {
        switch installation.state(folder) {
        case .blocked: "\(installer.displayPath(folder)) holds another frog skill."
        default: "Skill in \(installer.displayPath(folder))"
        }
    }
}

private struct AgentInstalledLabel: View {
    var body: some View {
        Label("Installed", systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(FrogStyle.accent)
    }
}

/// The setup assistant's AI agents step. Nothing changes until the button is pressed.
struct AgentSetupStep: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var installation: AgentInstallation
    @State private var tool = false
    @State private var folders: Set<String> = []
    @State private var chosen = false

    init(installer: AgentInstaller = .live) {
        _installation = StateObject(wrappedValue: AgentInstallation(installer: installer))
    }

    private var access: Bool { model.configuration.preferences.toolkitSettings.agentAccess == true }
    private var toolChoosable: Bool { installation.tool == .notInstalled || isOtherCopy }
    private var isOtherCopy: Bool { if case .otherCopy = installation.tool { true } else { false } }

    var body: some View {
        SettingsSection(title: "Let AI agents use Frog") {
            Text("Claude Code, Codex and other agents can then arrange windows, run your scripts and more through the frog command.")
                .font(.caption).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
            Divider()
            option("Command line tool", detail: toolDetail, isOn: Binding(get: { tool || installation.tool == .installed }, set: { tool = $0 }),
                   enabled: toolChoosable)
            ForEach(AgentInstaller.skillFolders) { folder in
                Divider()
                option(folder.title, detail: skillDetail(folder), isOn: Binding(
                    get: { folders.contains(folder.id) || installation.state(folder) == .installed },
                    set: { if $0 { folders.insert(folder.id) } else { folders.remove(folder.id) } }),
                       enabled: [.notInstalled, .outdated].contains(installation.state(folder)))
            }
            Divider()
            HStack(spacing: 10) {
                Button(tool || !folders.isEmpty ? "Turn on and install" : "Turn on agent access") { apply() }
                    .disabled(access && !tool && folders.isEmpty)
                if access { Label("Agents can use Frog", systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(FrogStyle.accent) }
            }
            if let issue = installation.issue { InlineIssue(message: issue) }
        }.onAppear(perform: choose)
    }

    /// Ticks what is found on this Mac and not yet installed, once.
    private func choose() {
        installation.refresh()
        guard !chosen else { return }
        chosen = true
        tool = toolChoosable
        folders = Set(AgentInstaller.skillFolders.filter {
            installation.found($0) && [.notInstalled, .outdated].contains(installation.state($0))
        }.map(\.id))
    }

    private func apply() {
        do { try model.setAgentAccess(true) } catch { installation.issue = error.localizedDescription; return }
        var failures: [String] = []
        if tool, toolChoosable {
            do { try installation.installer.installTool() } catch { failures.append(error.localizedDescription) }
        }
        for folder in AgentInstaller.skillFolders where folders.contains(folder.id) {
            do { try installation.installer.installSkill(folder) } catch { failures.append(error.localizedDescription) }
        }
        installation.refresh()
        installation.issue = failures.isEmpty ? nil : failures.joined(separator: "\n")
        tool = false
        folders = []
    }

    private var toolDetail: String {
        switch installation.tool {
        case .unavailable(let reason): reason
        case .installed: "Installed in \(installation.installer.linkDisplayPath)"
        case .blocked: "\(installation.installer.linkDisplayPath) is not Frog’s."
        case .notInstalled, .otherCopy: installation.installer.linkDisplayPath
        }
    }

    private func skillDetail(_ folder: AgentInstaller.SkillFolder) -> String {
        switch installation.state(folder) {
        case .installed: "Skill installed"
        case .blocked: "\(installation.installer.displayPath(folder)) holds another frog skill."
        case .outdated: "Skill can be updated"
        case .notInstalled: installation.found(folder) ? "Found on this Mac" : "Not found"
        }
    }

    private func option(_ title: String, detail: String, isOn: Binding<Bool>, enabled: Bool) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(title)).font(.system(size: 12))
                Text(L10n.text(detail)).font(.system(size: 10)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
            }.padding(.leading, 4)
        }.toggleStyle(.checkbox).disabled(!enabled).padding(.vertical, 3)
    }
}
