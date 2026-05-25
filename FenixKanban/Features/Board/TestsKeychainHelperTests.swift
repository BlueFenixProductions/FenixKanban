import Testing
import Foundation

@Suite("Keychain Helper Tests")
struct KeychainHelperTests {
    
    // Use unique test keys to avoid conflicts
    let testKey = "com.test.fenixkanban.keychainTest.\(UUID().uuidString)"
    
    init() {
        // Clean up any existing test data
        KeychainHelper.delete(key: testKey)
    }
    
    deinit {
        // Clean up after tests
        KeychainHelper.delete(key: testKey)
    }
    
    @Test("Save and load string from keychain")
    func saveAndLoad() async throws {
        let testValue = "test-user-id-123"
        
        // Save
        let saveResult = KeychainHelper.save(key: testKey, value: testValue)
        #expect(saveResult == true, "Save should succeed")
        
        // Load
        let loadedValue = KeychainHelper.load(key: testKey)
        #expect(loadedValue == testValue, "Loaded value should match saved value")
    }
    
    @Test("Load non-existent key returns nil")
    func loadNonExistent() async throws {
        let nonExistentKey = "com.test.nonexistent.\(UUID().uuidString)"
        let value = KeychainHelper.load(key: nonExistentKey)
        #expect(value == nil, "Loading non-existent key should return nil")
    }
    
    @Test("Delete removes value from keychain")
    func deleteValue() async throws {
        let testValue = "temporary-value"
        
        // Save
        _ = KeychainHelper.save(key: testKey, value: testValue)
        
        // Verify it exists
        let beforeDelete = KeychainHelper.load(key: testKey)
        #expect(beforeDelete == testValue)
        
        // Delete
        let deleteResult = KeychainHelper.delete(key: testKey)
        #expect(deleteResult == true, "Delete should succeed")
        
        // Verify it's gone
        let afterDelete = KeychainHelper.load(key: testKey)
        #expect(afterDelete == nil, "Value should be nil after delete")
    }
    
    @Test("Update existing value")
    func updateValue() async throws {
        let firstValue = "first-value"
        let secondValue = "second-value"
        
        // Save first value
        _ = KeychainHelper.save(key: testKey, value: firstValue)
        let loaded1 = KeychainHelper.load(key: testKey)
        #expect(loaded1 == firstValue)
        
        // Update to second value
        _ = KeychainHelper.save(key: testKey, value: secondValue)
        let loaded2 = KeychainHelper.load(key: testKey)
        #expect(loaded2 == secondValue, "Updated value should replace old value")
    }
    
    @Test("Save empty string")
    func saveEmptyString() async throws {
        let emptyValue = ""
        
        let saveResult = KeychainHelper.save(key: testKey, value: emptyValue)
        #expect(saveResult == true, "Saving empty string should succeed")
        
        let loaded = KeychainHelper.load(key: testKey)
        #expect(loaded == emptyValue, "Empty string should be retrievable")
    }
    
    @Test("Save string with special characters")
    func saveSpecialCharacters() async throws {
        let specialValue = "user@email.com|123!@#$%^&*()"
        
        let saveResult = KeychainHelper.save(key: testKey, value: specialValue)
        #expect(saveResult == true)
        
        let loaded = KeychainHelper.load(key: testKey)
        #expect(loaded == specialValue, "Special characters should be preserved")
    }
    
    @Test("Save Unicode string")
    func saveUnicode() async throws {
        let unicodeValue = "用户ID-👤-테스트"
        
        let saveResult = KeychainHelper.save(key: testKey, value: unicodeValue)
        #expect(saveResult == true)
        
        let loaded = KeychainHelper.load(key: testKey)
        #expect(loaded == unicodeValue, "Unicode characters should be preserved")
    }
}
