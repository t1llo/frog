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
            CompactRow(title: "Let AI agents use Frog") {
                Toggle("Let AI agents use Frog", isOn: Binding(get: { access }, set: { value in
                    do { try model.setAgentAccess(value) } catch { model.report(error) }
                })).labelsHidden()
            }
            if access, let issue = server.issue { Text(issue).font(FrogType.caption).foregroundStyle(FrogStyle.warning).fixedSize(horizontal: false, vertical: true) }
            SectionCaption(text: "Command and skills").padding(.top, 6)
            AgentToolRow(installation: installation)
            ForEach(AgentInstaller.skillFolders) { folder in
                AgentSkillRow(installation: installation, folder: folder)
            }
            if let issue = installation.issue { InlineIssue(message: issue) }
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
                    Button("Remove") { installation.perform(installer.removeTool) }.buttonStyle(.frog(.destructive))
                case .otherCopy:
                    Button("Relink") { installation.perform(installer.installTool) }
                    Button("Remove") { installation.perform(installer.removeTool) }.buttonStyle(.frog(.destructive))
                case .blocked:
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([installer.linkURL]) }
                }
            }
        }
        if installation.tool == .installed, !installation.shellFindsTool {
            let path = AgentInstaller.pathLine(shell: AgentInstaller.loginShell)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("If Terminal can’t find frog, add this line to \(path.file):").font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                    Text(path.line).font(FrogType.mono).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                CopyAction(title: "Copy line") { ViewActions.copy(path.line) }
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
                    if !installation.found(folder) { Text("Not found").font(FrogType.small).foregroundStyle(FrogStyle.muted) }
                    Button("Install") { installation.perform { try installer.installSkill(folder) } }
                case .installed:
                    AgentInstalledLabel()
                    Button("Remove") { installation.perform { try installer.removeSkill(folder) } }.buttonStyle(.frog(.destructive))
                case .outdated:
                    Button("Update") { installation.perform { try installer.installSkill(folder) } }
                    Button("Remove") { installation.perform { try installer.removeSkill(folder) } }.buttonStyle(.frog(.destructive))
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
        Label("Installed", systemImage: "checkmark.circle.fill").font(FrogType.small).foregroundStyle(FrogStyle.accent)
    }
}
