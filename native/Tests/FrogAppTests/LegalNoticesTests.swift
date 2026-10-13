import AppKit
import SwiftUI
import XCTest
@testable import FrogApp

@MainActor
final class LegalNoticesTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDown() {
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        folders = []
    }
    private func bundle(holding documents: [String: String]) throws -> Bundle {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        for (name, text) in documents { try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return try XCTUnwrap(Bundle(url: folder))
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func testDocumentsComeFromTheBundleThatCarriesThem() throws {
        let bundle = try bundle(holding: ["ThirdPartyNotices.txt": "Apache License"])

        XCTAssertEqual(LegalDocument.thirdPartyNotices.text(in: bundle), "Apache License")
        XCTAssertNil(LegalDocument.license.url(in: bundle), "A build without the file offers no document")
        XCTAssertNil(LegalDocument.license.text(in: bundle))
    }

    func testDocumentViewShowsTheWholeTextReadOnly() throws {
        let notices = (1...4000).map { "Line \($0) of the notices" }.joined(separator: "\n")
        let host = NSHostingView(rootView: LegalDocumentView(document: .thirdPartyNotices,
            bundle: try bundle(holding: ["ThirdPartyNotices.txt": notices])))
        // The window stays off screen; it only gives the hosted AppKit view a place to live.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()

        let text = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
        XCTAssertEqual(text.string, notices)
        XCTAssertFalse(text.isEditable)
        XCTAssertTrue(text.isSelectable)
    }

    /// Regenerating the guide from the wizard template would drop the notice its MIT license requires.
    func testStayAwakeGuideKeepsTheNoticeOfItsWizardLibrary() throws {
        let url = try XCTUnwrap(FrogResources.bundle.url(forResource: "StayAwakeSetup", withExtension: "command"))
        let script = try String(contentsOf: url, encoding: .utf8)
        let library = try XCTUnwrap(script.components(separatedBy: "# STAGES:").first)

        XCTAssertTrue(library.contains("# Copyright (c) 2026 Matt Pocock"))
        XCTAssertTrue(library.contains("# Permission is hereby granted, free of charge, to any person obtaining a copy"))
        XCTAssertTrue(library.contains("# The above copyright notice and this permission notice shall be included in all"))
    }
}
