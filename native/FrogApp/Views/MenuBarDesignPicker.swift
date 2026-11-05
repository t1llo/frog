import AppKit
import SwiftUI
import FrogCore

/// One card per design in an adaptive grid (three or four across), each drawn as the menu bar will show it with its
/// name under it; the chosen one has the accent ring, as the theme cards do.
struct MenuBarDesignTiles<Choice: Hashable>: View {
    let choices: [Choice]
    let selected: Choice
    let title: (Choice) -> String
    /// The design's image for a dark (true) or light menu bar.
    let image: (Choice, Bool) -> NSImage
    let choose: (Choice) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 220), spacing: FrogStyle.space10, alignment: .top)],
                  alignment: .leading, spacing: FrogStyle.space10) {
            ForEach(choices, id: \.self) { choice in
                MenuBarDesignTile(title: L10n.text(title(choice)), image: image(choice, scheme == .dark), chosen: choice == selected) { choose(choice) }
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

/// A strip of menu bar with one item on it, in the menu bar's light or dark look.
struct MenuBarPreviewStrip: View {
    let image: NSImage
    var radius: CGFloat = FrogStyle.smallRadius
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Image(nsImage: image).renderingMode(image.isTemplate ? .template : .original)
            .foregroundStyle(scheme == .dark ? Color.white : Color.black)
            .frame(maxWidth: .infinity).frame(height: FrogStyle.controlHeight)
            .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.93), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityHidden(true)
    }
}
