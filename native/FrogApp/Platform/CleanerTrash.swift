import AppKit
import CoreServices
import Darwin
import FrogCore

/// The real Trash. The user's own items move with FileManager; app bundles and administrator items move
/// through Finder, which asks for the password itself. Nothing here deletes an item for good.
struct SystemCleanerTrash: CleanerTrash {
    /// Finder may wait for the administrator password, so a send waits this long.
    private static let finderTimeout: TimeInterval = 300

    func trash(_ url: URL) async throws -> URL {
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        } catch {
            throw Self.trashFailure(error)
        }
        guard let resulting else { throw FrogError.message("Frog could not tell where the item went in the Trash.") }
        return resulting as URL
    }

    func trashWithFinder(_ urls: [URL]) async throws -> [URL?] {
        guard !urls.isEmpty else { return [] }
        return try await Task.detached(priority: .userInitiated) {
            // A failed send throws in NSOSStatusErrorDomain, so -128 (cancelled password prompt) stays the code.
            let reply = try FinderDeleteEvent.make(urls).sendEvent(options: [.waitForReply, .canInteract],
                                                                   timeout: Self.finderTimeout)
            if let code = FinderDeleteEvent.errorCode(in: reply) {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(code))
            }
            return FinderDeleteEvent.trashedURLs(from: reply, count: urls.count)
        }.value
    }

    func finderAutomation() async -> AutomationStatus {
        await Task.detached(priority: .userInitiated) {
            // Never asks: with askUserIfNeeded false this only reads the current choice.
            let target = FinderDeleteEvent.finder
            guard let desc = target.aeDesc else { return .unavailable }
            return FinderDeleteEvent.status(for: AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false))
        }.value
    }

    func putBack(_ trashed: URL, to original: URL) async throws {
        var info = stat()
        if lstat(original.path, &info) == 0 {
            throw FrogError.message("Something else is now at the original place.")
        }
        let parent = original.deletingLastPathComponent()
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw FrogError.message("The original folder is gone.")
        }
        try FileManager.default.moveItem(at: trashed, to: original)
    }

    /// A disk without a Trash makes `trashItem` fail. Frog then stops; it never deletes instead.
    static func trashFailure(_ error: Error) -> Error {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.featureUnsupported.rawValue {
            return FrogError.message("This disk has no Trash. Frog does not delete items for good.")
        }
        return error
    }
}

/// Finder's delete event, built as a descriptor. Paths never become AppleScript source, so a file name
/// cannot change what Finder is asked to do.
enum FinderDeleteEvent {
    static var finder: NSAppleEventDescriptor { NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder") }

    /// Finder's "delete" event (class 'core', id 'delo') with a list of file URL descriptors as the
    /// direct object. Never AppleScript source built from paths.
    static func make(_ urls: [URL]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEDelete),
                                                      targetDescriptor: finder, returnID: AEReturnID(kAutoGenerateReturnID),
                                                      transactionID: AETransactionID(kAnyTransactionID))
        let list = NSAppleEventDescriptor.list()
        for (index, url) in urls.enumerated() {
            list.insert(NSAppleEventDescriptor(fileURL: url), at: index + 1)
        }
        event.setParam(list, forKeyword: keyDirectObject)
        return event
    }

    /// Trash locations from Finder's reply, nil where a reference cannot become a file URL. Finder can
    /// move part of the list and then fail; CleanerRemover checks each item afterwards.
    static func trashedURLs(from reply: NSAppleEventDescriptor, count: Int) -> [URL?] {
        let result = reply.descriptorType == typeAppleEvent ? reply.paramDescriptor(forKeyword: keyDirectObject) : reply
        var urls: [URL?] = []
        if let result {
            if result.descriptorType == typeAEList {
                let items = result.numberOfItems
                if items > 0 {
                    for index in 1...items { urls.append(result.atIndex(index).flatMap(fileURL)) }
                }
            } else {
                urls.append(fileURL(result))
            }
        }
        if urls.count > count { urls.removeLast(urls.count - count) }
        return urls + Array(repeating: nil, count: max(0, count - urls.count))
    }

    /// noErr → .allowed, -1744 (errAEEventWouldRequireUserConsent) → .notDetermined,
    /// -1743 (errAEEventNotPermitted) → .denied, -600 (procNotFound) and others → .unavailable
    static func status(for code: OSStatus) -> AutomationStatus {
        switch code {
        case noErr: .allowed
        case OSStatus(errAEEventWouldRequireUserConsent): .notDetermined
        case OSStatus(errAEEventNotPermitted): .denied
        default: .unavailable
        }
    }

    /// The error number a reply carries when Finder itself failed, for example -128 when the user
    /// cancelled the password prompt.
    static func errorCode(in reply: NSAppleEventDescriptor) -> Int32? {
        guard let number = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, number != 0 else { return nil }
        return number
    }

    /// File references only: an object specifier stays nil, and text is never taken for a path.
    private static let fileReferenceTypes: Set<DescType> = [typeFileURL, typeAlias, typeBookmarkData, typeFSRef]

    private static func fileURL(_ descriptor: NSAppleEventDescriptor) -> URL? {
        fileReferenceTypes.contains(descriptor.descriptorType) ? descriptor.fileURLValue : nil
    }
}
