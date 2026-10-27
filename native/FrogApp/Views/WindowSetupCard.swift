import SwiftUI
import FrogCore

/// The first-run choice at the top of the Windows page: one click sets Windows up for a way of
/// arranging windows. Shown until something is chosen; after a choice, a confirmation with Undo
/// stays until the page is left.
struct WindowSetupCard: View {
    @EnvironmentObject private var model: AppModel
    /// macOS's own window tiling, as the page last read it.
    let macOS: MacWindowManagerSettings
    @State private var addShortcuts = true
    /// What was chosen on this visit of the page, and how to take it back.
    @State private var confirmation: Confirmation?
    /// Shown after Undo, until the page is left.
    @State private var restored: String?

    private struct Confirmation {
        var message: String
        var shortcuts: String?
        /// The preferences before the choice.
        var previous: Preferences
        var addedShortcuts: Bool
    }

    var body: some View {
        if let confirmation {
            FrogCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text(confirmation.message).font(FrogType.bodyMedium)
                    if let shortcuts = confirmation.shortcuts {
                        Text(shortcuts).font(FrogType.small).foregroundStyle(FrogStyle.muted)
                    }
                    Button("Undo") { undo(confirmation) }.buttonStyle(.frog())
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } else if settings.setupChoice == nil {
            SettingsSection(title: "How do you want to arrange windows?") {
                if let restored {
                    Text(restored).font(FrogType.small).foregroundStyle(FrogStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(WindowSetupChoice.options, id: \.self) { choice in
                    WindowSetupOption(choice: choice) { choose(choice) }
                }
                CompactRow(title: "Add suggested shortcuts (⌃⌥ with arrows and letters)") {
                    Toggle("Add suggested shortcuts (⌃⌥ with arrows and letters)", isOn: $addShortcuts).labelsHidden().toggleStyle(.switch)
                }
                Button("Set up myself") { record(.manual) }.buttonStyle(.frog(.ghost))
            }
        } else if let restored {
            Text(restored).font(FrogType.small).foregroundStyle(FrogStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var settings: WindowPreferences { model.configuration.preferences.toolkitSettings.windows ?? WindowPreferences() }

    private func record(_ choice: WindowSetupChoice) {
        do { try model.savePreferences(WindowSetupChoice.apply(choice, to: model.configuration.preferences)) }
        catch { model.report(error) }
    }

    private func choose(_ choice: WindowSetupChoice) {
        let previous = model.configuration.preferences
        do { try model.savePreferences(WindowSetupChoice.apply(choice, to: previous)) }
        catch { model.report(error); return }
        var shortcuts: String?
        var added = false
        if addShortcuts {
            do {
                let result = try model.applySuggestedWindowShortcuts()
                shortcuts = result.summary(display: HotkeyManager.display)
                added = !result.added.isEmpty
            } catch { model.report(error) }
        }
        restored = nil
        confirmation = Confirmation(message: Self.confirmation(choice, macOS: macOS), shortcuts: shortcuts, previous: previous,
                                    addedShortcuts: added)
    }

    /// Puts the Windows settings back as they were before the choice; added shortcuts stay.
    private func undo(_ confirmation: Confirmation) {
        do { try model.savePreferences(WindowSetupChoice.undo(to: confirmation.previous, from: model.configuration.preferences)) }
        catch { model.report(error); return }
        self.confirmation = nil
        restored = confirmation.addedShortcuts
            ? "Settings restored. Added shortcuts are still listed under Layout shortcuts."
            : "Settings restored."
    }

    static func confirmation(_ choice: WindowSetupChoice, macOS: MacWindowManagerSettings) -> String {
        switch choice {
        case .snap:
            macOS.edgeTiling ? "Snap is on. Hold Shift while dragging a window to choose a zone."
                : "Snap is on. Drag a window to a screen edge to try it."
        case .manual: ""
        }
    }
}

/// One choice of the card: its name and what it does, as a large button.
private struct WindowSetupOption: View {
    let choice: WindowSetupChoice
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(choice.title).font(FrogType.bodyMedium).foregroundStyle(FrogStyle.ink)
                Text(choice.detail).font(FrogType.small).foregroundStyle(FrogStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frogRowHighlight(hovering: hovering)
            .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
            .accessibilityElement(children: .combine)
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}
