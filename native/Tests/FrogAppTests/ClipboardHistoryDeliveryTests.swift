import AppKit
import XCTest
@testable import FrogApp

/// What happens after an item is chosen in the panel, against a pasteboard of its own.
/// The panel is never shown: the delivery starts as the panel starts it.
@MainActor
final class ClipboardHistoryDeliveryTests: XCTestCase {
    func testPastedItemIsNotReadBackAsANewCopy() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let history = ClipboardHistoryStore(pasteboard: pasteboard, gate: ClipboardHistoryCaptureGate())
        history.configure(enabled: true, automaticallyPoll: false)
        defer { history.configure(enabled: false) }
        let target = DeliveryTarget()
        let controller = ClipboardHistoryController(pasteboard: pasteboard, history: history, captureTarget: { target },
            waitForRelease: {}, activationNotifications: NotificationCenter())
        defer { controller.stop() }
        let item = NSPasteboardItem()
        item.setString("Formatted fixture", forType: .string)
        item.setData(Data("<b>Formatted fixture</b>".utf8), forType: .html)
        pasteboard.clearContents(); pasteboard.writeObjects([item]); await history.poll()
        let formatted = try XCTUnwrap(history.entries.first)
        history.recordCopiedText("Newer fixture")
        let newer = try XCTUnwrap(history.entries.first)

        for plain in [true, false] {
            controller.deliver(formatted, plainText: plain, to: target)
            await controller.waitForDelivery()
            XCTAssertEqual(pasteboard.string(forType: .string), "Formatted fixture")
            XCTAssertEqual(pasteboard.data(forType: .html) == nil, plain)
            await history.poll()
            XCTAssertEqual(history.entries.map(\.id), [formatted.id, newer.id],
                plain ? "Pasting as plain text adds no second row for the same text" : "The pasted item keeps its row")
            XCTAssertEqual(history.entries.first?.formatting, formatted.formatting, "The row keeps its formatting for the next paste")
        }
        XCTAssertEqual(target.requests, 2)
    }

    func testResultCopiedWhileAPasteWaitsDoesNotCancelIt() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let history = ClipboardHistoryStore(pasteboard: pasteboard, gate: ClipboardHistoryCaptureGate())
        history.configure(enabled: true, automaticallyPoll: false)
        defer { history.configure(enabled: false) }
        history.recordCopiedText("Chosen fixture")
        let chosen = try XCTUnwrap(history.entries.first)
        let target = DeliveryTarget()
        var release: CheckedContinuation<Void, Never>?
        let controller = ClipboardHistoryController(pasteboard: pasteboard, history: history, captureTarget: { target },
            waitForRelease: { await withCheckedContinuation { release = $0 } }, activationNotifications: NotificationCenter())
        defer { controller.stop() }

        for removed in [false, true] {
            release = nil
            controller.deliver(chosen, plainText: false, to: target)
            for _ in 0..<100 where release == nil { await Task.yield() }
            let waiting = try XCTUnwrap(release, "The paste waits until the shortcut is released")
            // A dictation or writing result lands on the clipboard in the meantime.
            pasteboard.clearContents(); pasteboard.setString("Dictated fixture", forType: .string)
            history.recordCopiedText("Dictated fixture")
            if removed { history.delete(id: chosen.id) }
            waiting.resume()
            await controller.waitForDelivery()
            if removed {
                XCTAssertEqual(target.requests, 1, "A deleted item is still never pasted")
                XCTAssertEqual(pasteboard.string(forType: .string), "Dictated fixture")
            } else {
                XCTAssertEqual(target.requests, 1, "The chosen item is pasted although another result arrived")
                XCTAssertEqual(pasteboard.string(forType: .string), "Chosen fixture")
            }
        }
    }
}

@MainActor private final class DeliveryTarget: ClipboardHistoryPasteTarget {
    var requests = 0
    func paste() throws { requests += 1 }
}
