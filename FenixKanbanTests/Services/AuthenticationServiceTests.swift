import Testing
import AuthenticationServices
@testable import FenixKanban

// .serialized because every test in this suite reads/writes the same
// hardcoded keychain key used by AuthenticationService. Parallel execution
// (the Swift Testing default) would race on that shared global state.
@Suite("Authentication Service", .serialized)
@MainActor
final class AuthenticationServiceTests {
    // AuthenticationService stores under a hardcoded internal key. Each test
    // instance wipes it in init/deinit so runs start from a known state.
    // Note: this clears any signed-in user on the simulator/test host.
    private static let serviceKey = "fenixkanban_apple_user_id"

    init() {
        KeychainHelper.delete(key: Self.serviceKey)
    }

    deinit {
        KeychainHelper.delete(key: Self.serviceKey)
    }

    @Test func initialStateWithNoStoredUser() {
        let service = AuthenticationService()
        #expect(service.isAuthenticated == false)
        #expect(service.userID == nil)
    }

    @Test func handleSignInPersistsUserID() {
        let service = AuthenticationService()
        let userID = "test.user.\(UUID().uuidString)"

        service.handleSignInResult(userID: userID)

        #expect(service.isAuthenticated == true)
        #expect(service.userID == userID)

        // A fresh instance must read the same ID back from the keychain.
        let reloaded = AuthenticationService()
        #expect(reloaded.isAuthenticated == true)
        #expect(reloaded.userID == userID)
    }

    @Test func signOutClearsCredentials() {
        let service = AuthenticationService()
        service.handleSignInResult(userID: "test.\(UUID().uuidString)")
        #expect(service.isAuthenticated == true)

        service.signOut()

        #expect(service.isAuthenticated == false)
        #expect(service.userID == nil)

        // The keychain entry must also be gone — a new instance stays signed out.
        let reloaded = AuthenticationService()
        #expect(reloaded.isAuthenticated == false)
        #expect(reloaded.userID == nil)
    }

    @Test func skipSignInLeavesUnauthenticated() {
        let service = AuthenticationService()
        service.skipSignIn()
        #expect(service.isAuthenticated == false)
        #expect(service.userID == nil)
    }

    @Test func checkCredentialStateReturnsFalseWithoutUserID() async {
        let service = AuthenticationService()
        let isValid = await service.checkCredentialState()
        #expect(isValid == false)
        #expect(service.isAuthenticated == false)
    }
}
