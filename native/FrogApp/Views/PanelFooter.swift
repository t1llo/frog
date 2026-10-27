import SwiftUI

/// The bar along the bottom of a Frog panel: which panel this is, what Return does, and where the actions are.
struct PanelFooter: View {
    let symbol: String
    let name: String
    /// The selected row's primary action; nil hides the Return hint.
    var primaryTitle: String?
    var showsActions = true
    /// What Escape does, for a panel without actions; nil hides the hint.
    var closeTitle: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(FrogType.label)
            Text(L10n.text(name)).font(FrogType.label).lineLimit(1)
            Spacer(minLength: 12)
            if let primaryTitle {
                Text(L10n.text(primaryTitle)).font(FrogType.label).foregroundStyle(FrogStyle.ink).lineLimit(1)
                KeyCap("↩")
            }
            if showsActions {
                Text(L10n.text("Actions")).font(FrogType.label).foregroundStyle(FrogStyle.ink)
                    .padding(.leading, primaryTitle != nil ? 8 : 0)
                HStack(spacing: 3) { KeyCap("⌘"); KeyCap("K") }
            }
            if let closeTitle {
                Text(L10n.text(closeTitle)).font(FrogType.label).foregroundStyle(FrogStyle.ink).lineLimit(1)
                    .padding(.leading, primaryTitle != nil || showsActions ? 8 : 0)
                KeyCap("esc")
            }
        }
        .foregroundStyle(FrogStyle.muted)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(FrogStyle.inset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let primaryTitle { parts.append("\(L10n.text(primaryTitle)), \(L10n.text("Return"))") }
        if showsActions { parts.append("\(L10n.text("Actions")), \(L10n.text("Command K"))") }
        if let closeTitle { parts.append("\(L10n.text(closeTitle)), \(L10n.text("Escape"))") }
        return parts.isEmpty ? L10n.text(name) : parts.joined(separator: ". ")
    }
}

/// One key of a shortcut, drawn as a small cap.
struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key).font(FrogType.label).foregroundStyle(FrogStyle.muted)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, 3)
            .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.smallRadius))
            .overlay(RoundedRectangle(cornerRadius: FrogStyle.smallRadius).strokeBorder(FrogStyle.border.opacity(0.6)))
    }
}
