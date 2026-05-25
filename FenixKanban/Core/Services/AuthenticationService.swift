import AuthenticationServices
import Foundation

protocol AuthenticationServiceProtocol: ObservableObject {
    var isAuthenticated: Bool { get }
    var userID: String? { get }
    func checkCredentialState() async -> Bool
    func signOut()
}

final class AuthenticationService: ObservableObject, AuthenticationServiceProtocol {
    @Published var isAuthenticated: Bool = false
    @Published var userID: String? = nil

    private let userIDKey = "fenixkanban_apple_user_id"

    init() {
        self.userID = KeychainHelper.load(key: userIDKey)
        self.isAuthenticated = userID != nil

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(credentialRevoked),
            name: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
            object: nil
        )
    }

    func checkCredentialState() async -> Bool {
        guard let userID = userID else { return false }

        do {
            let state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: userID)
            let valid = state == .authorized
            await MainActor.run {
                self.isAuthenticated = valid
                if !valid {
                    self.clearCredentials()
                }
            }
            return valid
        } catch {
            await MainActor.run {
                self.isAuthenticated = false
            }
            return false
        }
    }

    func handleSignInResult(userID: String) {
        KeychainHelper.save(key: userIDKey, value: userID)
        self.userID = userID
        self.isAuthenticated = true
    }

    func signOut() {
        clearCredentials()
    }

    func skipSignIn() {
        // Local-only mode — no credentials stored
        isAuthenticated = false
    }

    @objc private func credentialRevoked() {
        DispatchQueue.main.async {
            self.clearCredentials()
        }
    }

    private func clearCredentials() {
        KeychainHelper.delete(key: userIDKey)
        userID = nil
        isAuthenticated = false
    }
}

// MARK: - Keychain Helper

enum KeychainHelper {
    /// Saves a string value to the keychain
    /// - Parameters:
    ///   - key: The key to store the value under
    ///   - value: The string value to store
    /// - Returns: True if the save was successful, false otherwise
    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else {
            return false
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        
        // Delete any existing item first
        SecItemDelete(query as CFDictionary)
        
        // Add the new item
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Loads a string value from the keychain
    /// - Parameter key: The key to retrieve the value for
    /// - Returns: The stored string value, or nil if not found or if an error occurred
    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return string
    }

    /// Deletes a value from the keychain
    /// - Parameter key: The key to delete
    /// - Returns: True if the deletion was successful or if the item didn't exist, false on error
    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        // errSecItemNotFound is also considered success (item didn't exist)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
