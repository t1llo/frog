import Foundation
@testable import FrogCore

/// A fake home and system root under the temporary folder, with every leftover location and both
/// Applications folders. The roots keep the temporary folder's `/var` spelling, so every test also
/// exercises `CleanerRoots.resolved(_:)`.
struct CleanerFixture {
    let root: URL, home: URL, system: URL
    var roots: CleanerRoots { CleanerRoots(home: home, system: system) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("frog-cleaner-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        system = root.appendingPathComponent("system", isDirectory: true)
        let manager = FileManager.default
        for location in LeftoverLocation.allCases {
            for domain in location.domains {
                let library = domain == .user ? home : system
                try manager.createDirectory(at: library.appendingPathComponent("Library/" + location.relativePath, isDirectory: true),
                                            withIntermediateDirectories: true)
            }
        }
        for folder in [system, home] {
            try manager.createDirectory(at: folder.appendingPathComponent("Applications", isDirectory: true),
                                        withIntermediateDirectories: true)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// A bundle with an Info.plist and an empty executable, in the system Applications folder unless `folder` is
    /// given. `nested` files are relative to `Contents`, for example `PlugIns/Share.appex`.
    @discardableResult
    func app(_ name: String, bundleID: String, in folder: URL? = nil, version: String = "1.0",
             executable: String? = nil, bundleName: String? = nil, nested: [(file: String, bundleID: String)] = [],
             appStore: Bool = false, systemExtension: Bool = false, loginItem: Bool = false) throws -> URL {
        let bundle = (folder ?? system.appendingPathComponent("Applications", isDirectory: true))
            .appendingPathComponent(name + ".app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let executable = executable ?? name
        try writePlist(["CFBundleIdentifier": bundleID, "CFBundleName": bundleName ?? name,
                        "CFBundleShortVersionString": version, "CFBundleExecutable": executable],
                       to: contents.appendingPathComponent("Info.plist"))
        try writeFile(contents.appendingPathComponent("MacOS/" + executable), bytes: 0)
        for (file, id) in nested {
            try writePlist(["CFBundleIdentifier": id], to: contents.appendingPathComponent(file + "/Contents/Info.plist"))
        }
        if appStore { try writeFile(contents.appendingPathComponent("_MASReceipt/receipt"), bytes: 1) }
        if systemExtension {
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Library/SystemExtensions/Driver.systemextension"),
                                                    withIntermediateDirectories: true)
        }
        if loginItem {
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Library/LoginItems/\(name) Helper.app"),
                                                    withIntermediateDirectories: true)
        }
        return bundle
    }

    /// A folder (holding one file of `bytes` when it is not zero) or a file of `bytes` in a leftover location.
    @discardableResult
    func item(_ location: LeftoverLocation, _ name: String, domain: CleanerDomain = .user,
              directory: Bool = true, bytes: Int = 0) throws -> URL {
        let library = (domain == .user ? home : system).appendingPathComponent("Library/" + location.relativePath, isDirectory: true)
        let url = library.appendingPathComponent(name, isDirectory: directory)
        if directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if bytes > 0 { try writeFile(url.appendingPathComponent("data"), bytes: bytes) }
        } else {
            try writeFile(url, bytes: bytes)
        }
        return url
    }

    /// A launch job property list named `<label>.plist`.
    @discardableResult
    func launchPlist(_ location: LeftoverLocation, label: String, program: String? = nil,
                     arguments: [String]? = nil, associated: [String]? = nil, domain: CleanerDomain = .user) throws -> URL {
        let library = (domain == .user ? home : system).appendingPathComponent("Library/" + location.relativePath, isDirectory: true)
        var plist: [String: Any] = ["Label": label]
        if let program { plist["Program"] = program }
        if let arguments { plist["ProgramArguments"] = arguments }
        if let associated { plist["AssociatedBundleIdentifiers"] = associated }
        let url = library.appendingPathComponent(label + ".plist")
        try writePlist(plist, to: url)
        return url
    }

    private func writePlist(_ plist: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func writeFile(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }
}
