import SwiftUI
import AppKit
import FrogCore
import UniformTypeIdentifiers

struct PreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var notificationRequested = false
    @State private var pendingConfiguration: Configuration?
    @State private var showingImportConfirmation = false

    var body: some View {
        PageScroll {
            PageHeader(title: "Settle in.", subtitle: "A few small things to make Frog feel at home.")
            SectionCaption(text: "Everyday essentials")
            FrogCard {
                VStack(spacing: 20) {
                    SettingRow(title: "Ready when you are", description: "Start Frog at login. It stays in your menu bar when the window closes.") {
                        Toggle("Start Frog at login", isOn: Binding(get: { model.startAtLogin }, set: { model.setStartAtLogin($0) }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    HStack {
                        Label(model.loginStatus, systemImage: "power").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                        Spacer()
                    }
                    ruleDivider
                    SettingRow(title: "Show processing indicator", description: "A small floating status appears during hotkey actions, without taking focus from your writing.") {
                        Toggle("Show processing indicator", isOn: preference(\.showProcessingIndicator))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                }
            }
            SectionCaption(text: "Your setup, to go")
            FrogCard {
                VStack(alignment: .leading, spacing: 16) {
                    SettingRow(title: "Configuration files", description: "Back up your setup or move it to another Mac. Plain JSON, ready to edit or share.") {
                        Image(systemName: "doc.badge.gearshape").font(.system(size: 22)).foregroundStyle(FrogStyle.accent)
                    }
                    HStack(spacing: 10) {
                        Button("Export…", systemImage: "square.and.arrow.up") { exportConfiguration() }
                        Button("Import…", systemImage: "square.and.arrow.down") { chooseConfiguration() }
                            .disabled(model.isProcessing || model.isTestingProvider)
                    }
                    Text("Includes rules, shortcuts, provider settings, and preferences. API keys and text history are never included. Login and macOS permissions are set up separately on each Mac.")
                        .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
                }
            }
            SectionCaption(text: "A little memory")
            FrogCard {
                VStack(alignment: .leading, spacing: 20) {
                    SettingRow(title: "Keep a local history", description: "Save original text and results on this Mac. Off by default, always in your control.") {
                        Toggle("Record successful transformations", isOn: preference(\.historyEnabled))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    ruleDivider
                    HStack(spacing: 24) {
                        historyLimit
                        Rectangle().fill(FrogStyle.border).frame(width: 1, height: 42)
                        historyRetention
                    }
                    Text("Turning recording off also excludes requests in progress. Existing entries stay until deleted or expired. Lower limits also apply to saved history.")
                        .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
                }
            }
            SectionCaption(text: "Works with your Mac")
            FrogCard {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 14) {
                        SymbolTile(symbol: "hand.raised")
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Accessibility").font(.system(size: 14, weight: .semibold))
                                Spacer()
                                FrogBadge(text: model.accessibilityGranted ? "Allowed" : "Needs access", active: model.accessibilityGranted)
                            }
                            Text("Let Frog read and replace the selection in supported editable fields. Try text works without this permission.")
                                .font(.system(size: 12)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
                        }
                    }
                    HStack(spacing: 10) {
                        if !model.accessibilityGranted {
                            Button("Allow access") { SelectionService.requestAccess(); model.refreshSystemStatus() }
                                .buttonStyle(FrogButtonStyle(primary: true))
                        }
                        Button("Open System Settings", systemImage: "arrow.up.right") { SelectionService.openAccessibilitySettings() }
                        Spacer()
                        Button { model.refreshSystemStatus() } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Refresh permission status").help("Refresh permission status")
                    }
                    if !model.accessibilityGranted {
                        Text("Already enabled but still denied? Quit Frog, remove its old entry with the minus button in Accessibility, then add /Applications/Frog.app and enable it again. Toggling an old entry may retain its old signature. Always quit Frog before moving or replacing the app, then reopen the installed copy.")
                            .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
                    }
                    ruleDivider
                    HStack(alignment: .top, spacing: 14) {
                        SymbolTile(symbol: "bell")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("A quiet heads-up").font(.system(size: 14, weight: .semibold))
                            Text("Get notifications for background results and errors. Status is always available in Frog’s menu and window.")
                                .font(.system(size: 12)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("Allow notifications…") {
                        DesktopNotifications.requestAuthorization()
                        notificationRequested = true
                    }
                    if notificationRequested {
                        Text("No prompt? Manage Frog in System Settings → Notifications.")
                            .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                    }
                }
            }
            FrogCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Small app. Thoughtful defaults.", systemImage: "leaf").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FrogStyle.accent)
                    Text("Results are copied to the clipboard. If your original selection changes or can’t be safely edited, you can paste the result yourself.")
                    Text("Cloud providers receive your selected text and rule instructions. Choose a local endpoint to process on your own server.")
                    Text("No analytics, telemetry, or usage tracking. Frog makes no requests to a Frog server.")
                }.font(.system(size: 12)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
            }
        }.onAppear { model.refreshSystemStatus() }
        .confirmationDialog("Import this configuration?", isPresented: $showingImportConfirmation, titleVisibility: .visible) {
            Button("Replace configuration") {
                guard let pendingConfiguration else { return }
                do { try model.importConfiguration(pendingConfiguration) } catch { model.report(error) }
                self.pendingConfiguration = nil
            }
            Button("Cancel", role: .cancel) { pendingConfiguration = nil }
        } message: {
            if let pendingConfiguration {
                Text("Replace your current setup with \(pendingConfiguration.rules.count) rules and \(pendingConfiguration.providers.count) providers. The current file is backed up first. Matching connections keep their saved keys; others need keys entered again. History recording will be \(pendingConfiguration.preferences.historyEnabled ? "on" : "off"), and imported retention limits apply to existing history.")
            }
        }
    }

    private var ruleDivider: some View { Rectangle().fill(FrogStyle.border).frame(height: 1) }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Frog-configuration.json"
        panel.title = "Export Frog configuration"
        panel.message = "API keys and text history are not included."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.exportConfiguration(to: url) } catch { model.report(error) }
    }

    private func chooseConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import Frog configuration"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            pendingConfiguration = try ConfigurationFile.read(from: url)
            showingImportConfirmation = true
        } catch { model.report(error) }
    }

    private var historyLimit: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Maximum entries").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
            Stepper(value: preference(\.historyLimit), in: 1...200) {
                Text("\(model.configuration.preferences.historyLimit)").font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            }.accessibilityLabel("Maximum history entries")
        }.frame(maxWidth: .infinity)
    }

    private var historyRetention: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keep for").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
            Stepper(value: preference(\.historyRetentionDays), in: 1...30) {
                Text("\(model.configuration.preferences.historyRetentionDays) days").font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            }.accessibilityLabel("History retention in days")
        }.frame(maxWidth: .infinity)
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(get: { model.configuration.preferences[keyPath: keyPath] }, set: { value in
            var preferences = model.configuration.preferences
            preferences[keyPath: keyPath] = value
            do { try model.savePreferences(preferences) } catch { model.report(error) }
        })
    }
}
