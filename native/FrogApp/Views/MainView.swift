import SwiftUI
import AppKit
import FrogCore

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var section: Section = .rules

    private enum Section: String, CaseIterable, Identifiable {
        case rules = "Rules", providers = "Providers", manual = "Try text", history = "History", settings = "Settings"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .rules: "square.stack.3d.up"
            case .providers: "cpu"
            case .manual: "square.and.pencil"
            case .history: "clock.arrow.circlepath"
            case .settings: "slider.horizontal.3"
            }
        }
        var key: KeyEquivalent {
            switch self {
            case .rules: "1"
            case .providers: "2"
            case .manual: "3"
            case .history: "4"
            case .settings: "5"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 208)
            Rectangle().fill(FrogStyle.border).frame(width: 1)
            VStack(spacing: 0) {
                Group {
                    switch section {
                    case .rules: RulesView()
                    case .providers: ProvidersView()
                    case .manual: ManualView()
                    case .history: HistoryView()
                    case .settings: PreferencesView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let error = model.errorMessage {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                        Text(error).font(.system(size: 12)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Dismiss") { model.dismissError() }.buttonStyle(FrogButtonStyle())
                    }.padding(16).background(FrogStyle.surface)
                        .overlay(alignment: .top) { Rectangle().fill(FrogStyle.border).frame(height: 1) }
                }
            }.background(FrogStyle.canvas)
        }
        .font(.system(size: 13)).foregroundStyle(FrogStyle.ink)
        .tint(FrogStyle.accent).buttonStyle(FrogButtonStyle())
        .frame(minWidth: 940, minHeight: 660)
        .onAppear { model.refreshSystemStatus() }
        .task { await model.monitorSystemStatus() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshSystemStatus() } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                FrogMark()
                VStack(alignment: .leading, spacing: 1) {
                    Text("frog").font(.system(size: 26, weight: .bold, design: .rounded)).tracking(-1)
                    Text("A little writing magic").font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                }
            }.padding(.horizontal, 22).padding(.top, 28).padding(.bottom, 36)

            SectionCaption(text: "Workspace").padding(.horizontal, 25).padding(.bottom, 12)
            VStack(spacing: 5) {
                ForEach(Section.allCases) { item in
                    Button { section = item } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.symbol).font(.system(size: 15, weight: .medium)).frame(width: 20)
                            Text(item.rawValue).font(.system(size: 13, weight: section == item ? .semibold : .medium))
                            Spacer()
                            if section == item { Circle().fill(FrogStyle.accent).frame(width: 5, height: 5) }
                        }
                        .foregroundStyle(section == item ? FrogStyle.accent : FrogStyle.muted)
                        .padding(.horizontal, 13).padding(.vertical, 12)
                        .background(section == item ? FrogStyle.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).keyboardShortcut(item.key, modifiers: .command)
                        .accessibilityAddTraits(section == item ? .isSelected : [])
                        .help("\(item.rawValue) (Command–\(String(item.key.character)))")
                }
            }.padding(.horizontal, 13)
            Spacer(minLength: 24)
            if model.configuration.providers.isEmpty || !model.accessibilityGranted {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(FrogStyle.accent)
                    Text(model.configuration.providers.isEmpty ? "Make yourself at home" : "One more little step")
                        .font(.system(size: 12, weight: .semibold))
                    Text(model.configuration.providers.isEmpty ? "Connect a model to put your words to work." : "Allow Accessibility to rewrite text right where you type.")
                        .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
                    Button(model.configuration.providers.isEmpty ? "Connect a provider" : "Finish setup") {
                        section = model.configuration.providers.isEmpty ? .providers : .settings
                    }.buttonStyle(FrogButtonStyle()).controlSize(.small)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(FrogStyle.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 13).padding(.bottom, 18)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    if model.isProcessing { ProgressView().controlSize(.mini) }
                    else { Circle().fill(model.errorMessage == nil ? FrogStyle.accent : .orange).frame(width: 6, height: 6) }
                    Text(model.status).font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                        .lineLimit(4).textSelection(.enabled).help(model.status)
                }
                if model.isProcessing { Button("Cancel request") { model.cancelProcessing() } }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(FrogStyle.border).frame(height: 1) }
        }.background(FrogStyle.sidebar)
    }
}

enum ViewActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct EditorHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        PageHeader(title: title, subtitle: subtitle).padding(24)
    }
}

struct InlineIssue: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.system(size: 12)).foregroundStyle(FrogStyle.ink)
            .fixedSize(horizontal: false, vertical: true).padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }
}
