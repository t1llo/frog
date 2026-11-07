import SwiftUI
import FrogCore

/// A page the app-wide search can open.
enum AppSearchPage: Hashable, Sendable {
    /// A built-in plugin's page, by plugin ID.
    case plugin(String)
    case settings, statistics, models
}

/// One place in the app the sidebar's search finds: a section of a page, or a row inside one. Its titles are the
/// ones the page draws (`FrogSection`, `FrogRow`), so opening it can scroll to that spot (`FrogSearchFocus`).
struct AppSearchEntry: Hashable, Sendable {
    let page: AppSearchPage
    /// The section's heading, or nil for the page itself.
    let section: String?
    /// The row's title inside the section, or nil for the whole section.
    let row: String?
    /// Other words someone may search for, which the page does not show.
    var keywords: [String] = []

    /// What the result shows: the row, else the section.
    var title: String { row ?? section ?? "" }
}

/// Every section and setting of Frog's pages, for the sidebar's search. A page that adds or renames a section or
/// row adds it here too; `AppSearchCatalogTests` checks every title still appears in the app's source.
enum AppSearchCatalog {
    static let entries: [AppSearchEntry] = {
        var all: [AppSearchEntry] = []
        func add(_ page: AppSearchPage, _ section: String, keywords: [String] = [], rows: [(String, [String])] = []) {
            all.append(AppSearchEntry(page: page, section: section, row: nil, keywords: keywords))
            for (row, words) in rows { all.append(AppSearchEntry(page: page, section: section, row: row, keywords: words)) }
        }

        // Settings
        add(.settings, "General", rows: [("Start at login", ["launch", "startup", "login items", "autostart"]),
                                         ("Writing indicator", ["pill", "processing"]),
                                         ("Shortcut reference", ["cheat sheet", "hotkeys", "keys"]),
                                         ("Setup", ["onboarding", "welcome", "run setup again"]),
                                         ("Statistics", ["stats", "counts"])])
        add(.settings, "Appearance", keywords: ["dark mode", "light mode", "theme", "colour", "color", "accent", "classic"],
            rows: [("Custom palette", ["palette", "colors", "colours"])])
        add(.settings, "Glass", keywords: ["transparency", "blur", "translucent"],
            rows: [("Tint with theme", []), ("Accent color", ["accent colour", "tint"])])
        add(.settings, "Permissions", keywords: ["privacy", "allow"],
            rows: [("Accessibility", ["permission"]), ("Microphone", ["permission", "mic"])])
        add(.settings, "Agents", keywords: ["mcp", "ai agents", "claude code", "codex"],
            rows: [("Let AI agents use Frog", ["agent"]), ("Command line tool", ["cli", "terminal", "frog command"])])
        add(.settings, "History", rows: [("Save history on this Mac", ["privacy"]), ("Hide history text", ["mask", "privacy"]),
                                         ("Maximum entries", ["limit"]), ("Retention", ["days", "delete after", "keep"])])
        add(.settings, "Settings file", keywords: ["configuration", "config"],
            rows: [("config.toml", ["configuration file", "toml"]), ("Import or export", ["backup", "import", "export"])])
        add(.settings, "Updates", keywords: ["sparkle", "new version", "upgrade"],
            rows: [("Check automatically", ["updates"]), ("Download updates automatically", ["updates"]),
                   ("Software updates", ["check for updates"])])
        add(.settings, "About", keywords: ["version", "licence", "license", "privacy policy", "source code", "contact"],
            rows: [("Errors", ["log", "error log", "problems"])])

        // Statistics
        add(.statistics, "Rule runs")
        add(.statistics, "Tool use")
        add(.statistics, "Recording", rows: [("Record statistics", ["stats"]), ("Clear all counts", ["reset statistics"])])

        // Models
        add(.models, "Memory and storage", keywords: ["local models", "ram", "disk"],
            rows: [("Unload speech model", ["idle", "unload"]), ("Unload text models", ["idle", "unload"]),
                   ("Model folder", []), ("Disk used", [])])

        // Writing
        add(.plugin("writing"), "Rules", keywords: ["rewrite", "grammar", "translate", "prompts"])
        add(.plugin("writing"), "Selection bubble", keywords: ["popup", "bubble"],
            rows: [("Show after selecting text", ["selection"]), ("Longest selection", []),
                   ("Never show in", ["excluded apps", "blocklist", "ignore apps"])])

        // Explain
        add(.plugin("explain"), "Asking", rows: [("Shortcut", ["hotkey", "explain shortcut"]), ("Surrounding text", ["context"])])
        add(.plugin("explain"), "Answers", rows: [("Model", ["explain model"]), ("Save answers to notes", ["obsidian", "notes"]),
                                                  ("Open after saving", ["obsidian"])])

        // Dictation
        add(.plugin("dictation"), "Recording", keywords: ["voice", "speech", "transcription", "whisper"],
            rows: [("Microphone", ["input device", "mic"]), ("Mute Mac audio", ["mute", "sound"]),
                   ("Cancel shortcut", ["escape"])])

        // Command bar
        add(.plugin("command-bar"), "Shortcut", keywords: ["launcher", "spotlight"],
            rows: [("Open the bar", ["command bar shortcut", "hotkey"]), ("Free ⌘Space from Spotlight", ["cmd space", "spotlight"])])
        add(.plugin("command-bar"), "Results", rows: [("Learn from your choices", ["ranking", "recent"])])

        // Shortcuts
        add(.plugin("shortcuts"), "Apps", keywords: ["app shortcuts", "open app", "hotkeys"])
        add(.plugin("shortcuts"), "Actions", keywords: ["action shortcuts", "lock screen", "hotkeys"])

        // Clipboard
        add(.plugin("clipboard"), "Shortcut and size", keywords: ["clipboard history", "paste"],
            rows: [("Shortcut", ["clipboard shortcut", "hotkey"]), ("Keep", ["clipboard limit", "items"])])
        add(.plugin("clipboard"), "Copied", keywords: ["clipboard history"])

        // Windows
        add(.plugin("windows"), "Layouts", keywords: ["window layouts", "tile", "arrange"])
        add(.plugin("windows"), "Snap", rows: [("Drag to screen edges", ["snap", "edges"]), ("Restore size when dragged away", []),
                                               ("Zones while holding Shift", ["zones"])])
        add(.plugin("windows"), "Panels", rows: [("Layout picker", []), ("Cheat sheet", ["window shortcuts"])])
        add(.plugin("windows"), "Tiling", rows: [("Gap between windows", ["gaps", "spacing", "margin"]),
                                                 ("Cycle sizes when pressed again", ["halves", "thirds"]),
                                                 ("Thirds top to bottom on tall displays", ["vertical", "portrait"]),
                                                 ("Leave room for Stage Manager", ["stage manager"])])

        // Window switcher
        add(.plugin("window-switcher"), "Keys", keywords: ["alt tab", "command tab", "switch windows"],
            rows: [("Shortcut", ["window switcher shortcut"])])

        // System monitor
        add(.plugin("system-monitor"), "Menu bar", keywords: ["cpu", "gpu", "memory", "ram", "system monitor"],
            rows: [("Show in the menu bar", ["system monitor menu bar"]), ("Readings", ["cpu", "memory"])])

        // LLM usage
        add(.plugin("llm-usage"), "Limits", keywords: ["usage limits", "rate limit", "quota"])
        add(.plugin("llm-usage"), "Activity", keywords: ["tokens", "cost"])
        add(.plugin("llm-usage"), "Sources")
        add(.plugin("llm-usage"), "Claude", keywords: ["anthropic"],
            rows: [("Each account", ["accounts"]), ("Show limits", []), ("Menu bar shows", []), ("Claude Code folder", [])])
        add(.plugin("llm-usage"), "Menu bar", keywords: ["usage menu bar"], rows: [("Show in the menu bar", ["usage menu bar"])])

        // Stay awake
        add(.plugin("stay-awake"), "Session", keywords: ["caffeinate", "keep awake", "sleep", "amphetamine"],
            rows: [("Duration", ["timer"]), ("Keep the screen on", ["display sleep"]),
                   ("Stay awake with the lid closed", ["clamshell", "lid"])])
        add(.plugin("stay-awake"), "Menu bar", keywords: ["stay awake menu bar"], rows: [("Show in the menu bar", ["stay awake menu bar"])])

        // Hidden bar
        add(.plugin("hidden-bar"), "Hiding", keywords: ["menu bar icons", "bartender", "hide icons"],
            rows: [("Show or hide icons", []), ("Hide again automatically", []), ("Hide again after", ["delay"]),
                   ("Hide when Frog starts", []), ("Show on hover", ["hover"]), ("Always-hidden section", ["divider"])])

        // Phone
        add(.plugin("phone"), "Pair a phone", keywords: ["iphone", "android", "pairing", "qr code"])
        add(.plugin("phone"), "Send", rows: [("Send copies automatically", ["sync clipboard"]), ("Clipboard", ["phone clipboard"]),
                                             ("Files", ["send files"])])
        add(.plugin("phone"), "Recent")

        // Community plugins
        add(.plugin("community"), "Make one with your agent", keywords: ["create plugin", "build plugin"],
            rows: [("Ask your agent", ["prompt"])])
        add(.plugin("community"), "Share and install", rows: [("Share yours", ["share plugin"]),
                                                              ("Install from a link", ["frogplugin", "install plugin"])])
        return all
    }()

