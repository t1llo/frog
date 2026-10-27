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
        }.font(FrogType.body).padding(.horizontal, 8).frogControlSurface()
    }
}

struct FilterTag: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(L10n.text(title)).font(selected ? FrogType.bodyMedium : FrogType.body)
                .padding(.horizontal, 10).frame(height: FrogStyle.controlHeight)
                .foregroundStyle(selected || hovering ? FrogStyle.ink : FrogStyle.muted)
                .frogRowHighlight(hovering: hovering, selected: selected)
        }.buttonStyle(.plain).onHover { hovering = $0 }.accessibilityAddTraits(selected ? .isSelected : [])
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
                Text(L10n.text(title)).font(FrogType.body)
                if let detail { Text(L10n.text(detail)).font(FrogType.small).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            content.controlSize(.small).fixedSize(horizontal: true, vertical: false).environment(\.compactRowTitle, title)
        }.frame(minHeight: FrogStyle.controlHeight)
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
                    VStack(alignment: .leading, spacing: 1) { content }
                        .buttonStyle(CompactOptionStyle { showing = false })
                        .padding(6)
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
    /// `FrogStyle.controlHeight`, or `FrogStyle.compactHeight` in popups and panel headers.
    var height: CGFloat = FrogStyle.controlHeight
    @State private var hovering = false
    private var compact: Bool { height < FrogStyle.controlHeight }
    var body: some View {
        HStack(spacing: compact ? 5 : 7) {
            if let symbol { Image(systemName: symbol).foregroundStyle(FrogStyle.muted) }
            Text(value).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 2)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(FrogStyle.muted)
        }.font(compact ? FrogType.small : FrogType.body).foregroundStyle(FrogStyle.ink)
            .padding(.horizontal, 8).frame(width: width, height: height)
            .frogControlSurface(hovering: hovering, height: height).onHover { hovering = $0 }
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
                    .font(FrogType.body).padding(.horizontal, 8).frame(minHeight: FrogStyle.controlHeight)
                    .frogRowHighlight(hovering: hovering)
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
                    Text(L10n.text(title(value)))
                        .font(compact ? (selected == value ? FrogType.label : FrogType.small) : (selected == value ? FrogType.bodyMedium : FrogType.body))
                        .lineLimit(1).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(selected == value ? FrogStyle.ink : FrogStyle.muted)
                        .background(selected == value ? FrogStyle.surface : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: FrogStyle.smallRadius))
                        .shadow(color: .black.opacity(selected == value ? 0.08 : 0), radius: 1, y: 0.5)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selected == value ? .isSelected : [])
            }
        }.padding(2).frame(width: width, height: compact ? FrogStyle.compactHeight : FrogStyle.controlHeight)
            .frogControlSurface(height: nil)
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
        }.frame(height: FrogStyle.controlHeight)
    }
}
