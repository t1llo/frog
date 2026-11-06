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
        // A capsule, as Rex draws its search fields.
        }.font(FrogType.body).padding(.horizontal, 10).frogControlSurface(capsule: true)
    }
    @ViewBuilder private var field: some View {
        let field = FrogTextField(placeholder: placeholder, text: $text)
        if let focus { field.focused(focus) } else { field }
    }
}

/// A plain text field whose placeholder is drawn in `FrogStyle.placeholder`, a step lighter than muted text, so
/// an empty field never reads as filled in. Put it inside `LabeledField` or on `frogControlSurface()`.
struct FrogTextField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        // macOS draws a plain field's own placeholder nearly as dark as its text and ignores a styled prompt, so
        // the field draws none and this one sits behind it while the field is empty.
        TextField("", text: $text).textFieldStyle(.plain)
            .accessibilityLabel(L10n.text(placeholder))
            .background(alignment: .leading) {
                if text.isEmpty {
                    Text(L10n.text(placeholder)).foregroundStyle(FrogStyle.placeholder).lineLimit(1)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
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
                // A control-sized tag: the faint hover layer at rest, the control layer under the pointer, and
                // the neutral raised layer with a hairline when chosen, as Rex marks a selection.
                .background(selected ? FrogStyle.selection : hovering ? FrogStyle.control : FrogStyle.hover,
                            in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: FrogStyle.controlRadius, style: .continuous)
                    .strokeBorder(selected ? FrogStyle.hairline : .clear))
                .contentShape(RoundedRectangle(cornerRadius: FrogStyle.controlRadius, style: .continuous))
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

/// The v1 name of `FrogRow`, kept for views not moved yet: the same row, with small controls.
struct CompactRow<Content: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        FrogRow(title, caption: detail) { content.controlSize(.small) }
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

/// v1 dropdown, kept for code not moved yet: new code uses `FrogDropdown`. Mark the option that is chosen with
/// `.compactChoice(selected:)`.
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
                    .foregroundStyle(FrogStyle.ink).frogSurface(.popover)
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

/// Rex's dropdown: the value in plain text and a small round button with an up-and-down chevron. It hugs its
/// value up to `width` and sits on the trailing side; a hover lays the faint layer behind both.
struct CompactDropdownLabel: View {
    let value: String
    var symbol: String? = nil
    /// The most it grows to, its value ending on the trailing edge; `nil` takes only the width its value needs.
    var width: CGFloat? = 220
    /// `FrogStyle.controlHeight`, or `FrogStyle.compactHeight` in popups and panel headers.
    var height: CGFloat = FrogStyle.controlHeight
    /// Held down, or its list is open.
    var pressed = false
    /// The value keeps something from working (a rule without a model): a warning mark leads the value, inside the
    /// button, so the control and its problem read as one.
    var warning = false
    @State private var hovering = false
    @Environment(\.frogRowAccessory) private var inRow
    private var compact: Bool { height < FrogStyle.controlHeight }
    var body: some View {
        let knob: CGFloat = compact ? 16 : 20
        HStack(spacing: compact ? 5 : 7) {
            if warning {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(FrogStyle.warning).accessibilityHidden(true)
            } else if let symbol { Image(systemName: symbol).foregroundStyle(FrogStyle.muted) }
            Text(value).lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: compact ? 7 : 9, weight: .bold))
                .foregroundStyle(FrogStyle.ink.opacity(0.85))
                .frame(width: knob, height: knob)
                .background(Circle().fill(pressed || hovering ? FrogStyle.pressed : FrogStyle.control))
        }.font(compact ? FrogType.small : FrogType.body).foregroundStyle(FrogStyle.ink)
            .padding(.leading, compact ? 7 : 9).padding(.trailing, (height - knob) / 2)
            .frame(height: height)
            .background(Capsule(style: .continuous).fill(hovering || pressed ? FrogStyle.hover : .clear))
            .frame(maxWidth: width ?? .infinity, alignment: .trailing)
            .fixedSize(horizontal: width == nil, vertical: false)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // In a row the knob ends on the content edge, level with a switch or button; only the hover fill reaches
            // past it.
            .padding(.trailing, inRow ? -(height - knob) / 2 : 0)
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

/// Rex's segmented control: a capsule with the chosen segment filled with the accent (grey while the window is not
/// in front). Segments are as wide as their labels unless a `width` is given, which splits it evenly.
struct CompactSegments<Value: Hashable>: View {
    let values: [Value]
    let selected: Value
    var width: CGFloat? = nil
    /// Popup headers: the height of a bordered `IconAction` beside it.
    var compact = false
    let title: (Value) -> String
    let choose: (Value) -> Void
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    /// One thumb behind all the labels slides to the chosen segment, so it never covers a label on the way. With
    /// Reduce Motion each segment has its own thumb, and they fade from one to the other.
    var body: some View {
        HStack(spacing: 0) {
            ForEach(values, id: \.self) { value in
                Button { choose(value) } label: {
                    Text(L10n.text(title(value)))
                        .font(compact ? FrogType.small : FrogType.body)
                        .lineLimit(1).padding(.horizontal, compact ? 9 : 12)
                        .frame(maxWidth: width == nil ? nil : .infinity, maxHeight: .infinity)
                        .foregroundStyle(selected == value && active ? FrogStyle.onAccent : FrogStyle.ink)
                        .background { if reduceMotion && selected == value { thumbShape } }
                        .matchedGeometryEffect(id: value, in: thumb)
                        .contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(selected == value ? .isSelected : [])
            }
        }
        .background {
            if !reduceMotion && values.contains(selected) {
                thumbShape.matchedGeometryEffect(id: selected, in: thumb, isSource: false)
            }
        }
        .frame(width: width, height: compact ? FrogStyle.compactHeight : FrogStyle.controlHeight)
        .background(Capsule(style: .continuous).fill(FrogStyle.control))
        .animation(reduceMotion ? FrogMotion.reveal : FrogMotion.slide, value: selected)
    }

    private var active: Bool { activeState == .key || activeState == .active }

    private var thumbShape: some View {
        Capsule(style: .continuous).fill(active ? FrogStyle.accent : FrogStyle.pressed)
    }
}

/// The one place a search goes: the row directly above the list it filters, never the page header or the window
/// toolbar. Filters or tabs lead and the search trails at `searchWidth`; with no filters the search fills the row.
/// `showsSearch` hides the field (an empty list) while the filters keep their place.
struct ListToolbar<Filters: View>: View {
    static var searchWidth: CGFloat { 220 }
    let placeholder: String
    @Binding var search: String
    var showsSearch = true
    @ViewBuilder var filters: Filters
    var body: some View {
        HStack(spacing: 4) {
            if Filters.self == EmptyView.self {
                if showsSearch { SearchBox(placeholder: placeholder, text: $search) }
            } else {
                filters
                Spacer(minLength: 12)
                if showsSearch { SearchBox(placeholder: placeholder, text: $search).frame(width: Self.searchWidth) }
            }
        }.frame(height: FrogStyle.controlHeight)
    }
}

extension ListToolbar where Filters == EmptyView {
    init(placeholder: String, search: Binding<String>, showsSearch: Bool = true) {
        self.init(placeholder: placeholder, search: search, showsSearch: showsSearch) { EmptyView() }
    }
}
