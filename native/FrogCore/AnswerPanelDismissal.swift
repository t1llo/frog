import Foundation

/// What can close the answer panel.
public enum PanelEvent: Equatable, Sendable {
    /// The close button or ⌘W.
    case closeButton
    /// Escape while the panel is key.
    case escapeInPanel
    /// Escape typed in another app.
    case escapeElsewhere
    /// A mouse down outside the panel.
    case clickOutside
    /// Another app became active. `isSource`: the app the selection came from.
    case appActivated(isSource: Bool)
}

/// Whether the answer panel closes. A pinned panel closes only when asked to directly.
public enum AnswerPanelDismissal {
    public static func shouldClose(_ event: PanelEvent, pinned: Bool) -> Bool {
        switch event {
        case .closeButton, .escapeInPanel: true
        case .escapeElsewhere, .clickOutside: !pinned
        case .appActivated(let isSource): !isSource && !pinned
        }
    }
}
