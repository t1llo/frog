import SwiftUI

/// Every page of the Frog window: a scroll view with the standard padding, sections 24 apart, and a column
/// no wider than `FrogStyle.pageWidth`. Dashboards and tables pass `FrogStyle.wideWidth`.
struct FrogPage<Content: View>: View {
    var width: CGFloat = FrogStyle.pageWidth
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FrogStyle.sectionSpacing) { content }
                .padding(FrogStyle.pagePadding)
                .frame(maxWidth: width + FrogStyle.pagePadding * 2)
                .frame(maxWidth: .infinity, alignment: .top)
                .minimalScrollbars()
        }
    }
}

/// The top of a page: its title, at most one line of subtitle, and the page's actions on the trailing side.
struct FrogPageHeader<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(title)).font(FrogType.title).tracking(-0.4)
                    .foregroundStyle(FrogStyle.ink).accessibilityAddTraits(.isHeader)
                if let subtitle, !subtitle.isEmpty {
                    Text(L10n.text(subtitle)).font(FrogType.lead).foregroundStyle(FrogStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .overlay { WindowDragRegion().accessibilityHidden(true) }
            actions
        }.frame(minHeight: FrogStyle.controlHeight)
    }
}

extension FrogPageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A group of rows: an optional caption above one rounded card, and an optional one-sentence footer. Rows are
/// set apart by their own height, never by lines.
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
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(spacing: 8) {
                    if let title {
                        Text(L10n.text(title)).font(FrogType.section).foregroundStyle(FrogStyle.ink)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 8)
                    accessory
                }.frame(minHeight: 20).padding(.horizontal, 2)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 14).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frogTableSurface()
            if let footer {
                Text(L10n.text(footer)).font(FrogType.small).foregroundStyle(FrogStyle.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
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
                Text(L10n.text(title)).font(FrogType.body).foregroundStyle(FrogStyle.ink)
                if let caption {
                    Text(L10n.text(caption)).font(FrogType.small).foregroundStyle(FrogStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control.fixedSize(horizontal: true, vertical: false).environment(\.compactRowTitle, title)
        }
        .padding(.vertical, 6)
        .frame(minHeight: FrogStyle.rowHeight)
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
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }
}
