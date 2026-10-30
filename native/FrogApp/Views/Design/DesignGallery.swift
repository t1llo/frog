import SwiftUI

/// Every component of Frog's design system on one page, with sample values. `PageShotsTests` draws it in light
/// and dark (`design-gallery-light.png`, `design-gallery-dark.png`); look at it after changing a component.
struct DesignGallery: View {
    @State private var theme = "Frog"
    @State private var model: String? = "whisper-small"
    @State private var microphone: String? = nil
    @State private var period = "Week"
    @State private var gap = 8
    @State private var mode = "System"
    @State private var launch = true
    @State private var sounds = false
    @State private var picked: Set<String> = ["Downloads"]
    @State private var search = ""
    @State private var filter = "All"

    private static let themes = ["Frog", "Tokyo Night", "Catppuccin", "Nord", "Gruvbox", "Dracula", "Rosé Pine"]
    /// Sample tints in the spirit of System Settings' icons.
    private static let tints: [(String, Color)] = [
        ("doc.on.clipboard", tile(0x3B82F6)), ("mic.fill", tile(0xEF4444)), ("rectangle.split.2x1", tile(0x6366F1)),
        ("cup.and.saucer.fill", tile(0xF59E0B)), ("chart.bar.fill", tile(0x22A55B)), ("command", tile(0x6B7280)),
        ("sparkles", tile(0xA855F7)), ("menubar.rectangle", tile(0x14B8A6))
    ]
    private static func tile(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }

