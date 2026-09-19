import SwiftUI
import AppKit
import FrogCore

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var section: Section? = .rules

    private enum Section: String, CaseIterable, Identifiable {
        case rules = "Rules", providers = "Providers", manual = "Try text", history = "History", settings = "Settings"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .rules: "text.badge.checkmark"
            case .providers: "server.rack"
            case .manual: "text.cursor"
            case .history: "clock"
            case .settings: "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationTitle("Frog")
            .navigationSplitViewColumnWidth(min: 150, ideal: 175, max: 220)
        } detail: {
            VStack(spacing: 0) {
                if model.configuration.providers.isEmpty {
                    HStack {
                        Label("Connect a provider to start writing with Frog.", systemImage: "sparkles")
                        Spacer()
                        Button("Add provider") { section = .providers }
                    }
                    .padding().background(.quaternary)
                } else if !model.accessibilityGranted {
                    HStack {
                        Label("Allow Accessibility to replace selected text in other apps.", systemImage: "hand.raised")
                        Spacer()
                        Button("Permissions") { section = .settings }
                    }
                    .padding().background(.quaternary)
                }
                Group {
                    switch section ?? .rules {
                    case .rules: RulesView()
                    case .providers: ProvidersView()
                    case .manual: ManualView()
                    case .history: HistoryView()
                    case .settings: PreferencesView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if let error = model.errorMessage {
                        HStack(alignment: .top) {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red).textSelection(.enabled)
                            Spacer()
                            Button("Dismiss") { model.dismissError() }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    HStack {
                        if model.isProcessing { ProgressView().controlSize(.small) }
                        Text(model.status).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer()
                        if model.isProcessing { Button("Cancel") { model.cancelProcessing() } }
                    }
                }.padding(12)
            }
        }
        .frame(minWidth: 850, minHeight: 600)
        .onAppear { model.refreshSystemStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshSystemStatus() }
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
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding()
    }
}

struct InlineIssue: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
    }
}
