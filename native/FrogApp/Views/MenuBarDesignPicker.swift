import AppKit
import SwiftUI
import FrogCore

/// One card per design, each drawn as the menu bar will show it with its name under it; the chosen one has the
/// accent ring and its name in ink. The cards share a row's width evenly, up to four across, and more than four
/// split into rows of equal count, so a group never leaves one card alone on a row or a gap at a row's end.
struct MenuBarDesignTiles<Choice: Hashable>: View {
    let choices: [Choice]
    let selected: Choice
    let title: (Choice) -> String
    /// The design's image for a dark (true) or light menu bar.
    let image: (Choice, Bool) -> NSImage
    let choose: (Choice) -> Void
    @Environment(\.colorScheme) private var scheme

    /// How many cards stand on a row: all of them up to four, else as few rows of equal count as fit four across.
    static func perRow(_ count: Int) -> Int {
        guard count > 4 else { return max(1, count) }
        let rows = (count + 3) / 4
        return (count + rows - 1) / rows
    }

    var body: some View {
        let perRow = Self.perRow(choices.count)
        let rows = stride(from: 0, to: choices.count, by: perRow).map { Array(choices[$0..<min($0 + perRow, choices.count)]) }
        Grid(alignment: .top, horizontalSpacing: FrogStyle.space10, verticalSpacing: FrogStyle.space10) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    ForEach(rows[index], id: \.self) { choice in
                        MenuBarDesignTile(title: L10n.text(title(choice)), image: image(choice, scheme == .dark),
                                          chosen: choice == selected) { choose(choice) }
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

private struct MenuBarDesignTile: View {
    let title: String
    let image: NSImage
    let chosen: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            VStack(spacing: FrogStyle.space6) {
                MenuBarPreviewStrip(image: image, radius: FrogStyle.controlRadius)
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: FrogStyle.controlRadius + 3, style: .continuous)
                        .strokeBorder(chosen ? FrogStyle.accent : hovering ? FrogStyle.hairline : .clear, lineWidth: 2.5))
                Text(title).font(chosen ? FrogType.rowMedium : FrogType.body)
                    .foregroundStyle(chosen ? FrogStyle.ink : FrogStyle.muted).lineLimit(1)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityLabel(title).accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// Every look of a meter in the menu bar as a gallery: the styles, then the colours drawn in the chosen style.
/// LLM usage and System monitor show the same one. Images are rendered once per look and menu bar colour.
struct MenuBarStyleGallery: View {
    /// Names what the previews show, such as the readings, so a different sample draws anew.
    let sample: String
    let style: MenuBarMeterStyle
    let palette: MenuBarMeterPalette
    let render: (MenuBarMeterStyle, MenuBarMeterPalette, Bool) -> NSImage
    let chooseStyle: (MenuBarMeterStyle) -> Void
    let choosePalette: (MenuBarMeterPalette) -> Void

    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: FrogStyle.space12) {
            group("Style") {
                MenuBarDesignTiles(choices: MenuBarMeterStyle.allCases, selected: style, title: \.title,
                                   image: { cached($0, palette, $1) }, choose: chooseStyle)
            }
            group("Colors") {
                MenuBarDesignTiles(choices: MenuBarMeterPalette.allCases, selected: palette, title: \.title,
                                   image: { cached(style, $0, $1) }, choose: choosePalette)
            }
        }.padding(.vertical, FrogStyle.space8)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: FrogStyle.space8) {
            Text(L10n.text(title)).font(FrogType.body).foregroundStyle(FrogStyle.muted)
            content()
        }.accessibilityElement(children: .contain).accessibilityLabel(L10n.text(title))
    }

    @MainActor private func cached(_ style: MenuBarMeterStyle, _ palette: MenuBarMeterPalette, _ dark: Bool) -> NSImage {
        let key = "\(sample)|\(style.rawValue)|\(palette.rawValue)|\(dark)"
        if let image = Self.cache[key] { return image }
        let image = render(style, palette, dark)
        Self.cache[key] = image
        return image
    }
}

/// A strip of menu bar with one item on it, at the menu bar's own size and in its light or dark look: the bar's
/// 24-point band, the item at its real size on it, over a hint of the desktop below, so
/// a preview reads as the menu bar it will be seen in rather than as a button.
struct MenuBarPreviewStrip: View {
    let image: NSImage
    var radius: CGFloat = FrogStyle.smallRadius
    /// The menu bar's height on a Mac without a notch.
    static let barHeight: CGFloat = 24
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(spacing: 0) {
            Image(nsImage: image).renderingMode(image.isTemplate ? .template : .original)
                .foregroundStyle(dark ? Color.white : Color.black)
                .frame(maxWidth: .infinity).frame(height: Self.barHeight)
                .background(dark ? Color(white: 0.14) : Color(white: 0.95))
            // The desktop under the bar, a quiet band of the accent.
            LinearGradient(colors: [FrogStyle.accent.opacity(dark ? 0.32 : 0.22), FrogStyle.accent.opacity(dark ? 0.16 : 0.1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: FrogStyle.space10)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(FrogStyle.hairline, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