    var body: some View {
        FrogPage(width: FrogStyle.wideWidth) {
            FrogPageHeader(title: "Design gallery", subtitle: "Every Frog component, with sample values.") {
                Button("Secondary") {}
                Button("Primary") {}.buttonStyle(.frog(.primary))
            }
            HStack(alignment: .top, spacing: FrogStyle.sectionSpacing) {
                VStack(alignment: .leading, spacing: FrogStyle.sectionSpacing) {
                    choices
                    rows
                    buttons
                    FrogSection("Empty state") {
                        FrogEmptyState(symbol: "tray", title: "No notes yet", message: "Notes you save appear here.") {
                            Button("New note") {}.buttonStyle(.frog(.primary))
                        }
                    }
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: FrogStyle.sectionSpacing) {
                    lists
                    tiles
                    fields
                }.frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.frog())
        .tint(FrogStyle.accent)
        .foregroundStyle(FrogStyle.ink)
        .background(FrogStyle.opaqueCanvas)
    }

    private var choices: some View {
        FrogSection("Choices", footer: "One dropdown for every choice; segments for two to four.") {
            FrogRow("Theme") {
                FrogDropdown(selection: $theme, options: Self.themes, title: { $0 })
            }
            FrogRow("Speech model", caption: "Searchable, in sections.") {
                FrogDropdown(selection: $model, sections: Self.modelSections, searchPrompt: "Find a model",
                             placeholder: "Choose a model", item: Self.modelItem)
            }
            FrogRow("Microphone") {
                FrogDropdown(selection: $microphone, options: [nil, "MacBook Pro Microphone", "Studio Display"],
                             title: { $0 ?? "System default" }, symbol: { $0 == nil ? "mic" : "mic.fill" })
            }
            FrogRow("Gap between windows") {
                FrogDropdown(selection: $gap, options: [0, 4, 8, 12, 16], width: 120, title: { "\($0) pt" })
                    .disabled(true)
            }
            FrogRow("Appearance") {
                CompactSegments(values: ["System", "Light", "Dark"], selected: mode, title: { $0 }) { mode = $0 }
            }
            FrogRow("Open at login") { Toggle("Open at login", isOn: $launch).labelsHidden().toggleStyle(.switch) }
        }
    }

    private var rows: some View {
        FrogSection("Rows", accessory: { Button("Add") {}.buttonStyle(.frog(compact: true)) }) {
            FrogRow("Clipboard history", caption: "⌘⇧V opens it.", icon: { PluginIconTile(symbol: "doc.on.clipboard", tint: Self.tints[0].1) }) {
                Toggle("Clipboard history", isOn: .constant(true)).labelsHidden().toggleStyle(.switch)
            }
            FrogRow("Dictation", icon: { PluginIconTile(symbol: "mic.fill", tint: Self.tints[1].1) }) {
                ShortcutBadge(text: "⌥Space")
            }
            FrogRow("Sounds", caption: "Plays a tick when a recording starts.") {
                Toggle("Sounds", isOn: $sounds).labelsHidden().toggleStyle(.switch)
            }
            FrogRow("Period") {
                FrogDropdown(selection: $period, options: ["Day", "Week", "Month"], width: 90, compact: true, title: { $0 })
            }
            FrogRowNote(text: "A note inside a card that belongs to no row.")
        }
    }

    private var buttons: some View {
        FrogSection("Buttons") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button("Save") {}.buttonStyle(.frog(.primary))
                    Button("Cancel") {}
                    Button("Reset") {}.buttonStyle(.frog(.ghost))
                    Button("Delete") {}.buttonStyle(.frog(.destructive))
                    Button("Disabled") {}.disabled(true)
                }
                HStack(spacing: 8) {
                    Button("Compact") {}.buttonStyle(.frog(.primary, compact: true))
                    Button("Compact") {}.buttonStyle(.frog(compact: true))
                    Button("Ghost") {}.buttonStyle(.frog(.ghost, compact: true))
                    IconAction(title: "Copy", symbol: "doc.on.doc") {}
                    IconAction(title: "Remove", symbol: "trash", destructive: true) {}
                    IconAction(title: "Add", symbol: "plus", bordered: true) {}
                    IconMenu(title: "More") { Button("Rename") {} }
                }
            }.padding(.vertical, 10)
        }
    }

    private var lists: some View {
        FrogSection("Dropdown lists", footer: "Opened: arrows move the highlight, Return chooses, Escape closes.") {
            HStack(alignment: .top, spacing: 12) {
                FrogDropdownList(sections: [.init(values: Array(Self.themes.prefix(5)))], selected: theme,
                                 item: { FrogDropdownItem($0) }, width: 170) { theme = $0 }
                    .modifier(GalleryPopup())
                FrogDropdownList(sections: Self.modelSections, selected: model, item: Self.modelItem,
                                 searchPrompt: "Find a model", width: 250) { model = $0 }
                    .modifier(GalleryPopup())
            }.padding(.vertical, 12)
        }
    }

    private var tiles: some View {
        FrogSection("Plugin icons", footer: "20 in the sidebar, 28 in lists, 40 in headers.") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ForEach(Self.tints, id: \.0) { PluginIconTile(symbol: $0.0, tint: $0.1, size: .sidebar) }
                }
                HStack(spacing: 10) {
                    ForEach(Self.tints, id: \.0) { PluginIconTile(symbol: $0.0, tint: $0.1, size: .list) }
                }
                HStack(spacing: 10) {
                    ForEach(Self.tints.prefix(6), id: \.0) { PluginIconTile(symbol: $0.0, tint: $0.1, size: .header) }
                }
            }.padding(.vertical, 12)
        }
    }

    private var fields: some View {
        FrogSection("Fields and labels") {
            VStack(alignment: .leading, spacing: 12) {
                SearchBox(placeholder: "Search", text: $search)
                LabeledField(title: "Name") { TextField("Name", text: .constant("Work")) }
                HStack(spacing: 4) {
                    ForEach(["All", "Text", "Audio"], id: \.self) { tag in FilterTag(title: tag, selected: filter == tag) { filter = tag } }
                    Spacer()
                    FrogBadge(text: "New", active: true)
                    FrogBadge(text: "Beta")
                    KeyCap("⌘")
                    KeyCap("K")
                }
                HStack(spacing: 16) {
                    ForEach(["Downloads", "Desktop", "Caches"], id: \.self) { item in
                        Toggle(item, isOn: Binding(get: { picked.contains(item) }, set: { on in
                            if on { picked.insert(item) } else { picked.remove(item) }
                        })).toggleStyle(.frogCheckbox).font(FrogType.body)
                    }
                }
            }.padding(.vertical, 12)
        }
    }

    private static let modelSections: [FrogDropdownSection<String?>] = [
        .init(values: [nil]),
        .init("Downloaded", values: ["whisper-small", "whisper-large", "parakeet"]),
        .init("External", values: ["gpt-4o-transcribe", "scribe"])
    ]

    private static func modelItem(_ id: String?) -> FrogDropdownItem {
        switch id {
        case nil: FrogDropdownItem("None", symbol: "circle.slash")
        case "whisper-small": FrogDropdownItem("Whisper Small", detail: "466 MB · WhisperKit", symbol: "cpu", badge: "Recommended")
        case "whisper-large": FrogDropdownItem("Whisper Large v3", detail: "1.6 GB · WhisperKit", symbol: "cpu")
        case "parakeet": FrogDropdownItem("Parakeet v3", detail: "Needs macOS 15", symbol: "cpu", disabled: true)
        case "gpt-4o-transcribe": FrogDropdownItem("GPT-4o Transcribe", detail: "OpenAI", symbol: "cloud")
        default: FrogDropdownItem("Scribe", detail: "ElevenLabs", symbol: "cloud")
        }
    }
}

/// An open dropdown list drawn in place, framed like the popover it opens in.
private struct GalleryPopup: ViewModifier {
    func body(content: Content) -> some View {
        content.clipShape(RoundedRectangle(cornerRadius: FrogStyle.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: FrogStyle.panelRadius).strokeBorder(FrogStyle.border.opacity(0.8)))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}
