import SwiftUI

struct SearchBox: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(FrogStyle.muted)
            TextField(L10n.text(placeholder), text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(FrogStyle.muted) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }.font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 7)
            .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
            .overlay(RoundedRectangle(cornerRadius: FrogStyle.corner).strokeBorder(FrogStyle.border.opacity(0.45)))
    }
}

struct FilterTag: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(L10n.text(title)).font(.system(size: 11, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .foregroundStyle(selected ? FrogStyle.ink : FrogStyle.muted)
                .background(selected ? FrogStyle.selection : .clear, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct CompactRowTitleKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    /// The title of the row a control sits in. A control that shows nothing but its value is named by it.
    var compactRowTitle: String? {
        get { self[CompactRowTitleKey.self] }
        set { self[CompactRowTitleKey.self] = newValue }
    }
}

struct CompactRow<Content: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(title)).font(.system(size: 12))
                if let detail { Text(L10n.text(detail)).font(.system(size: 10)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            content.controlSize(.small).fixedSize(horizontal: true, vertical: false).environment(\.compactRowTitle, title)
        }.padding(.vertical, 3)
    }
}

/// Mark the option that is chosen with `.accessibilityAddTraits(.isSelected)`.
struct CompactMenu<Content: View>: View {
    let value: String
    var width: CGFloat = 220
    @ViewBuilder var content: Content
    @State private var showing = false
    @Environment(\.compactRowTitle) private var rowTitle
    var body: some View {
        Button { showing.toggle() } label: {
            CompactDropdownLabel(value: L10n.text(value), width: width)
        }.buttonStyle(.plain).help(L10n.text(value))
            .modifier(RowControlName(title: rowTitle, value: L10n.text(value)))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) { content }
                        .buttonStyle(CompactOptionStyle { showing = false })
                        .padding(8)
                }.frame(width: 280).frame(maxHeight: 280).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(FrogStyle.ink).background(FrogStyle.panelSurface)
                    // The options are not controls of the row.
                    .environment(\.compactRowTitle, nil)
            }
    }
}

/// The dropdown draws only its choice. In a row VoiceOver reads the row's title as its name and the
/// choice as its value; outside a row it keeps the name it is given where it is used.
private struct RowControlName: ViewModifier {
    let title: String?
    let value: String
    func body(content: Content) -> some View {
        if let title { content.accessibilityLabel(L10n.text(title)).accessibilityValue(value) } else { content }
    }
}

struct CompactDropdownLabel: View {
    let value: String
    var symbol: String? = nil
    var width: CGFloat = 220
    var height: CGFloat = 32
    @State private var hovering = false
    var body: some View {
        HStack(spacing: height < 28 ? 5 : 8) {
            if let symbol { Image(systemName: symbol).foregroundStyle(FrogStyle.muted) }
            Text(value).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 2)
            Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(FrogStyle.muted)
        }.font(.system(size: 11, weight: .medium)).foregroundStyle(FrogStyle.ink)
            .padding(.horizontal, height < 28 ? 7 : 9).frame(width: width, height: height)
            .background(hovering ? AnyShapeStyle(FrogStyle.selection) : FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: FrogStyle.controlRadius).strokeBorder(FrogStyle.border.opacity(0.6)))
            .contentShape(RoundedRectangle(cornerRadius: FrogStyle.controlRadius)).onHover { hovering = $0 }
    }
}

private struct CompactOptionStyle: PrimitiveButtonStyle {
    let dismiss: () -> Void
    func makeBody(configuration: Configuration) -> some View {
        Option(configuration: configuration, dismiss: dismiss)
    }
    private struct Option: View {
        let configuration: PrimitiveButtonStyleConfiguration
        let dismiss: () -> Void
        @State private var hovering = false
        var body: some View {
            Button { configuration.trigger(); dismiss() } label: {
                HStack { configuration.label; Spacer(minLength: 0) }
                    .font(.system(size: 12)).padding(8).contentShape(Rectangle())
                    .background(hovering ? FrogStyle.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain).onHover { hovering = $0 }
        }
    }
}

struct CompactSegments<Value: Hashable>: View {
    let values: [Value]
    let selected: Value
    var width: CGFloat = 220
    /// Popup headers: the height and outline of a bordered `IconAction` beside it.
    var compact = false
    let title: (Value) -> String
    let choose: (Value) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(values, id: \.self) { value in
                Button { choose(value) } label: {
                    Text(L10n.text(title(value))).font(.system(size: 11, weight: selected == value ? .semibold : .regular))
                        .frame(maxWidth: .infinity).padding(.vertical, compact ? 3 : 6)
                        .foregroundStyle(selected == value ? FrogStyle.ink : FrogStyle.muted)
                        .background(selected == value ? FrogStyle.surface : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: FrogStyle.innerRadius))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selected == value ? .isSelected : [])
            }
        }.padding(compact ? 2 : 3).frame(width: width, height: compact ? 24 : nil)
            .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: compact ? 5 : 7))
            .overlay { if compact { RoundedRectangle(cornerRadius: 5).strokeBorder(FrogStyle.border.opacity(0.6)) } }
    }
}

struct ListToolbar<Filters: View>: View {
    let placeholder: String
    @Binding var search: String
    @ViewBuilder var filters: Filters
    var body: some View {
        HStack(spacing: 4) {
            filters
            Spacer(minLength: 12)
            SearchBox(placeholder: placeholder, text: $search).frame(width: 190)
        }.frame(height: 32)
    }
}
