import AppKit
import XCTest
@testable import FrogApp

/// What an entry puts on a pasteboard, against a pasteboard of its own.
final class ClipboardHistoryEntryTests: XCTestCase {
    func testTextThatLooksLikeAKeyIsMaskedAndStillCopiesWhole() {
        // Built at run time, so that no key-like text sits in the source.
        let key = "sk-" + "ant-" + SyntheticKey.make(40)
        let entry = ClipboardHistoryEntry(text: key)
        XCTAssertEqual(entry.secret, .apiKey)
        XCTAssertTrue(entry.isSensitive)
        XCTAssertEqual(entry.displayPreview(revealed: false), ClipboardHistoryEntry.mask)
        XCTAssertEqual(entry.displayPreview(revealed: true), key)
        XCTAssertEqual(entry.sensitivityLabel, "API key")
        XCTAssertEqual(entry.sensitiveTitle, "Copied API key")
        XCTAssertEqual(entry.contentsOptions, .currentHostOnly)

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(entry.write(to: pasteboard, plainText: false))
        XCTAssertEqual(pasteboard.string(forType: .string), key, "What is pasted is the key itself")
        XCTAssertEqual(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")), true)

        // Text an app marked has no kind of its own; ordinary text is shown as it is.
        let marked = ClipboardHistoryEntry(text: "Synthetic marked text", isSensitive: true)
        XCTAssertNil(marked.secret)
        XCTAssertEqual(marked.sensitivityLabel, "Sensitive")
        XCTAssertEqual(marked.sensitiveTitle, "Sensitive copied text")
        let ordinary = ClipboardHistoryEntry(text: "See you at 10:30")
        XCTAssertFalse(ordinary.isSensitive)
        XCTAssertEqual(ordinary.displayPreview(revealed: false), "See you at 10:30")
    }

    func testSensitiveEntryIsCopiedForThisMacOnly() {
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let rtf = Data("{\\rtf1\\ansi Synthetic secret}".utf8)
        let secret = ClipboardHistoryEntry(text: "Synthetic secret", formatting: [NSPasteboard.PasteboardType.rtf.rawValue: rtf], isSensitive: true)
        let ordinary = ClipboardHistoryEntry(text: "Ordinary text", formatting: [NSPasteboard.PasteboardType.rtf.rawValue: rtf])
        XCTAssertEqual(secret.contentsOptions, .currentHostOnly, "Universal Clipboard must not offer a password to the other devices again")
        XCTAssertEqual(ordinary.contentsOptions, [], "Ordinary text still reaches the other devices")

        // The restriction itself cannot be read back from a pasteboard. What can be seen is
        // that a copy made this way still replaces the contents with one change.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents(); pasteboard.setString("<b>Earlier</b>", forType: .html)
        var count = pasteboard.changeCount
        XCTAssertTrue(secret.write(to: pasteboard, plainText: true))
        XCTAssertEqual(pasteboard.changeCount, count + 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "Synthetic secret")
        XCTAssertEqual(pasteboard.types?.contains(concealed), true)
        XCTAssertNil(pasteboard.string(forType: .html), "What was copied before is gone")
        XCTAssertNil(pasteboard.data(forType: .rtf), "Plain text carries no formatting")

        count = pasteboard.changeCount
        XCTAssertTrue(secret.write(to: pasteboard, plainText: false))
        XCTAssertEqual(pasteboard.changeCount, count + 1)
        XCTAssertEqual(pasteboard.data(forType: .rtf), rtf)
        XCTAssertEqual(pasteboard.types?.contains(concealed), true)

        count = pasteboard.changeCount
        XCTAssertTrue(ordinary.write(to: pasteboard, plainText: false))
        XCTAssertEqual(pasteboard.changeCount, count + 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "Ordinary text")
        XCTAssertEqual(pasteboard.data(forType: .rtf), rtf)
        XCTAssertEqual(pasteboard.types?.contains(concealed), false, "The marker of the copy before does not stay behind")
    }
}
