import SwiftUI

// Small components shared across surfaces: the status item popups' header and footer, a page's state pill,
// commands in text, and badges.

/// The top of every status item popup: the feature's tile and name, then its actions on the trailing side.
/// Its content starts where the cards' text does.
struct FrogPopupHeader<Trailing: View>: View {
    let symbol: String
    let tint: PluginTint
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: FrogStyle.space8) {
            PluginIconTile(symbol: symbol, tint: tint.color, size: .sidebar)
            Text(L10n.text(title)).font(FrogType.section).lineLimit(1).fixedSize()
            Spacer(minLength: FrogStyle.space6)
            trailing
        }.padding(.horizontal, FrogStyle.cardPadding).frame(height: 40)
    }
}

/// The bottom of every status item popup, under a hairline: a muted status on the left, Close and Escape on the right.
struct FrogPopupFooter<Status: View>: View {
    @ViewBuilder var status: Status

    var body: some View {
        HStack(spacing: FrogStyle.space6) {
            status.font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
            Spacer(minLength: FrogStyle.space8)
            Text(L10n.text("Close")).font(FrogType.label).foregroundStyle(FrogStyle.ink)
            KeyCap("esc")
        }
        .padding(.horizontal, FrogStyle.cardPadding).frame(height: 32).frame(maxWidth: .infinity)
        // As `PanelFooter`: the panel's own colour under a thin line.
        .overlay(alignment: .top) { Rectangle().fill(FrogStyle.hairline).frame(height: 1) }
    }
}

/// A page's state in its header: a dot and a word or two in a capsule, green while on.
struct FrogStatePill: View {
    let text: String
    let on: Bool

    var body: some View {
        HStack(spacing: FrogStyle.space6) {
            Circle().fill(on ? FrogStyle.good : FrogStyle.muted.opacity(0.6)).frame(width: 7, height: 7)
            Text(L10n.text(text)).font(FrogType.bodyMedium).foregroundStyle(on ? FrogStyle.ink : FrogStyle.muted)
        }
        .padding(.horizontal, FrogStyle.space10).frame(height: FrogStyle.compactHeight)
        .background(on ? FrogStyle.good.opacity(0.14) : FrogStyle.control, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Text with `backticked` commands, the commands set in the mono font on a faint fill and the backticks dropped.
enum InlineCode {
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (index, part) in text.components(separatedBy: "`").enumerated() {
            var piece = AttributedString(part)
            if index % 2 == 1 {
                piece.font = FrogType.mono
                piece.backgroundColor = FrogStyle.hover
            }
            result += piece
        }
        return result
    }
}

/// A command to type, as a chip in the mono font; a click copies it.
struct FrogCodeChip: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            ViewActions.copy(text); copied = true
            Task { try? await Task.sleep(for: FrogMotion.confirmation); copied = false }
        } label: {
            HStack(spacing: FrogStyle.space6) {
                Text(text).font(FrogType.mono).foregroundStyle(FrogStyle.ink)
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
            }
            .padding(.horizontal, FrogStyle.space8).frame(height: FrogStyle.compactHeight)
            .background(FrogStyle.control, in: RoundedRectangle(cornerRadius: FrogStyle.smallRadius, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help("Copy \(text)").accessibilityLabel("Copy \(text)")
    }
}
