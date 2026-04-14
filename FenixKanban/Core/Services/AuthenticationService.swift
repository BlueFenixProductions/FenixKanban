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
    static func save(key: String, value: String) {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
