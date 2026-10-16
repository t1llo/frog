import SwiftUI
import AppKit
import FrogCore

/// The sidebar's features, pinned ones first. Holding Shift, a row can be dragged to another place; dropped among
/// the pinned rows it is pinned, among the others unpinned. The context menu pins, moves and resets as well.
struct SidebarFeatureList<Row: View>: View {
    @EnvironmentObject private var model: AppModel
    let features: [FeatureID]
    /// A feature's row, given the symbol to show at its end: a pin, or a grip while Shift is held.
    @ViewBuilder let row: (FeatureID, _ marker: String?) -> Row

    @StateObject private var shift = ShiftKeyWatcher()
    @State private var hovering = false
    @State private var frames: [FeatureID: CGRect] = [:]
    @State private var dragged: FeatureID?
    @State private var drop: Int?
    /// A drag begun without Shift is a click or a scroll as before, and is left alone until it ends.
    @State private var ignoringDrag = false

    private static var space: String { "sidebarFeatures" }

    private var arrangement: SidebarArrangement {
        let settings = model.configuration.preferences.toolkitSettings
        return SidebarArrangement(order: settings.sidebarOrder, pinned: settings.pinnedSidebarItems)
    }

    var body: some View {
        let arrangement = arrangement
        let grips = hovering && shift.held
        VStack(spacing: 2) {
            ForEach(Array(features.enumerated()), id: \.element) { index, feature in
                if index > 0, arrangement.pinned.contains(features[index - 1]), !arrangement.pinned.contains(feature) {
                    Divider().opacity(0.6).padding(.horizontal, 9).padding(.vertical, 3)
                }
                row(feature, grips ? "line.3.horizontal" : arrangement.pinned.contains(feature) ? "pin.fill" : nil)
                    .opacity(dragged == feature ? 0.45 : 1)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: SidebarRowFrames.self, value: [feature: proxy.frame(in: .named(Self.space))])
                    })
                    .simultaneousGesture(drag(feature))
                    .contextMenu { menu(feature, arrangement: arrangement) }
            }
        }
        .coordinateSpace(name: Self.space)
        .overlay(alignment: .topLeading) { dropLine }
        .onPreferenceChange(SidebarRowFrames.self) { frames = $0 }
        .onHover { inside in
            hovering = inside
            if inside { shift.start() } else if dragged == nil { shift.stop() }
        }
        .onDisappear { shift.stop() }
    }

    private func drag(_ feature: FeatureID) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragged == nil, !ignoringDrag {
                    guard NSEvent.modifierFlags.contains(.shift) else { ignoringDrag = true; return }
                    dragged = feature
                }
                guard dragged == feature else { return }
                drop = dropIndex(at: value.location.y)
            }
            .onEnded { _ in
                let moved = dragged == feature ? drop : nil
                dragged = nil; drop = nil; ignoringDrag = false
                if !hovering { shift.stop() }
                guard let moved else { return }
                save { $0.move(feature, to: moved, in: features) }
            }
    }

    /// The gap nearest the pointer: the index of the first row whose middle lies below it.
    private func dropIndex(at y: CGFloat) -> Int {
        features.firstIndex { frames[$0].map { y < $0.midY } ?? false } ?? features.count
    }

    /// Where the dragged row would go, unless that is where it already is.
    @ViewBuilder private var dropLine: some View {
        if let dragged, let drop, let from = features.firstIndex(of: dragged), drop != from, drop != from + 1, let y = lineY(drop) {
            Capsule().fill(FrogStyle.accent).frame(height: 2).padding(.horizontal, 4).offset(y: y - 1)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func lineY(_ index: Int) -> CGFloat? {
        if features.indices.contains(index) { return frames[features[index]].map { $0.minY - 1 } }
        return features.last.flatMap { frames[$0] }.map { $0.maxY + 1 }
    }

    @ViewBuilder private func menu(_ feature: FeatureID, arrangement: SidebarArrangement) -> some View {
        let pinned = arrangement.pinned.contains(feature)
        Button(pinned ? "Unpin" : "Pin to top", systemImage: pinned ? "pin.slash" : "pin") {
            save { $0.setPinned(feature, !pinned) }
        }
        Button("Move up", systemImage: "arrow.up") { save { $0.move(feature, by: -1, in: features) } }
            .disabled(!arrangement.canMove(feature, by: -1, in: features))
        Button("Move down", systemImage: "arrow.down") { save { $0.move(feature, by: 1, in: features) } }
            .disabled(!arrangement.canMove(feature, by: 1, in: features))
        Divider()
        Button("Reset sidebar order") { save { $0 = SidebarArrangement(order: [], pinned: []) } }
            .disabled(!arrangement.isCustom)
        Text("Hold Shift and drag a row to move it")
    }

    private func save(_ change: (inout SidebarArrangement) -> Void) {
        var next = arrangement
        change(&next)
        do {
            try model.updateToolkit { $0.sidebarOrder = next.storedOrder; $0.pinnedSidebarItems = next.storedPinned }
        } catch { model.report(error) }
    }
}

private struct SidebarRowFrames: PreferenceKey {
    static var defaultValue: [FeatureID: CGRect] { [:] }
    static func reduce(value: inout [FeatureID: CGRect], nextValue: () -> [FeatureID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Whether Shift is down, while the pointer is over the sidebar: the rows show grips then. Watching only there
/// keeps capital letters typed on a page from flashing them.
@MainActor private final class ShiftKeyWatcher: ObservableObject {
    @Published private(set) var held = false
    private var monitor: Any?

    func start() {
        held = NSEvent.modifierFlags.contains(.shift)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let held = event.modifierFlags.contains(.shift)
            MainActor.assumeIsolated { self?.held = held }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        held = false
    }
}