    /// The entries that match `query`, best first: a title that starts with it, then one with a word that does,
    /// then one that contains it, then a match on the section or a keyword. At most `limit`.
    static func search(_ query: String, in entries: [AppSearchEntry] = entries, limit: Int = 12,
                       translate: (String) -> String = { L10n.text($0) }) -> [AppSearchEntry] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        func contains(_ text: String) -> Bool {
            translate(text).localizedCaseInsensitiveContains(query) || text.localizedCaseInsensitiveContains(query)
        }
        func score(_ entry: AppSearchEntry) -> Int? {
            let title = entry.title, shown = translate(title)
            for candidate in Set([title, shown]) {
                if candidate.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil { return 0 }
            }
            for candidate in Set([title, shown]) {
                let words = candidate.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                if words.contains(where: { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil }) { return 1 }
            }
            if contains(title) { return 2 }
            if entry.keywords.contains(where: contains) { return 3 }
            // A row is found by its section's name only when the section itself is listed too, so a section's name
            // does not bring up each of its rows.
            return nil
        }
        return entries.enumerated()
            .compactMap { index, entry in score(entry).map { (entry, $0, index) } }
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            .prefix(limit).map(\.0)
    }
}

/// Where the open page should scroll to and show briefly, set when a search result opens it.
struct FrogSearchFocus: Equatable {
    let route: ToolkitRoute
    let section: String?
    let row: String?
    /// A new value for each opening, so the same result opened twice scrolls again.
    let token = UUID()

