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
                CompactSegments(values: CleanerAppSort.allCases, selected: cleaner.sort, title: \.title) { cleaner.sort = $0 }
            }
            .onSubmit { if let row = apps.first(where: { $0.id == highlighted }) ?? apps.first { open(row) } }
            if apps.isEmpty, cleaner.loadingApps {
                loadingList
            } else if apps.isEmpty {
                if !cleaner.search.trimmingCharacters(in: .whitespaces).isEmpty {
                    FrogEmptyState(symbol: "magnifyingglass", title: "No matching apps", message: "Try its bundle ID.")
                } else {
                    FrogEmptyState(symbol: "app.dashed", title: "No apps found", message: "Drop an app here to review it.",
                                   tint: AppCleanerPlugin.info.tint)
                }
            } else {
                // Headed like the review's groups and every other page's cards, one section's space under the
                // toolbar as Models' sections sit under its tabs.
                VStack(alignment: .leading, spacing: FrogStyle.space8) {
                    FrogSectionHeader("Apps", count: apps.count)
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
                .padding(.top, FrogStyle.sectionSpacing - 10)
            }
        }
    }

    /// The list as it will look, its rows drawn as skeletons, under the heading that says how far the load is, so
    /// the page has its shape at once and nothing moves when the apps arrive.
    private var loadingList: some View {
        VStack(alignment: .leading, spacing: FrogStyle.space8) {
            FrogSectionHeader("Apps") {
                HStack(spacing: FrogStyle.space6) {
                    FrogSpinner(size: .mini, label: "Finding apps")
                    Text(loadingProgress).monospacedDigit()
                }
            }
            VStack(spacing: 2) {
                ForEach(Array(Self.skeletonNameWidths.enumerated()), id: \.offset) { index, width in
                    skeletonRow(nameWidth: width, sizeWidth: index.isMultiple(of: 3) ? 52 : 44)
                }
            }
            .padding(6).frogTableSurface()
            .accessibilityHidden(true)
        }
        .padding(.top, FrogStyle.sectionSpacing - 10)
    }

    /// "Looking in Applications…" until the bundles are found, then how many are being read.
    private var loadingProgress: String {
        guard let count = cleaner.foundAppCount else { return L10n.text("Looking in Applications…") }
        return String(format: L10n.text("Reading %@ apps…"), count.formatted(.number.locale(L10n.locale)))
    }

    /// Names of differing lengths, so the skeleton reads as a list of apps rather than a striped block.
    private static let skeletonNameWidths: [CGFloat] = [96, 140, 72, 118, 160, 88, 124, 104]

    /// One app row's shape: icon, name and size where `appRow` draws them, at its height.
    private func skeletonRow(nameWidth: CGFloat, sizeWidth: CGFloat) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: FrogStyle.smallRadius + 2, style: .continuous).fill(FrogStyle.skeleton)
                .frame(width: 24, height: 24).frame(width: 28, height: 28)
            FrogSkeleton(width: nameWidth, height: 16)
            Spacer(minLength: 8)
            FrogSkeleton(width: sizeWidth, height: 14)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(FrogStyle.skeleton)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func appRow(_ row: CleanerAppRow) -> some View {
        let identity = row.identity
        return Button { open(row) } label: {
            HStack(spacing: 10) {
                ApplicationIcon(path: identity.path, size: 28)
                Text(identity.name).font(FrogType.body).lineLimit(1)
                if let version = identity.version {
                    Text(version).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
                }
                if identity.isAppStore { FrogBadge(text: "App Store") }
                if identity.owner == .administrator { FrogBadge(text: "Needs password") }
                Spacer(minLength: 8)
                if let size = row.size {
                    Text(CleanerFormat.bytes(size.bytes)).font(FrogType.small.monospacedDigit()).foregroundStyle(FrogStyle.muted)
                } else {
                    // Sizes arrive together once the page has measured them; a small spinner says they are coming.
                    FrogSpinner(size: .mini, label: "Measuring size")
                }
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
