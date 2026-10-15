import CoreGraphics
import Foundation

/// Where an answer panel is placed next to a selection.
public enum SelectionAnchor {
    /// The selection's rectangle, or the rectangle of its last character when the selection is taller than half of
    /// its screen (a panel beside a whole page helps nobody) or reports no rectangle of its own. `last` is read only
    /// when it is needed. Nil when neither helps, so the panel opens at the pointer.
    public static func choose(union: CGRect?, last: @autoclosure () -> CGRect?, screenHeight: CGFloat) -> CGRect? {
        if let union, union.height <= screenHeight / 2 { return union }
        return last()
    }
}

/// The part of a long text read to find the sentence or paragraph around a selection.
public enum ContextWindow {
    /// The UTF-16 range to read around a selection, clamped to the text.
    public static func range(selection: (location: Int, length: Int), count: Int, margin: Int) -> (location: Int, length: Int) {
        let count = max(0, count), margin = max(0, margin)
        let start = min(max(0, selection.location), count)
        let end = min(max(start, start + max(0, selection.length)), count)
        let location = max(0, start - margin)
        return (location, min(count, end + margin) - location)
    }
}

/// The document or page a selection came from, as kept in History and notes. It is never sent to a model.
public enum SourceAddress {
    /// The address without the parts that can carry credentials or tokens (user, password, query and fragment), for
    /// web pages and files only.
    public static func clean(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return nil }
        if scheme != "file", (components.host ?? "").isEmpty { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string
    }
}