    /// The one view on the page that matches carries this ID, for `ScrollViewProxy.scrollTo`.
    static let anchor = "frog-search-focus"
}

private struct FrogSearchFocusKey: EnvironmentKey { static let defaultValue: FrogSearchFocus? = nil }
private struct FrogSectionTitleKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    /// What a search result asked the open page to show; `FrogPage` scrolls to it and the matching
    /// `FrogSection` or `FrogRow` flashes.
    var frogSearchFocus: FrogSearchFocus? {
        get { self[FrogSearchFocusKey.self] }
        set { self[FrogSearchFocusKey.self] = newValue }
    }
    /// The heading of the section a row sits in, so a row's match can be told apart from a same-named row elsewhere.
    var frogSectionTitle: String? {
        get { self[FrogSectionTitleKey.self] }
        set { self[FrogSectionTitleKey.self] = newValue }
    }
}

extension FrogSearchFocus {
    func matchesSection(_ title: String?) -> Bool { row == nil && title != nil && section == title }
    func matchesRow(_ title: String, in section: String?) -> Bool {
        row == title && (self.section == nil || self.section == section)
    }
}

/// Marks the view a search result opened: it takes the anchor ID the page scrolls to and flashes once.
private struct FrogSearchTarget: ViewModifier {
    let token: UUID
    @State private var lit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: FrogStyle.controlRadius, style: .continuous)
                    .fill(FrogStyle.accent.opacity(lit ? 0.16 : 0)).padding(-FrogStyle.space4)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .id(FrogSearchFocus.anchor)
            .task(id: token) {
                withAnimation(FrogMotion.reveal) { lit = true }
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 1_400 : 1_100))
                guard !Task.isCancelled else { return }
                withAnimation(FrogMotion.exit) { lit = false }
            }
    }
}

extension View {
    /// Applies `FrogSearchTarget` while `focus` points here.
    @ViewBuilder func frogSearchTarget(_ focus: FrogSearchFocus?, active: Bool) -> some View {
        if let focus, active { modifier(FrogSearchTarget(token: focus.token)) } else { self }
    }
}
