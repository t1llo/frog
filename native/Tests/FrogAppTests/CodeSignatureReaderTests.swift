import FrogCore
import XCTest
@testable import FrogApp

/// Signatures are read from a fixture bundle in a temporary folder and, read-only, from two system files.
final class CodeSignatureReaderTests: XCTestCase {
    func testAnUnsignedFixtureBundleHasNoSignature() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Cleaner Sample.app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.frogcleanersample", "CFBundleName": "Cleaner Sample",
                                   "CFBundleExecutable": "Cleaner Sample"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        // A script, so the fixture is a bundle with an executable but no signature at all.
        let executable = contents.appendingPathComponent("MacOS/Cleaner Sample")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        XCTAssertNil(SecurityCodeSignatureReader().signature(of: bundle))
        XCTAssertNil(SecurityCodeSignatureReader().signature(of: root.appendingPathComponent("Missing.app")))
    }

    func testASystemAppIsReadWithoutCrashing() {
        XCTAssertNotNil(SecurityCodeSignatureReader().signature(of: URL(fileURLWithPath: "/System/Applications/Calculator.app")))
    }

    func testASingleExecutableIsRead() {
        XCTAssertNotNil(SecurityCodeSignatureReader().signature(of: URL(fileURLWithPath: "/usr/bin/true")))
    }

    func testAppGroupsAreBounded() {
        let many = (0..<40).map { "group.com.example.\($0)" }
        XCTAssertEqual(SecurityCodeSignatureReader.appGroups(many).count, 32)
        XCTAssertEqual(SecurityCodeSignatureReader.appGroups(["group.a", String(repeating: "x", count: 129), 5, ""]), ["group.a"])
        XCTAssertEqual(SecurityCodeSignatureReader.appGroups("group.a"), [])
        XCTAssertEqual(SecurityCodeSignatureReader.appGroups(nil), [])
    }
}
