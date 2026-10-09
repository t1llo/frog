import SwiftUI
import AppKit
import FrogCore

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var section: Section = .rules
    @State private var permissionsRequest: UUID?
    @State private var showingLoadedModels = false

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
            sidebar.padding(.top, 32).frame(width: 176).background(FrogStyle.sidebar)
                .overlay(alignment: .trailing) { Rectangle().fill(FrogStyle.border.opacity(0.6)).frame(width: 1) }
            VStack(spacing: 0) {
                Group {
                    switch section {
                    case .rules: RulesView()
                    case .providers: ProvidersView()
                    case .history: HistoryView()
                    case .settings: PreferencesView(permissionsRequest: permissionsRequest)
                    case .shortcuts: RulesView(applications: true)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let error = model.errorMessage {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                        Text(error).font(.system(size: 12)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        IconAction(title: "Copy error", symbol: "doc.on.doc") { ViewActions.copy(error) }
                        Button { model.dismissError() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss error")
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
        .sheet(isPresented: Binding(get: { model.setupPresented }, set: { if !$0 { model.finishSetup() } })) {
            SetupView().environmentObject(model).interactiveDismissDisabled()
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshSystemStatus() } }
        .onChange(of: model.configuration.preferences.shortcutsEnabled) { _, enabled in if !enabled && section == .shortcuts { section = .settings } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: FrogMenuIcon.image).renderingMode(.template).frame(width: 20)
                Text("Frog").font(.system(size: 14, weight: .semibold)).tracking(-0.2)
            }.padding(.horizontal, 16).padding(.top, 19).padding(.bottom, 23)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay { WindowDragRegion().accessibilityHidden(true) }

            VStack(spacing: 2) {
                ForEach(Section.allCases.filter { $0 != .shortcuts || model.configuration.preferences.shortcutsEnabled }) { item in
                    Button { section = item } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.symbol).font(.system(size: 13, weight: .regular)).frame(width: 18)
                            Text(L10n.text(item.rawValue)).font(.system(size: 12, weight: section == item ? .medium : .regular))
                                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(section == item ? FrogStyle.ink : FrogStyle.muted)
                        .padding(.horizontal, 9).padding(.vertical, 8)
                        .background(section == item ? FrogStyle.selection : .clear, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
                        .contentShape(RoundedRectangle(cornerRadius: FrogStyle.corner))
                    }.buttonStyle(.plain).keyboardShortcut(item.key, modifiers: .command)
                        .accessibilityAddTraits(section == item ? .isSelected : [])
                        .help("\(item.rawValue) (Command–\(String(item.key.character)))")
                }
            }.padding(.horizontal, 8)
            Spacer(minLength: 24)
            if !model.accessibilityGranted || !DictationController.microphoneGranted {
                Button {
                    section = .settings; permissionsRequest = UUID()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(FrogStyle.muted)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Finish setup").font(.system(size: 11, weight: .medium))
                            Text(L10n.text(!model.accessibilityGranted ? "Allow Accessibility" : "Allow Microphone"))
                                .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                        }
                        Spacer(minLength: 0)
                    }.padding(10).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.horizontal, 6).padding(.bottom, 10)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    if model.isProcessing { ProgressView().controlSize(.mini) }
                    else { Circle().fill(model.errorMessage == nil ? FrogStyle.accent : .orange).frame(width: 6, height: 6) }
                     Text(L10n.text(model.dictation.active ? model.dictation.phase.rawValue.capitalized : model.status)).font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                        .lineLimit(2).textSelection(.enabled).help(model.status)
                    Spacer(minLength: 0)
                }
                Button { showingLoadedModels.toggle() } label: {
                    Label(model.localModels.loaded.count == 1 ? "1 model in memory" : "\(model.localModels.loaded.count) models in memory", systemImage: "cpu")
                        .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                }.buttonStyle(.plain)
                    .popover(isPresented: $showingLoadedModels) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Models in memory").font(.system(size: 13, weight: .semibold))
                            ForEach(model.localModels.catalog.filter { model.localModels.loaded.contains($0.id) }) { item in
                                VStack(alignment: .leading, spacing: 3) {
                                    Label(item.name, systemImage: item.kind == .audio ? "waveform" : "text.bubble")
                                        .font(.system(size: 12, weight: .medium))
                                    Text("\(item.kind == .audio ? "Audio" : "Text") · \(item.size) download")
                                        .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                                }
                            }
                            if model.localModels.loaded.isEmpty { Text("No models loaded").font(.caption).foregroundStyle(FrogStyle.muted) }
                            Text("Models stay cached after use until the idle timeout. Audio rules load a text model only when cleanup is enabled.")
                                .font(.caption).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
                        }.padding(16).frame(width: 340).foregroundStyle(FrogStyle.ink).background(FrogStyle.panelSurface)
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
