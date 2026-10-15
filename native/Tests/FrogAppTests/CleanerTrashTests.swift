import AppKit
import CoreServices
import FrogCore
import XCTest
@testable import FrogApp

/// The Finder event and its reply are built and read here by hand; nothing is sent to Finder and
/// nothing moves to the real Trash.
final class CleanerTrashTests: XCTestCase {
    func testFinderDeleteEventCarriesEveryFileAsADescriptorNotSource() throws {
        let urls = [URL(fileURLWithPath: "/Applications/Cleaner Sample.app"),
                    URL(fileURLWithPath: "/Library/Application Support/Name with \"quotes\" and ; end tell")]
        let event = FinderDeleteEvent.make(urls)

        XCTAssertEqual(event.eventClass, AEEventClass(kAECoreSuite))
        XCTAssertEqual(event.eventID, AEEventID(kAEDelete))
        let list = try XCTUnwrap(event.paramDescriptor(forKeyword: keyDirectObject))
        XCTAssertEqual(list.descriptorType, typeAEList)
        XCTAssertEqual(list.numberOfItems, 2)
        for (index, url) in urls.enumerated() {
            let item = try XCTUnwrap(list.atIndex(index + 1))
            XCTAssertEqual(item.descriptorType, typeFileURL)
            XCTAssertEqual(item.fileURLValue?.path, url.path)
        }
        let target = try XCTUnwrap(event.attributeDescriptor(forKeyword: keyAddressAttr))
        XCTAssertEqual(target.descriptorType, typeApplicationBundleID)
        XCTAssertEqual(String(decoding: target.data, as: UTF8.self), "com.apple.finder")
    }

    func testAutomationStatusCodesMap() {
        XCTAssertEqual(FinderDeleteEvent.status(for: noErr), .allowed)
        XCTAssertEqual(FinderDeleteEvent.status(for: -1744), .notDetermined)
        XCTAssertEqual(FinderDeleteEvent.status(for: -1743), .denied)
        XCTAssertEqual(FinderDeleteEvent.status(for: -600), .unavailable)
        XCTAssertEqual(FinderDeleteEvent.status(for: -50), .unavailable)
    }

    func testTrashedURLsAreReadFromAFinderStyleReply() throws {
        let trash = URL(fileURLWithPath: "/private/tmp/Frog test Trash", isDirectory: true)
        let first = trash.appendingPathComponent("Cleaner Sample.app")
        let third = trash.appendingPathComponent("Cleaner Sample Helper")
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(fileURL: first), at: 1)
        // An object specifier, as Finder returns for some items, cannot become a file URL; nor can text.
        let specifier = NSAppleEventDescriptor.record()
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(cItem)), forKeyword: AEKeyword(keyAEDesiredClass))
        specifier.setDescriptor(NSAppleEventDescriptor(string: "Cleaner Sample Data"), forKeyword: AEKeyword(keyAEKeyData))
        list.insert(try XCTUnwrap(specifier.coerce(toDescriptorType: typeObjectSpecifier)), at: 2)
        list.insert(NSAppleEventDescriptor(fileURL: third), at: 3)
        let reply = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEAnswer),
                                                      targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                                      transactionID: AETransactionID(kAnyTransactionID))
        reply.setParam(list, forKeyword: keyDirectObject)

        XCTAssertEqual(FinderDeleteEvent.trashedURLs(from: reply, count: 3).map { $0?.path },
                       [first.path, nil, third.path])
        // Fewer answers than items are padded, so each item keeps its index.
        XCTAssertEqual(FinderDeleteEvent.trashedURLs(from: reply, count: 4).count, 4)
        let text = NSAppleEventDescriptor.list()
        text.insert(NSAppleEventDescriptor(string: "/private/tmp/elsewhere"), at: 1)
        XCTAssertEqual(FinderDeleteEvent.trashedURLs(from: text, count: 1), [nil])
        // One moved item comes back as a single descriptor, not a list.
        let single = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEAnswer),
                                                       targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                                       transactionID: AETransactionID(kAnyTransactionID))
        single.setParam(NSAppleEventDescriptor(fileURL: first), forKeyword: keyDirectObject)
        XCTAssertEqual(FinderDeleteEvent.trashedURLs(from: single, count: 1).map { $0?.path }, [first.path])
        XCTAssertNil(FinderDeleteEvent.errorCode(in: single))
        single.setParam(NSAppleEventDescriptor(int32: -128), forKeyword: keyErrorNumber)
        XCTAssertEqual(FinderDeleteEvent.errorCode(in: single), -128)
    }

    func testADiskWithoutATrashStopsInsteadOfDeleting() {
        let unsupported = NSError(domain: NSCocoaErrorDomain, code: CocoaError.featureUnsupported.rawValue)
        XCTAssertEqual(SystemCleanerTrash.trashFailure(unsupported) as? FrogError,
                       .message("This disk has no Trash. Frog does not delete items for good."))
        let denied = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue)
        XCTAssertEqual(SystemCleanerTrash.trashFailure(denied) as NSError, denied)
    }

    func testPutBackRefusesATakenPlaceAndAMissingFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trashed = root.appendingPathComponent("trashed")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: trashed)
        let taken = root.appendingPathComponent("folder/item")
        try Data("b".utf8).write(to: taken)
        let trash = SystemCleanerTrash()

        do { try await trash.putBack(trashed, to: taken); XCTFail("A taken place must be refused") }
        catch { XCTAssertEqual(error as? FrogError, .message("Something else is now at the original place.")) }
        do { try await trash.putBack(trashed, to: root.appendingPathComponent("gone/item")); XCTFail("A missing folder must be refused") }
        catch { XCTAssertEqual(error as? FrogError, .message("The original folder is gone.")) }

        let free = root.appendingPathComponent("folder/back")
        try await trash.putBack(trashed, to: free)
        XCTAssertTrue(FileManager.default.fileExists(atPath: free.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path))
    }
}
