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
    var body: some View {
        Menu(content: { content }) {
            HStack(spacing: 8) {
                Text(L10n.text(value)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 6)
                .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
                .overlay(RoundedRectangle(cornerRadius: FrogStyle.corner).strokeBorder(FrogStyle.border.opacity(0.6)))
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
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
