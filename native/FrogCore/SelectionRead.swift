import CoreGraphics
import Foundation

/// Tells two reads of the same selection apart from reads of different ones, without keeping the text.
public struct SelectionFingerprint: Hashable, Sendable {
    public var pid: Int32
    /// The hash of the element that holds the selection.
    public var element: Int
    /// The selected range in UTF-16 units. Selections read through text markers use the index the app gives for
    /// their first marker, or 0 without one, and the text's length.
    public var location: Int
    public var length: Int
    public var textHash: Int

    public init(pid: Int32, element: Int, location: Int, length: Int, textHash: Int) {
        self.pid = pid; self.element = element; self.location = location; self.length = length; self.textHash = textHash
    }
}

/// A selection read through Accessibility only, never through the clipboard.
public struct SelectionSnapshot: Equatable, Sendable {
    public var text: String
    /// Cocoa coordinates: the union of the selection, or its last character when the union is very tall.
    public var bounds: CGRect?
    /// The last character, for a bubble placed at the end of the selection.
    public var endBounds: CGRect?
    /// The sentence or paragraph around the selection, read only when asked for.
    public var context: String?
    /// The document or page address. Never sent to a model.
    public var source: String?
    public var isEditable: Bool
    public var pid: Int32
    public var bundleID: String?
    public var applicationName: String?
    public var fingerprint: SelectionFingerprint

    public init(text: String, bounds: CGRect?, endBounds: CGRect?, context: String?, source: String?, isEditable: Bool,
                pid: Int32, bundleID: String?, applicationName: String?, fingerprint: SelectionFingerprint) {
        self.text = text; self.bounds = bounds; self.endBounds = endBounds; self.context = context; self.source = source
        self.isEditable = isEditable; self.pid = pid; self.bundleID = bundleID; self.applicationName = applicationName
        self.fingerprint = fingerprint
    }
}

/// What reading the selection found. `unavailable` means the app does not expose it through Accessibility, so a
/// caller that may copy can still try that; `empty` is a caret in a real text field.
public enum SelectionReadResult: Equatable, Sendable {
    case selection(SelectionSnapshot)
    case empty
    case secure
    case tooLong(Int)
    case unavailable
}

/// The decisions of a selection read, apart from the reads themselves.
public enum SelectionReadDecision {
    public enum Step: Equatable, Sendable { case secure, empty, tooLong(Int), readAttributes, tryMarkers }

    /// Path A, before any text is fetched. A caret counts as empty only in a text area or text field: web areas and
    /// other views report a zero-length range while their selection lives in text markers.
    public static func attributes(role: String?, subrole: String?, range: (location: Int, length: Int)?,
                                  maxCharacters: Int) -> Step {
        if subrole == "AXSecureTextField" { return .secure }
        guard let range, range.location >= 0, range.length >= 0 else { return .tryMarkers }
        if range.length == 0 { return ["AXTextArea", "AXTextField"].contains(role ?? "") ? .empty : .tryMarkers }
        if range.length > maxCharacters { return .tooLong(range.length) }
        return .readAttributes
    }

    /// Path B, after the marker text was read. Nil when the selection is usable. A caret in a web area is not a
    /// selection Frog can tell is empty, so it is unavailable.
    public static func markers(textLength: Int?, maxCharacters: Int) -> SelectionReadResult? {
        guard let textLength, textLength > 0 else { return .unavailable }
        if textLength > maxCharacters { return .tooLong(textLength) }
        return nil
    }
}
