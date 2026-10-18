import FrogTestSupport
import XCTest

/// Tests keep their defaults out of `~/Library/Preferences`. The scan reads the test sources as text.
final class TemporaryDefaultsTests: XCTestCase {
    func testTheSuiteKeepsItsPlistInItsOwnFolderAndRemovesIt() {
        let suite = TemporaryDefaults()
        suite.defaults.set("value", forKey: "key")
        CFPreferencesAppSynchronize(suite.suiteName as CFString)
        let plist = suite.folder.appendingPathComponent("defaults.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path), "A suite named by a path writes to that path")
        suite.remove()
        XCTAssertNil(suite.defaults.string(forKey: "key"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: suite.folder.path))
    }

    func testTestsMakeDefaultsSuitesOnlyThroughTheHelper() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard let walker = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "No sources under \(tests.path)")
        let named = "UserDefaults" + "(suiteName:" // split so this line is not a match itself
        var found: [String] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            let name = String(file.path.dropFirst(tests.path.count + 1))
            guard !name.hasPrefix("FrogTestSupport/") else { continue }
            for (index, text) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated()
            where text.contains(named) && !text.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                found.append("\(name):\(index + 1)")
            }
        }
        XCTAssertTrue(found.isEmpty, "A named suite leaves a plist in ~/Library/Preferences that no cleanup removes; "
                      + "use temporaryDefaults() from FrogTestSupport:\n" + found.joined(separator: "\n"))
    }
}
