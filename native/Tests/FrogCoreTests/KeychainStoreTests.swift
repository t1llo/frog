import Security
import XCTest
@testable import FrogCore

/// These tests never touch a keychain: they check what a failed Keychain call tells the person.
final class KeychainStoreTests: XCTestCase {
    func testOnlyALockedKeychainAsksToUnlockIt() {
        XCTAssertTrue(KeychainStore.failure(errSecInteractionNotAllowed).localizedDescription.contains("Unlock"))
        for status in [errSecUserCanceled, errSecAuthFailed, errSecNoSuchKeychain, errSecNoDefaultKeychain, errSecNotAvailable, OSStatus(-12_345)] {
            XCTAssertFalse(KeychainStore.failure(status).localizedDescription.contains("Unlock"), "\(status)")
        }
    }

    func testEachKeychainFailureSaysWhatToDo() {
        XCTAssertEqual(KeychainStore.Failure(errSecInteractionNotAllowed), .locked)
        XCTAssertEqual(KeychainStore.Failure(errSecUserCanceled), .cancelled)
        XCTAssertEqual(KeychainStore.Failure(errSecAuthFailed), .denied)
        XCTAssertEqual(KeychainStore.Failure(errSecNoSuchKeychain), .unavailable)
        XCTAssertEqual(KeychainStore.Failure(errSecNoDefaultKeychain), .unavailable)
        XCTAssertEqual(KeychainStore.Failure(errSecNotAvailable), .unavailable)
        XCTAssertEqual(KeychainStore.Failure(-12_345), .other(-12_345))
        let messages = [errSecInteractionNotAllowed, errSecUserCanceled, errSecAuthFailed, errSecNotAvailable, -12_345]
            .map { KeychainStore.failure($0).localizedDescription }
        XCTAssertEqual(Set(messages).count, messages.count, "\(messages)")
        // An unexpected status is kept for a bug report; the expected ones need no number.
        XCTAssertTrue(messages[4].contains("(-12345)"), messages[4])
        XCTAssertFalse(messages[1].contains("("), messages[1])
    }
}
