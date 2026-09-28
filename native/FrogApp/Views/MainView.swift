import SwiftUI
import AppKit
import FrogCore

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var section: Section = .rules

    private enum Section: String, CaseIterable, Identifiable {
        case rules = "Rules", history = "History", providers = "Models", shortcuts = "Shortcuts", settings = "Settings"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .rules: "square.stack.3d.up"
            case .providers: "cpu"
            case .history: "clock.arrow.circlepath"
            case .settings: "slider.horizontal.3"
            case .shortcuts: "command"
            }
        }
        var key: KeyEquivalent {
            switch self {
            case .rules: "1"
            case .history: "2"
            case .providers: "3"
            case .shortcuts: "4"
            case .settings: "5"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.padding(.top, 32).frame(width: 190).background(FrogStyle.sidebar)
            VStack(spacing: 0) {
                Group {
                    switch section {
                    case .rules: RulesView()
                    case .providers: ProvidersView()
                    case .history: HistoryView()
                    case .settings: PreferencesView()
                    case .shortcuts: RulesView(applications: true)
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
            }.clipped().padding(.top, 32).background(FrogStyle.canvas)
        }
        .font(.system(size: 13)).foregroundStyle(FrogStyle.ink)
        .environment(\.locale, L10n.locale)
        .background(FrogWindowMaterial())
        .ignoresSafeArea(.container, edges: .top)
        .tint(FrogStyle.accent).buttonStyle(FrogButtonStyle())
        .frame(minWidth: 740, minHeight: 520)
        .onAppear { model.refreshSystemStatus() }
        .task { await model.monitorSystemStatus() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshSystemStatus() } }
        .onChange(of: model.configuration.preferences.shortcutsEnabled) { _, enabled in if !enabled && section == .shortcuts { section = .settings } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                FrogMark()
                Text("frog").font(.system(size: 24, weight: .semibold, design: .rounded)).tracking(-0.8)
            }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 28)

            VStack(spacing: 4) {
                ForEach(Section.allCases.filter { $0 != .shortcuts || model.configuration.preferences.shortcutsEnabled }) { item in
                    Button { section = item } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.symbol).font(.system(size: 15, weight: .medium)).frame(width: 20)
                            Text(L10n.text(item.rawValue)).font(.system(size: 13, weight: section == item ? .semibold : .medium))
                                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(section == item ? FrogStyle.accent : FrogStyle.muted)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(section == item ? FrogStyle.accentSoft : .clear, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
                        .contentShape(RoundedRectangle(cornerRadius: FrogStyle.corner))
                    }.buttonStyle(.plain).keyboardShortcut(item.key, modifiers: .command)
                        .accessibilityAddTraits(section == item ? .isSelected : [])
                        .help("\(item.rawValue) (Command–\(String(item.key.character)))")
                }
            }.padding(.horizontal, 13)
            Spacer(minLength: 24)
            if !model.accessibilityGranted || !DictationController.microphoneGranted {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(FrogStyle.accent)
                    Text(L10n.text(!model.accessibilityGranted ? "Allow Accessibility" : "Allow Microphone"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(L10n.text(!model.accessibilityGranted ? "For writing and window shortcuts." : "For voice transcription."))
                        .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
                    Button("Finish setup") {
                        section = .settings
                    }.buttonStyle(FrogButtonStyle()).controlSize(.small)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(FrogStyle.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: FrogStyle.corner))
                    .padding(.horizontal, 13).padding(.bottom, 18)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    if model.isProcessing { ProgressView().controlSize(.mini) }
                    else { Circle().fill(model.errorMessage == nil ? FrogStyle.accent : .orange).frame(width: 6, height: 6) }
                     Text(L10n.text(model.dictation.active ? model.dictation.phase.rawValue.capitalized : model.status)).font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                        .lineLimit(4).textSelection(.enabled).help(model.status)
                    Spacer(minLength: 0)
                    HStack(spacing: 3) {
                        Image(systemName: "cpu").font(.system(size: 9))
                        Text("\(model.localModels.loaded.count)").font(.system(size: 9)).monospacedDigit()
                    }.foregroundStyle(FrogStyle.muted)
                        .help(model.localModels.loaded.isEmpty ? L10n.text("No models in RAM") : model.localModels.loaded.sorted().map { model.configuration.localModel($0)?.name ?? $0 }.joined(separator: ", "))
                        .accessibilityLabel(L10n.text("Models in RAM") + ": \(model.localModels.loaded.count)")
                }
                if model.isProcessing { Button("Cancel request") { model.cancelProcessing() } }
            }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 38)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .bottom) { MemorySparkline().frame(height: 34).allowsHitTesting(false) }
        }
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
