import Testing
import Foundation
@testable import FenixKanban

@Suite("Keychain Helper")
final class KeychainHelperTests {
    // Unique per-instance key so concurrent or repeated runs don't collide.
    // Final class instead of struct so deinit can run the post-test cleanup.
    let testKey: String

    init() {
        testKey = "com.test.fenixkanban.keychainTest.\(UUID().uuidString)"
        KeychainHelper.delete(key: testKey)
    }

    deinit {
        KeychainHelper.delete(key: testKey)
    }

    @Test func saveAndLoadString() {
        let value = "test-user-id-123"
        #expect(KeychainHelper.save(key: testKey, value: value) == true)
        #expect(KeychainHelper.load(key: testKey) == value)
    }

    @Test func loadNonExistentKeyReturnsNil() {
        let bogus = "com.test.nonexistent.\(UUID().uuidString)"
        #expect(KeychainHelper.load(key: bogus) == nil)
    }

    @Test func deleteRemovesValue() {
        KeychainHelper.save(key: testKey, value: "temporary")
        #expect(KeychainHelper.load(key: testKey) == "temporary")
        #expect(KeychainHelper.delete(key: testKey) == true)
        #expect(KeychainHelper.load(key: testKey) == nil)
    }

    @Test func deleteNonExistentKeyIsSuccess() {
        // errSecItemNotFound is treated as success — deleting "nothing" is a no-op.
        let bogus = "com.test.nonexistent.\(UUID().uuidString)"
        #expect(KeychainHelper.delete(key: bogus) == true)
    }

    @Test func updateExistingValue() {
        KeychainHelper.save(key: testKey, value: "first")
        KeychainHelper.save(key: testKey, value: "second")
        #expect(KeychainHelper.load(key: testKey) == "second")
    }

    @Test func saveEmptyString() {
        #expect(KeychainHelper.save(key: testKey, value: "") == true)
        #expect(KeychainHelper.load(key: testKey) == "")
    }

    @Test func saveSpecialCharacters() {
        let value = "user@email.com|123!@#$%^&*()"
        #expect(KeychainHelper.save(key: testKey, value: value) == true)
        #expect(KeychainHelper.load(key: testKey) == value)
    }

    @Test func saveUnicode() {
        let value = "用户ID-👤-테스트"
        #expect(KeychainHelper.save(key: testKey, value: value) == true)
        #expect(KeychainHelper.load(key: testKey) == value)
    }
}
