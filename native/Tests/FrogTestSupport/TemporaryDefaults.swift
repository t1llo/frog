import Foundation
import XCTest

/// A defaults suite of its own in a temporary folder, for one test.
///
/// A suite with a plain name such as `frog-tests-…` lives in `~/Library/Preferences`, and nothing
/// removes it there: `removePersistentDomain(forName:)` and `defaults delete` leave an empty plist,
/// and cfprefsd writes a deleted plist back from its cache. A suite named by an absolute path keeps
/// its plist at that path instead, so deleting the folder removes it for good.
public struct TemporaryDefaults {
    public let folder: URL
    public let suiteName: String
    public let defaults: UserDefaults

    public init() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("frog-test-defaults-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suiteName = folder.appendingPathComponent("defaults").path
        defaults = UserDefaults(suiteName: suiteName)!
    }

    /// Forgets every value and deletes the folder with the plist.
    public func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }
}

public extension XCTestCase {
    /// Empty defaults for this test, removed with everything written to them when the test ends.
    /// Works from `setUp` too.
    func temporaryDefaults() -> UserDefaults {
        let suite = TemporaryDefaults()
        addTeardownBlock { suite.remove() }
        return suite.defaults
    }
}
