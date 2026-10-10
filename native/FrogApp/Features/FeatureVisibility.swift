import AppKit
import SwiftUI

/// An NSWindow can keep its SwiftUI tree mounted after close/minimize. Tie a
/// visible-page collector to native visibility rather than onAppear alone.
struct FeatureVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> VisibilityView { VisibilityView(changed: changed) }
    func updateNSView(_ view: VisibilityView, context: Context) { view.changed = changed }
    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) { view.stop() }

    final class VisibilityView: NSView {
        var changed: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        private var last: Bool?
        init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.deliver(notification.name != NSWindow.willCloseNotification && self.isWindowVisible)
                    }
                })
            }
            deliver(isWindowVisible)
        }
        private var isWindowVisible: Bool { window?.isVisible == true && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true }
        private func deliver(_ visible: Bool) {
            guard last != visible else { return }; last = visible
            // Avoid publishing ObservableObject changes during SwiftUI view construction.
            let callback = changed
            DispatchQueue.main.async { [weak self] in
                guard self?.last == visible else { return }; callback(visible)
            }
        }
        func stop() {
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            last = false; changed(false)
        }
        isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
