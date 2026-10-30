import SwiftUI

/// How a dropdown draws one value: its row in the list and, when chosen, the button.
struct FrogDropdownItem {
    var title: String
    /// One short line under the title in the list. Search matches it too.
    var detail: String? = nil
    var symbol: String? = nil
    /// A small badge after the title, such as "Recommended".
    var badge: String? = nil
    /// Shown but not choosable.
    var disabled = false

    init(_ title: String, detail: String? = nil, symbol: String? = nil, badge: String? = nil, disabled: Bool = false) {
        self.title = title; self.detail = detail; self.symbol = symbol; self.badge = badge; self.disabled = disabled
    }
}

/// A group of values under an optional caption.
struct FrogDropdownSection<Value: Hashable>: Identifiable {
    var title: String?
    var values: [Value]
    var id: String { title ?? "" }

    init(_ title: String? = nil, values: [Value]) { self.title = title; self.values = values }
}

/// Frog's one control for a single choice: a 28-point button with the current value and a chevron, opening one
/// list with a checkmark on the chosen row. Arrow keys move, Return chooses, Escape closes. With `searchPrompt`
/// the same list gets a search field on top, for long lists such as models, apps and microphones.
///
/// For an optional choice make `Value` optional and offer `nil` as a value ("System default", "None").
struct FrogDropdown<Value: Hashable>: View {
    let sections: [FrogDropdownSection<Value>]
    let selected: Value
    let choose: (Value) -> Void
    let item: (Value) -> FrogDropdownItem
    var width: CGFloat = 220
    /// 24 points tall, for popups, panel headers and dense rows.
    var compact = false
    /// Turns on the search field, with this placeholder.
    var searchPrompt: String? = nil
    /// What the button says while the chosen value is in no section. Without one it names the value anyway.
    var placeholder: String? = nil
    /// The width of the list; by default the button's, and at least 240 (320 with search).
    var listWidth: CGFloat? = nil
    /// Said in the list when it has no values at all.
    var emptyMessage = "Nothing to choose from."
    /// One sentence under the list, such as where to get more values.
    var footnote: String? = nil
    /// What the button says for a value, when it should be shorter than the list's row.
    var buttonTitle: ((Value) -> String)? = nil

    @State private var showing = false
    @Environment(\.compactRowTitle) private var rowTitle
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let listed = sections.contains { $0.values.contains(selected) }
        let current = listed || placeholder == nil ? item(selected) : nil
        let value = L10n.text(current.map { buttonTitle?(selected) ?? $0.title } ?? placeholder ?? "")
        Button { showing.toggle() } label: {
            EmptyView()
        }
        .buttonStyle(DropdownTriggerStyle(value: value, symbol: current?.symbol, width: width,
                                          height: compact ? FrogStyle.compactHeight : FrogStyle.controlHeight, open: showing))
        .help(value)
        .modifier(RowControlName(title: rowTitle, value: value))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            FrogDropdownList(sections: sections, selected: selected, item: item, searchPrompt: searchPrompt,
                             emptyMessage: emptyMessage, footnote: footnote,
                             width: listWidth ?? max(width, searchPrompt == nil ? 240 : 320)) { value in
                showing = false
                choose(value)
            } dismiss: { showing = false }
                // The options are not controls of the row.
                .environment(\.compactRowTitle, nil)
        }
        .onChange(of: enabled) { _, on in if !on { showing = false } }
    }
}

extension FrogDropdown {
    /// Values in sections, each drawn by `item`.
    init(selection: Binding<Value>, sections: [FrogDropdownSection<Value>], width: CGFloat = 220, compact: Bool = false,
         searchPrompt: String? = nil, placeholder: String? = nil, listWidth: CGFloat? = nil,
         emptyMessage: String = "Nothing to choose from.", item: @escaping (Value) -> FrogDropdownItem) {
        self.init(sections: sections, selected: selection.wrappedValue, choose: { selection.wrappedValue = $0 }, item: item,
                  width: width, compact: compact, searchPrompt: searchPrompt, placeholder: placeholder,
                  listWidth: listWidth, emptyMessage: emptyMessage)
    }

