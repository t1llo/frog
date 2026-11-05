import SwiftUI

/// Every page of the Frog window: a scroll view with the standard padding, sections `sectionSpacing` apart, and
/// a column no wider than `FrogStyle.pageWidth`. Dashboards and tables pass `FrogStyle.wideWidth`. In the main
/// window the toolbar above holds the title, so the page starts close under it.
struct FrogPage<Content: View>: View {
    var width: CGFloat = FrogStyle.pageWidth
    @ViewBuilder var content: Content
    @Environment(\.frogToolbarTitle) private var titleInToolbar

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FrogStyle.sectionSpacing) { content }
                .padding(.horizontal, FrogStyle.pagePadding).padding(.bottom, FrogStyle.pagePadding)
                .padding(.top, titleInToolbar ? FrogStyle.toolbarFade : FrogStyle.pagePadding)
                .frame(maxWidth: width + FrogStyle.pagePadding * 2)
                .frame(maxWidth: .infinity, alignment: .top)
                .minimalScrollbars()
        }
    }
}

/// The open page's title, which `FrogPageHeader` hands up to the main window's toolbar.
struct FrogPageTitleKey: PreferenceKey {
    static let defaultValue: String? = nil
    /// The first header on a page names it.
    static func reduce(value: inout String?, nextValue: () -> String?) { value = value ?? nextValue() }
}

private struct FrogToolbarTitleKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True on the pages of the main window, whose toolbar shows the title. A sheet sets it back to false, so
    /// its header draws its own title.
    var frogToolbarTitle: Bool {
        get { self[FrogToolbarTitleKey.self] }
        set { self[FrogToolbarTitleKey.self] = newValue }
    }
}

/// The top of a page: its title, at most one line of subtitle, and the page's actions on the trailing side.
/// In the main window the title sits in the toolbar beside back and forward, so the header keeps only the
/// subtitle and actions, and takes no room when it has neither.
struct FrogPageHeader<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var actions: Actions
    @Environment(\.frogToolbarTitle) private var titleInToolbar

    var body: some View {
        let hasSubtitle = subtitle.map { !$0.isEmpty } ?? false
        let hasActions = Actions.self != EmptyView.self
        Group {
            if !titleInToolbar || hasSubtitle || hasActions {
                HStack(alignment: .center, spacing: FrogStyle.space16) {
                    VStack(alignment: .leading, spacing: FrogStyle.space2) {
                        if !titleInToolbar {
                            // As tall as a control, so the title sits at the same height with or without a
                            // subtitle or actions.
                            Text(L10n.text(title)).font(FrogType.title).tracking(-0.4)
                                .foregroundStyle(FrogStyle.ink).accessibilityAddTraits(.isHeader)
                                .frame(minHeight: FrogStyle.controlHeight)
                        }
                        if let subtitle, hasSubtitle {
                            Text(L10n.text(subtitle)).font(FrogType.lead).foregroundStyle(FrogStyle.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.frame(maxWidth: .infinity, minHeight: FrogStyle.controlHeight, alignment: .leading)
                        .overlay { WindowDragRegion().accessibilityHidden(true) }
                    if hasActions { HStack(spacing: FrogStyle.space8) { actions } }
                }
            }
        }.preference(key: FrogPageTitleKey.self, value: L10n.text(title))
    }
}

extension FrogPageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A group of rows: an optional caption above one rounded card, and an optional one-sentence footer. The card
/// draws a thin line between two `FrogRow`s, inset to the content edge; nothing else in Frog draws lines.
struct FrogSection<Content: View, Accessory: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder accessory: () -> Accessory,
         @ViewBuilder content: () -> Content) {
        self.title = title; self.footer = footer; self.accessory = accessory(); self.content = content()
    }

    var body: some View {
        // Rex's spacing: the heading and the note under the card start where the rows' text does, 10 in.
        VStack(alignment: .leading, spacing: FrogStyle.space10) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(spacing: 8) {
                    if let title {
                        Text(L10n.text(title)).font(FrogType.section).foregroundStyle(FrogStyle.ink)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 8)
                    accessory
                }.frame(minHeight: 20).padding(.horizontal, FrogStyle.rowInset)
            }
            SeparatedRows { content }
                .padding(.horizontal, FrogStyle.rowInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frogTableSurface()
            if let footer {
                Text(L10n.text(footer)).font(FrogType.small).foregroundStyle(FrogStyle.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, FrogStyle.rowInset)
            }
        }
    }
}

