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
            content.controlSize(.small).frame(maxWidth: 245, alignment: .trailing)
        }.padding(.vertical, 3)
    }
}

struct CompactMenu<Content: View>: View {
    let value: String
    @ViewBuilder var content: Content
    @State private var hovering = false
    var body: some View {
        Menu(content: { content }) {
            HStack(spacing: 8) {
                Text(L10n.text(value)).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(FrogStyle.muted)
            }.font(.system(size: 11, weight: .medium))
                .foregroundStyle(FrogStyle.ink)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(hovering ? FrogStyle.accentSoft : FrogStyle.inset, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(hovering ? FrogStyle.accent.opacity(0.45) : FrogStyle.border.opacity(0.4)))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(maxWidth: 220, alignment: .trailing)
            .onHover { hovering = $0 }
            .help(L10n.text(value))
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