    /// One list of values, each named by `title` and, optionally, a symbol.
    init(selection: Binding<Value>, options: [Value], width: CGFloat = 220, compact: Bool = false,
         searchPrompt: String? = nil, placeholder: String? = nil,
         title: @escaping (Value) -> String, symbol: ((Value) -> String?)? = nil) {
        self.init(selection: selection, sections: [.init(values: options)], width: width, compact: compact,
                  searchPrompt: searchPrompt, placeholder: placeholder) { FrogDropdownItem(title($0), symbol: symbol?($0)) }
    }

    /// The same, for a choice that is saved through an action rather than a binding.
    init(selected: Value, options: [Value], width: CGFloat = 220, compact: Bool = false,
         searchPrompt: String? = nil, placeholder: String? = nil,
         title: @escaping (Value) -> String, symbol: ((Value) -> String?)? = nil, choose: @escaping (Value) -> Void) {
        self.init(sections: [.init(values: options)], selected: selected, choose: choose,
                  item: { FrogDropdownItem(title($0), symbol: symbol?($0)) },
                  width: width, compact: compact, searchPrompt: searchPrompt, placeholder: placeholder)
    }

    /// Sections, saved through an action.
    init(selected: Value, sections: [FrogDropdownSection<Value>], width: CGFloat = 220, compact: Bool = false,
         searchPrompt: String? = nil, placeholder: String? = nil, listWidth: CGFloat? = nil,
         emptyMessage: String = "Nothing to choose from.", footnote: String? = nil,
         item: @escaping (Value) -> FrogDropdownItem, choose: @escaping (Value) -> Void) {
        self.init(sections: sections, selected: selected, choose: choose, item: item, width: width, compact: compact,
                  searchPrompt: searchPrompt, placeholder: placeholder, listWidth: listWidth, emptyMessage: emptyMessage,
                  footnote: footnote)
    }
}

extension FrogDropdown {
    /// A shorter text for the button than the list's row, such as "7d" for "Last 7 days".
    func buttonTitle(_ title: @escaping (Value) -> String) -> Self {
        var copy = self; copy.buttonTitle = title; return copy
    }
}

/// The dropdown's button: the shared control surface, darker while pressed or open.
private struct DropdownTriggerStyle: ButtonStyle {
    let value: String
    let symbol: String?
    let width: CGFloat
    let height: CGFloat
    let open: Bool
    func makeBody(configuration: Configuration) -> some View {
        DropdownTrigger(value: value, symbol: symbol, width: width, height: height, pressed: configuration.isPressed || open)
    }
}

private struct DropdownTrigger: View {
    let value: String
    let symbol: String?
    let width: CGFloat
    let height: CGFloat
    let pressed: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        CompactDropdownLabel(value: value, symbol: symbol, width: width, height: height, pressed: pressed && enabled)
            .opacity(enabled ? 1 : 0.45)
    }
}

/// Moving through a dropdown's rows with the keyboard: up and down step over disabled rows and wrap around.
struct FrogDropdownNavigation<Value: Hashable> {
    /// The rows that can be chosen, in the order they are shown.
    let values: [Value]

    func next(after current: Value?, by step: Int) -> Value? {
        guard !values.isEmpty else { return nil }
        guard let current, let index = values.firstIndex(of: current) else { return step > 0 ? values.first : values.last }
        return values[(index + step + values.count) % values.count]
    }
}

/// The list in a dropdown's popover. Also drawn on its own in the design gallery.
struct FrogDropdownList<Value: Hashable>: View {
    let sections: [FrogDropdownSection<Value>]
    let selected: Value
    let item: (Value) -> FrogDropdownItem
    var searchPrompt: String? = nil
    var emptyMessage = "Nothing to choose from."
    var footnote: String? = nil
    var width: CGFloat = 240
    let choose: (Value) -> Void
    var dismiss: () -> Void = {}

    @State private var query = ""
    /// The row the pointer or the arrow keys are on. One highlight for both, as in a menu.
    @State private var highlighted: Value?
    @FocusState private var listFocused: Bool
    @FocusState private var fieldFocused: Bool

