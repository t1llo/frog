import SwiftUI

struct SearchBox: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10n.text(placeholder), text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
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
                .foregroundStyle(selected ? FrogStyle.accent : FrogStyle.muted)
                .background(selected ? FrogStyle.accentSoft : .clear, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
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
                if let detail { Text(L10n.text(detail)).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            content.controlSize(.small).fixedSize(horizontal: true, vertical: false)
        }.padding(.vertical, 3)
    }
}

struct CompactMenu<Content: View>: View {
    let value: String
    @ViewBuilder var content: Content
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            CompactDropdownLabel(value: L10n.text(value))
        }.buttonStyle(.plain).help(L10n.text(value))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) { content }
                        .buttonStyle(CompactOptionStyle { showing = false })
                        .padding(8)
                }.frame(width: 280).frame(maxHeight: 280).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(FrogStyle.ink).background(FrogStyle.panelSurface)
            }
    }
}

struct CompactDropdownLabel: View {
    let value: String
    var symbol: String? = nil
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol).foregroundStyle(FrogStyle.muted) }
            Text(value).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 2)
            Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(FrogStyle.muted)
        }.font(.system(size: 11, weight: .medium)).foregroundStyle(FrogStyle.ink)
            .padding(.horizontal, 9).frame(width: 220, height: 32)
            .background(hovering ? FrogStyle.accentSoft : FrogStyle.inset, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(FrogStyle.border.opacity(0.6)))
            .contentShape(RoundedRectangle(cornerRadius: 7)).onHover { hovering = $0 }
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
    let title: (Value) -> String
    let choose: (Value) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(values, id: \.self) { value in
                Button { choose(value) } label: {
                    Text(L10n.text(title(value))).font(.system(size: 11, weight: selected == value ? .semibold : .regular))
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .foregroundStyle(selected == value ? FrogStyle.accent : FrogStyle.muted)
                        .background(selected == value ? FrogStyle.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).accessibilityAddTraits(selected == value ? .isSelected : [])
            }
        }.padding(3).frame(width: 220).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 7))
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
