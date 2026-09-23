import SwiftUI
import AppKit

/// Shared adaptive colors keep the app, sheets, and controls in the same visual language.
enum FrogStyle {
    static let canvas = adaptive(light: 0xF8F9F6, dark: 0x191C1A)
    static let sidebar = adaptive(light: 0xEFF1EC, dark: 0x141715)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x232724)
    static let inset = adaptive(light: 0xF4F6F1, dark: 0x1B1F1C)
    static let border = adaptive(light: 0xDDE3D9, dark: 0x39413B)
    static let accent = adaptive(light: 0x326B49, dark: 0xA3D8AF)
    static let accentSoft = adaptive(light: 0xE3EDDE, dark: 0x2D4131)
    static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x18261C)
    static let ink = adaptive(light: 0x242D26, dark: 0xEDF2EA)
    static let muted = adaptive(light: 0x647060, dark: 0xADB8AB)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

struct FrogButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .foregroundStyle(primary ? FrogStyle.onAccent : FrogStyle.ink)
            .background(primary ? FrogStyle.accent : FrogStyle.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(primary ? .clear : FrogStyle.border, lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct FrogCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(FrogStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(contrast == .increased ? FrogStyle.muted : FrogStyle.border, lineWidth: 1))
    }
}

struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 29, weight: .bold, design: .rounded)).tracking(-0.6)
                    .foregroundStyle(FrogStyle.ink).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(FrogStyle.muted)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            actions.padding(.top, 3)
        }
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, subtitle: String) {
        self.title = title; self.subtitle = subtitle; self.actions = EmptyView()
    }
}

struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content }
                .padding(32).frame(maxWidth: 1080)
                .frame(maxWidth: .infinity, alignment: .top)
        }.background(FrogStyle.canvas)
    }
}

struct SectionCaption: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1.4)
            .foregroundStyle(FrogStyle.muted).accessibilityAddTraits(.isHeader)
    }
}

struct SymbolTile: View {
    let symbol: String
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.4, weight: .medium))
            .foregroundStyle(FrogStyle.accent).frame(width: size, height: size)
            .background(FrogStyle.accentSoft, in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

struct FrogBadge: View {
    let text: String
    var active = false
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(active ? FrogStyle.accent : FrogStyle.muted)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(active ? FrogStyle.accentSoft : FrogStyle.inset, in: Capsule())
    }
}

struct ShortcutBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(FrogStyle.muted).padding(.horizontal, 9).padding(.vertical, 5)
            .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(FrogStyle.border, lineWidth: 1))
            .accessibilityLabel("Shortcut: \(text)")
    }
}

struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(FrogStyle.ink)
            content.textFieldStyle(.plain).padding(11)
                .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(FrogStyle.border, lineWidth: 1))
        }
    }
}

/// Full-width menu controls with the same inset surface as editable fields.
struct FrogMenu<Content: View>: View {
    let title: String
    let value: String
    var symbol = "chevron.up.chevron.down"
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium))
            Menu { content } label: {
                HStack(spacing: 12) {
                    Text(value).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(FrogStyle.muted)
                }.font(.system(size: 13)).foregroundStyle(FrogStyle.ink).padding(12)
                    .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(FrogStyle.border, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .accessibilityLabel(title).accessibilityValue(value)
        }
    }
}

struct IconAction: View {
    let title: String
    let symbol: String
    var destructive = false
    let action: () -> Void
    var body: some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(destructive ? Color.red : FrogStyle.muted)
                .frame(width: 32, height: 32)
                .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityLabel(title).help(title)
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    let description: String
    @ViewBuilder var control: Control
    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(FrogStyle.ink)
                Text(description).font(.system(size: 12)).foregroundStyle(FrogStyle.muted)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            control
        }
    }
}

struct FrogEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 16) {
            SymbolTile(symbol: symbol, size: 60)
            Text(title).font(.system(size: 21, weight: .semibold, design: .rounded)).foregroundStyle(FrogStyle.ink)
            Text(message).font(.system(size: 13)).foregroundStyle(FrogStyle.muted)
                .multilineTextAlignment(.center).lineSpacing(4).frame(maxWidth: 340)
        }.frame(maxWidth: .infinity).padding(.vertical, 44).padding(.horizontal, 24)
    }
}

struct FrogMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(FrogStyle.accentSoft).frame(width: 46, height: 46)
            Capsule().fill(FrogStyle.accent).frame(width: 29, height: 21).offset(y: 4)
            ForEach([-1.0, 1.0], id: \.self) { side in
                Circle().fill(FrogStyle.accent).frame(width: 13, height: 13).offset(x: side * 9, y: -5)
                Circle().fill(FrogStyle.onAccent).frame(width: 5, height: 5).offset(x: side * 9, y: -6)
                Circle().fill(FrogStyle.accent).frame(width: 2, height: 2).offset(x: side * 9, y: -6)
            }
            Path { path in
                path.move(to: CGPoint(x: 18, y: 28))
                path.addQuadCurve(to: CGPoint(x: 28, y: 28), control: CGPoint(x: 23, y: 33))
            }.stroke(FrogStyle.onAccent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }.frame(width: 46, height: 46).accessibilityHidden(true)
    }
}
