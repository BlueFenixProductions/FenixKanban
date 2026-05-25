import Testing
import AuthenticationServices
@testable import FenixKanban

@Suite("Authentication Service Tests")
@MainActor
struct AuthenticationServiceTests {
    
    // Use unique test key to avoid conflicts with real app data
    let testUserIDKey = "test_fenixkanban_apple_user_id_\(UUID().uuidString)"
    
    init() {
        // Clean up any test data
        KeychainHelper.delete(key: testUserIDKey)
    }
    
    deinit {
        // Clean up after tests
        KeychainHelper.delete(key: testUserIDKey)
    }
    
    @Test("Initial state when no user ID stored")
    func initialStateNoUser() async throws {
        // Clean keychain first
        KeychainHelper.delete(key: testUserIDKey)
        
        // Create service (it reads from keychain in init)
        let service = AuthenticationService()
        
        #expect(service.isAuthenticated == false)
        #expect(service.userID == nil)
    }
    
    @Test("Sign in saves user ID and updates state")
    func signInSavesUserID() async throws {
        let service = AuthenticationService()
        let testUserID = "test.user.001.\(UUID().uuidString)"
        
        service.handleSignInResult(userID: testUserID)
        
        #expect(service.isAuthenticated == true)
        #expect(service.userID == testUserID)
        
        // Verify it was saved to keychain (using the service's key)
        // Note: We can't directly access the private key, so we create a new service
        // This is a limitation - ideally the key would be injectable
    }
    
    @Test("Sign out clears credentials")
    func signOutClearsCredentials() async throws {
        let service = AuthenticationService()
        let testUserID = "test.user.002.\(UUID().uuidString)"
        
        // Sign in first
        service.handleSignInResult(userID: testUserID)
        #expect(service.isAuthenticated == true)
        
        // Sign out
        service.signOut()
        
        #expect(service.isAuthenticated == false)
        #expect(service.userID == nil)
    }
    
    @Test("Skip sign in maintains unauthenticated state")
    func skipSignIn() async throws {
        let service = AuthenticationService()
        
        service.skipSignIn()
        
        #expect(service.isAuthenticated == false)
        #expect(service.userID == nil)
    }
    
    @Test("Check credential state returns false for nil userID")
    func checkCredentialStateNilUser() async throws {
        let service = AuthenticationService()
        
        let isValid = await service.checkCredentialState()
        
        #expect(isValid == false)
        #expect(service.isAuthenticated == false)
    }
}

// MARK: - Integration Test Notes
/*
 Full credential state checking requires Sign in with Apple to be configured
 and can't be easily mocked without dependency injection.
 
 Refactoring recommendations:
 1. Make userIDKey injectable for testing
 2. Extract ASAuthorizationAppleIDProvider into a protocol
 3. Add mock provider for testing different credential states
 4. Test credential revocation notification handling
 
 Example:
 ```swift
 protocol AppleIDProviderProtocol {
     func credentialState(forUserID: String) async throws -> ASAuthorizationAppleIDProvider.CredentialState
 }
 ```
 */
