import SwiftUI

struct SearchBox: View {
    let placeholder: String
    @Binding var text: String
    /// Lets a popup put the cursor in the field when it opens.
    var focus: FocusState<Bool>.Binding? = nil
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(FrogStyle.muted)
            field
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(FrogStyle.muted) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }.font(FrogType.body).padding(.horizontal, 8).frogControlSurface()
    }
    @ViewBuilder private var field: some View {
        let field = TextField(L10n.text(placeholder), text: $text).textFieldStyle(.plain)
        if let focus { field.focused(focus) } else { field }
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

private struct CompactChoiceKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    fileprivate var compactChoiceSelected: Bool {
        get { self[CompactChoiceKey.self] }
        set { self[CompactChoiceKey.self] = newValue }
    }
}

extension View {
    /// Marks the option of a `CompactMenu` that is the current choice: it shows a checkmark, and VoiceOver
    /// reads it as selected.
    func compactChoice(selected: Bool) -> some View {
        environment(\.compactChoiceSelected, selected).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Mark the option that is chosen with `.compactChoice(selected:)`.
struct CompactMenu<Content: View>: View {
    let value: String
    var width: CGFloat = 220
    /// `FrogStyle.compactHeight` in popups and panel headers.
    var height: CGFloat = FrogStyle.controlHeight
    @ViewBuilder var content: Content
    @State private var showing = false
    @Environment(\.compactRowTitle) private var rowTitle
    var body: some View {
        Button { showing.toggle() } label: {
            CompactDropdownLabel(value: L10n.text(value), width: width, height: height)
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
struct RowControlName: ViewModifier {
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
    /// Held down, or its list is open.
    var pressed = false
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
            .frogControlSurface(hovering: hovering, pressed: pressed, height: height).onHover { hovering = $0 }
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
        @Environment(\.compactChoiceSelected) private var chosen
        var body: some View {
            Button { configuration.trigger(); dismiss() } label: {
                HStack(spacing: 8) {
                    configuration.label
                    Spacer(minLength: 0)
                    if chosen {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(FrogStyle.accent)
                            .accessibilityHidden(true)
                    }
                }
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
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One thumb behind all the labels slides to the chosen segment, so it never covers a label on the way. With
    /// Reduce Motion each segment has its own thumb, and they fade from one to the other.
    var body: some View {
        HStack(spacing: 2) {
            ForEach(values, id: \.self) { value in
                Button { choose(value) } label: {
                    Text(L10n.text(title(value)))
                        .font(compact ? (selected == value ? FrogType.label : FrogType.small) : (selected == value ? FrogType.bodyMedium : FrogType.body))
                        .lineLimit(1).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(selected == value ? FrogStyle.ink : FrogStyle.muted)
                        .background { if reduceMotion && selected == value { thumbShape } }
                        .matchedGeometryEffect(id: value, in: thumb)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selected == value ? .isSelected : [])
            }
        }
        .background {
            if !reduceMotion && values.contains(selected) {
                thumbShape.matchedGeometryEffect(id: selected, in: thumb, isSource: false)
            }
        }
        .padding(2).frame(width: width, height: compact ? FrogStyle.compactHeight : FrogStyle.controlHeight)
            .frogControlSurface(height: nil)
            .animation(reduceMotion ? FrogMotion.reveal : FrogMotion.slide, value: selected)
    }

    private var thumbShape: some View {
        RoundedRectangle(cornerRadius: FrogStyle.smallRadius).fill(FrogStyle.surface)
            .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
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