    private var visible: [FrogDropdownSection<Value>] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sections.filter { !$0.values.isEmpty } }
        return sections.map { section in
            FrogDropdownSection(section.title, values: section.values.filter { value in
                let item = item(value)
                return (L10n.text(item.title) + " " + (item.detail ?? "")).localizedStandardContains(query)
            })
        }.filter { !$0.values.isEmpty }
    }

    var body: some View {
        let sections = visible
        let navigation = FrogDropdownNavigation(values: sections.flatMap(\.values).filter { !item($0).disabled })
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if let searchPrompt {
                    SearchBox(placeholder: searchPrompt, text: $query, focus: $fieldFocused)
                        .padding([.horizontal, .top], 6).padding(.bottom, 2)
                        .onSubmit { if let highlighted { choose(highlighted) } }
                        .onChange(of: query) { _, _ in highlighted = visible.flatMap(\.values).first { !item($0).disabled } }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                            if let title = section.title {
                                Text(L10n.text(title)).font(FrogType.label).foregroundStyle(FrogStyle.muted)
                                    .padding(.horizontal, 8).padding(.top, index == 0 ? 2 : 8).padding(.bottom, 2)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ForEach(section.values, id: \.self) { value in
                                FrogDropdownRow(item: item(value), chosen: value == selected, highlighted: value == highlighted) {
                                    choose(value)
                                }
                                .id(value)
                                .onHover { inside in if inside, !item(value).disabled { highlighted = value } }
                            }
                        }
                        if sections.isEmpty {
                            Text(L10n.text(self.sections.allSatisfy(\.values.isEmpty) ? emptyMessage : "No matches."))
                                .font(FrogType.small).foregroundStyle(FrogStyle.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }
                    }.padding(6)
                }
                .frame(maxHeight: 300).fixedSize(horizontal: false, vertical: true)
                if let footnote {
                    Text(L10n.text(footnote)).font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .bottom], 14)
                }
            }
            .frame(width: width)
            .foregroundStyle(FrogStyle.ink)
            // Without a search field the list itself takes the keys.
            .focusable(searchPrompt == nil)
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(navigation, by: 1, proxy); return .handled }
            .onKeyPress(.upArrow) { move(navigation, by: -1, proxy); return .handled }
            .onKeyPress(.return) {
                // The search field chooses through its own submit.
                guard searchPrompt == nil, let highlighted else { return .ignored }
                choose(highlighted); return .handled
            }
            .onKeyPress(.escape) { dismiss(); return .handled }
            .onAppear {
                // It opens on the chosen row, as a menu does.
                if navigation.values.contains(selected) {
                    highlighted = selected
                    if navigation.values.count > 8 { proxy.scrollTo(selected, anchor: .center) }
                }
                if searchPrompt == nil { listFocused = true } else { fieldFocused = true }
            }
        }
        .frogSurface(.popover)
        // Arrow keys move the highlight many times a second: it moves at once, without hover fades.
        .environment(\.frogKeyboardSurface, true)
    }

    private func move(_ navigation: FrogDropdownNavigation<Value>, by step: Int, _ proxy: ScrollViewProxy) {
        highlighted = navigation.next(after: highlighted, by: step)
        if let highlighted { proxy.scrollTo(highlighted) }
    }
}

/// A row of the list: symbol, title, optional detail and badge, and the checkmark on the chosen value.
struct FrogDropdownRow: View {
    let item: FrogDropdownItem
    let chosen: Bool
    let highlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol = item.symbol {
                    Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(FrogStyle.muted).frame(width: 16)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(L10n.text(item.title)).font(chosen ? FrogType.bodyMedium : FrogType.body).lineLimit(1)
                        if let badge = item.badge { FrogBadge(text: badge, active: true).fixedSize() }
                    }
                    if let detail = item.detail {
                        Text(L10n.text(detail)).font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(FrogStyle.accent)
                    .opacity(chosen ? 1 : 0).accessibilityHidden(true)
            }
            .padding(.horizontal, 8).padding(.vertical, item.detail == nil ? 0 : 5)
            .frame(minHeight: FrogStyle.controlHeight)
            .frogRowHighlight(hovering: highlighted && !item.disabled)
            .opacity(item.disabled ? 0.45 : 1)
        }
        .buttonStyle(.plain).disabled(item.disabled)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