extension FrogSection where Accessory == EmptyView {
    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, footer: footer, accessory: { EmptyView() }, content: content)
    }
}

/// One setting: a title, at most one short caption, and its control on the trailing side. At least
/// `FrogStyle.rowHeight` tall, so a section's rows line up whatever their control.
struct FrogRow<Control: View, Icon: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder var icon: Icon
    @ViewBuilder var control: Control

    init(_ title: String, caption: String? = nil, @ViewBuilder icon: () -> Icon, @ViewBuilder control: () -> Control) {
        self.title = title; self.caption = caption; self.icon = icon(); self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(title)).font(FrogType.row).foregroundStyle(FrogStyle.ink)
                if let caption {
                    Text(L10n.text(caption)).font(FrogType.small).foregroundStyle(FrogStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            // Every on/off setting in a row is Rex's switch.
            control.fixedSize(horizontal: true, vertical: false).environment(\.compactRowTitle, title)
                .toggleStyle(.frogSwitch)
        }
        .padding(.vertical, 7)
        .frame(minHeight: FrogStyle.rowHeight)
        .markedAsSeparatedRow()
    }
}

private extension View {
    @ViewBuilder func markedAsSeparatedRow() -> some View {
        if #available(macOS 15, *) { containerValue(\.frogSeparatedRow, true) } else { self }
    }
}

/// A step back inside the open page, such as from a History entry to its list. The main window's Back (⌘[)
/// takes it before going to the previous page.
struct FrogPageBack: Equatable {
    let id: String
    let action: () -> Void
    static func == (lhs: FrogPageBack, rhs: FrogPageBack) -> Bool { lhs.id == rhs.id }
}

struct FrogPageBackKey: PreferenceKey {
    static let defaultValue: FrogPageBack? = nil
    static func reduce(value: inout FrogPageBack?, nextValue: () -> FrogPageBack?) { value = value ?? nextValue() }
}

extension View {
    /// Offers a step back inside the page to the toolbar's Back. `id` names the state it leaves.
    func frogPageBack(_ id: String, perform action: @escaping () -> Void) -> some View {
        preference(key: FrogPageBackKey.self, value: FrogPageBack(id: id, action: action))
    }
}

@available(macOS 15, *)
private struct FrogSeparatedRowKey: ContainerValueKey { static let defaultValue = false }

@available(macOS 15, *)
extension ContainerValues {
    /// Set by `FrogRow`, so `FrogSection` draws its line only between two rows. Written out rather than with
    /// `@Entry`, whose macro plugin the Command Line Tools lack.
    var frogSeparatedRow: Bool {
        get { self[FrogSeparatedRowKey.self] }
        set { self[FrogSeparatedRowKey.self] = newValue }
    }
}

/// The rows of a section card, one thin line between each two. A row hidden by an `if` takes its line with it.
/// macOS 14 cannot list a view's children, so there the rows are set apart by their height alone.
private struct SeparatedRows<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 15, *) {
            Group(subviews: content) { rows in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        // A line only between two settings: a note, caption or warning stays with the row above it.
                        if row.containerValues.frogSeparatedRow, let index = rows.firstIndex(where: { $0.id == row.id }),
                           index > rows.startIndex, rows[rows.index(before: index)].containerValues.frogSeparatedRow {
                            Rectangle().fill(FrogStyle.separator).frame(height: 1).accessibilityHidden(true)
                        }
                        row
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) { content }
        }
    }
}

extension FrogRow where Icon == EmptyView {
    init(_ title: String, caption: String? = nil, @ViewBuilder control: () -> Control) {
        self.init(title, caption: caption, icon: { EmptyView() }, control: control)
    }
}

extension FrogRow where Icon == EmptyView, Control == EmptyView {
    init(_ title: String, caption: String? = nil) {
        self.init(title, caption: caption, icon: { EmptyView() }, control: { EmptyView() })
    }
}

/// A sentence inside a section card that belongs to no row: a status, a warning, a hint.
struct FrogRowNote: View {
    let text: String
    var tone: Color = FrogStyle.muted
    var body: some View {
        Text(L10n.text(text)).font(FrogType.small).foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, FrogStyle.space8)
    }
}
