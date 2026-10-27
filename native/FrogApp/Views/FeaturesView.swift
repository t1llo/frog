import SwiftUI
import FrogCore

/// Turns features on and off. Each feature's settings are on its own page.
struct FeaturesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var pending = Set<FeatureID>()

    private var shown: [FeatureID] {
        FeatureID.allCases.filter { search.isEmpty || ($0.title + " " + $0.detail).localizedStandardContains(search) }
    }

    var body: some View {
        PageScroll {
            PageHeader(title: "Features")
            SearchBox(placeholder: "Find a feature", text: $search)
            let shown = shown
            if shown.isEmpty {
                FrogEmptyState(symbol: "magnifyingglass", title: "No matches", message: "Try another word.")
            } else {
                VStack(spacing: 2) {
                    ForEach(shown, id: \.self) { feature in row(feature) }
                }.padding(6).frogTableSurface()
            }
        }
    }

    private func row(_ feature: FeatureID) -> some View {
        let enabled = model.configuration.preferences.featureEnabled(feature)
        return HStack(spacing: 12) {
            Image(systemName: feature.symbol).font(.system(size: 14)).frame(width: 22).foregroundStyle(FrogStyle.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(feature.title)).font(FrogType.bodyMedium)
                Text(L10n.text(feature.detail)).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if enabled {
                Button("Open") { model.toolkit.select(.feature(feature)) }
                    .buttonStyle(.frog(.ghost, compact: true))
                    .accessibilityLabel("Open \(feature.title)")
            }
            Toggle(feature.title, isOn: Binding(get: { enabled }, set: { on in
                pending.insert(feature)
                Task {
                    defer { pending.remove(feature) }
                    do { try await model.setFeature(feature, enabled: on) } catch { model.report(error) }
                }
            })).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(pending.contains(feature))
        }.padding(.horizontal, 8).padding(.vertical, 7).frogHoverRow()
    }
}
