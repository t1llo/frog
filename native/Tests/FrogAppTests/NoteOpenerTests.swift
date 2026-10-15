import XCTest
@testable import FrogApp

final class NoteOpenerTests: XCTestCase {
    func testObsidianOpensANoteOnlyInAVaultWhenItIsInstalled() {
        let file = URL(fileURLWithPath: "/Volumes/Data/Notes Vault/Daily/2026-10-14.md")
        let vault = URL(fileURLWithPath: "/Volumes/Data/Notes Vault", isDirectory: true)
        XCTAssertEqual(NoteOpenTarget.decide(file: file, vaultRoot: vault, obsidianAvailable: true).absoluteString,
                       "obsidian://open?path=%2FVolumes%2FData%2FNotes%20Vault%2FDaily%2F2026-10-14.md")
        XCTAssertEqual(NoteOpenTarget.decide(file: file, vaultRoot: vault, obsidianAvailable: false), file)
        XCTAssertEqual(NoteOpenTarget.decide(file: file, vaultRoot: nil, obsidianAvailable: true), file)
        XCTAssertEqual(NoteOpenTarget.decide(file: file, vaultRoot: nil, obsidianAvailable: false), file)
        let reserved = URL(fileURLWithPath: "/Vault/Q&A #1?.md")
        XCTAssertEqual(NoteOpenTarget.decide(file: reserved, vaultRoot: vault, obsidianAvailable: true).absoluteString,
                       "obsidian://open?path=%2FVault%2FQ%26A%20%231%3F.md")
    }

    func testTheVaultIsTheNearestFolderWithObsidianSettingsBelowTheHomeFolder() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("FrogVault-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        let vault = home.appendingPathComponent("Vault", isDirectory: true)
        let daily = vault.appendingPathComponent("Daily", isDirectory: true)
        try FileManager.default.createDirectory(at: daily, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        // A vault above the home folder is never reached.
        try FileManager.default.createDirectory(at: base.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        let plain = home.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        XCTAssertEqual(NoteOpenTarget.vaultRoot(for: daily.appendingPathComponent("2026-10-14.md"), home: home)?.path, vault.path)
        XCTAssertEqual(NoteOpenTarget.vaultRoot(for: vault.appendingPathComponent("river bank.md"), home: home)?.path, vault.path)
        XCTAssertNil(NoteOpenTarget.vaultRoot(for: plain.appendingPathComponent("river bank.md"), home: home))
    }
}
