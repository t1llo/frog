import Foundation
import XCTest

/// Colours, radii, controls and text come from the theme tokens, so every view follows the theme and
/// docs/design.md. The scan reads the app's sources as text; it opens no window.
final class StyleTokenScanTests: XCTestCase {
    /// `"File.swift: pattern"` entries a view may keep, each with a comment that says why.
    private let allowed: Set<String> = []

    /// A plugin's `tint: .orange` is a `PluginTint`, not a colour, so it is not matched.
    func testViewsUseThemeColoursInsteadOfRawOrangeAndRed() throws {
        try assertNoMatch(#"(?<!tint: |case )\.orange\b|Color\.red\b|\.red\.opacity|foregroundStyle\(\.red\)"#,
                          "use FrogStyle.warning or FrogStyle.critical")
    }

    func testViewsUseTheMutedColourInsteadOfSystemSecondary() throws {
        try assertNoMatch(#"foregroundStyle\(\.secondary\)"#, "use FrogStyle.muted")
    }

    func testControlsUseRadiusTokens() throws {
        try assertNoMatch(#"cornerRadius:\s*[0-9]|\.cornerRadius\(\s*[0-9]"#, "use a FrogStyle radius",
                          except: ["Views/DesignSystem.swift"])
    }

    func testContentIsSeparatedBySpaceRatherThanLines() throws {
        try assertNoMatch(#"\bDivider\(\)|\.separator\(\)"#, "separate with space, a heading or a surface")
        // Markdown rules and quote bars are the user's own content.
        try assertNoMatch(#"Rectangle\(\)\.fill\(FrogStyle\.border"#, "separate with space, a heading or a surface",
                          except: ["Views/MarkdownPreview.swift"])
    }

    func testControlsAreFrogsOwn() throws {
        try assertNoMatch(#"\.buttonStyle\(\.(bordered|borderedProminent|borderless|link|accessoryBar)\b"#, "use FrogButtonStyle")
        try assertNoMatch(#"\.textFieldStyle\(\.(roundedBorder|squareBorder)\)"#, "use LabeledField or frogControlSurface")
        try assertNoMatch(#"\.toggleStyle\(\.checkbox\)"#, "use a switch")
        try assertNoMatch(#"\bStepper\("#, "offer the choices in a CompactMenu")
        // The dictation pill's microphone menu is the one bare symbol, in the accent colour.
        try assertNoMatch(#"\.menuStyle\(\.borderlessButton\)"#, "use IconMenu: the borderless style drops Frog's surface and hover",
                          except: ["Platform/DictationController.swift"])
    }

    func testTextUsesFrogsTypeScale() throws {
        try assertNoMatch(#"\.font\(\.(caption2?|headline|title[23]?|body|callout|subheadline|footnote|largeTitle)\b"#, "use FrogType")
    }

    func testAnimationsNameAMotionToken() throws {
        let advice = "name a FrogMotion token; docs/design.md says what may move"
        // A bare withAnimation, or a curve written in place: `.animation(.easeOut…)`, `flag ? nil : .spring()`,
        // `Transaction(animation: .linear)`, `Animation.default`.
        try assertNoMatch(#"withAnimation\s*\{|(?<![\w.])\.(easeIn|easeOut|easeInOut|linear|spring|interactiveSpring|interpolatingSpring|smooth|snappy|bouncy|timingCurve)\b|\bAnimation\.\w+"#,
                          advice, except: ["Views/Motion.swift"])
        // AppKit animations: their duration and curve are tokens too.
        try assertNoMatch(#"(?<![\w.])(context|ctx|\$0)\.duration\s*=(?!=)(?!\s*FrogMotion\.)|CAMediaTimingFunction\("#, advice, except: ["Views/Motion.swift"])
        try assertNoMatch(#"\.bounce\b|\bbounce:"#, "nothing in Frog bounces")
    }

    func testTextIsNeverSetInNinePoints() throws {
        try assertNoMatch(#"Text\(.*\.font\(\.system\(size: 9\)\)"#, "use FrogType.caption")
    }

    private func assertNoMatch(_ pattern: String, _ advice: String, except files: Set<String> = [],
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let expression = try NSRegularExpression(pattern: pattern)
        var found: [String] = []
        for (name, source) in try appSources() where !files.contains(name) {
            for (index, text) in source.components(separatedBy: "\n").enumerated() {
                guard !text.trimmingCharacters(in: .whitespaces).hasPrefix("//"),
                      let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let range = Range(match.range, in: text),
                      !allowed.contains("\(name): \(text[range])") else { continue }
                found.append("\(name):\(index + 1): \(text[range])")
            }
        }
        XCTAssertTrue(found.isEmpty, "\(advice):\n" + found.joined(separator: "\n"), file: file, line: line)
    }

    /// Every Swift file of the app target, by its path relative to `native/FrogApp`.
    private func appSources() throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("FrogApp")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "No sources under \(root.path)")
        return try files.sorted { $0.path < $1.path }.map {
            (String($0.path.dropFirst(root.path.count + 1)), try String(contentsOf: $0, encoding: .utf8))
        }
    }
}
