import SwiftUI
import FrogCore

/// The apps Frog may remove, searchable by name and bundle ID. A click or Return opens an app's review.
struct CleanerAppsView: View {
    @ObservedObject var cleaner: CleanerModel
    @State private var highlighted: String?
    @FocusState private var listFocused: Bool

    var body: some View {
        let apps = cleaner.visibleApps
        VStack(alignment: .leading, spacing: 10) {
            ListToolbar(placeholder: "Search apps", search: $cleaner.search) {
                CompactSegments(values: CleanerAppSort.allCases, selected: cleaner.sort, width: 140, title: \.title) { cleaner.sort = $0 }
            }
            .onSubmit { if let row = apps.first(where: { $0.id == highlighted }) ?? apps.first { open(row) } }
            if apps.isEmpty {
                if cleaner.loadingApps {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Finding apps…").font(FrogType.body).foregroundStyle(FrogStyle.muted)
                    }.padding(.vertical, 12)
                } else if !cleaner.search.trimmingCharacters(in: .whitespaces).isEmpty {
                    FrogEmptyState(symbol: "magnifyingglass", title: "No matching apps",
                                   message: "Search by an app's name or its bundle ID.")
                } else {
                    FrogEmptyState(symbol: "app.dashed", title: "No apps found",
                                   message: "Apps in your Applications folders appear here. Drop an app onto this page to review it.")
                }
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(apps) { row in appRow(row) }
                }
                .padding(6).frogTableSurface()
                .focusable().focused($listFocused).focusEffectDisabled()
                .onKeyPress(.downArrow) { move(1, in: apps) }
                .onKeyPress(.upArrow) { move(-1, in: apps) }
                .onKeyPress(.return) {
                    guard let row = apps.first(where: { $0.id == highlighted }) else { return .ignored }
                    open(row)
                    return .handled
                }
            }
            Text("Drop an app here to review it.").font(FrogType.small).foregroundStyle(FrogStyle.muted)
        }
    }

    private func appRow(_ row: CleanerAppRow) -> some View {
        let identity = row.identity
        return Button { open(row) } label: {
            HStack(spacing: 10) {
                ApplicationIcon(path: identity.path, size: 24)
                Text(identity.name).font(FrogType.bodyMedium).lineLimit(1)
                if let version = identity.version {
                    Text(version).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
                }
                if identity.isAppStore { FrogBadge(text: "App Store") }
                if identity.owner == .administrator { FrogBadge(text: "Needs password") }
                Spacer(minLength: 8)
                Text(row.size.map { CleanerFormat.bytes($0.bytes) } ?? "—")
                    .font(FrogType.small.monospacedDigit()).foregroundStyle(FrogStyle.muted)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FrogStyle.muted).accessibilityHidden(true)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            // The pointer and the arrow keys move one highlight, so it is drawn as the chosen row.
            .frogRowHighlight(hovering: false, selected: highlighted == row.id)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlighted = row.id } }
        .accessibilityLabel(identity.name)
        .accessibilityHint("Opens the review of what moves to the Trash")
    }

    private func move(_ step: Int, in apps: [CleanerAppRow]) -> KeyPress.Result {
        guard !apps.isEmpty else { return .ignored }
        let index = apps.firstIndex { $0.id == highlighted }.map { $0 + step } ?? (step > 0 ? 0 : apps.count - 1)
        highlighted = apps[min(max(index, 0), apps.count - 1)].id
        return .handled
    }

    private func open(_ row: CleanerAppRow) {
        highlighted = row.id
        Task { await cleaner.open(row.identity.url) }
    }
}
