import Foundation

/// Persists Fizzy credentials (Bearer token, account slug, base URL) in the
/// Keychain via the project's `KeychainHelper`.
///
/// Production uses the default `keyPrefix` of `"fizzy"`, producing the three
/// keys named in the spec: `fizzy.accessToken`, `fizzy.accountSlug`,
/// `fizzy.baseURL`. Tests pass a unique prefix so concurrent test runs and
/// the user's real credentials on the simulator stay isolated.
///
/// Phase 2 of the Fizzy integration; Phase 5's `FizzyAuthView` writes via the
/// `set*` methods, and Phase 4's sync engine + Phase 5's `FizzySyncProvider`
/// read via the properties.
final class FizzyAuthState {

    /// Default Fizzy server. User-overridable via `setBaseURL` so a developer
    /// can repoint at a localhost Fizzy instance without rebuilding the app.
    static let defaultBaseURL = URL(string: "https://fizzy.bluefenix.net")!

    let keyPrefix: String

    init(keyPrefix: String = "fizzy") {
        self.keyPrefix = keyPrefix
    }

    private var tokenKey: String  { "\(keyPrefix).accessToken" }
    private var slugKey: String   { "\(keyPrefix).accountSlug" }
    private var urlKey: String    { "\(keyPrefix).baseURL" }

    /// Bearer personal access token (e.g. `claude-dev`). `nil` when not configured.
    var accessToken: String? {
        KeychainHelper.load(key: tokenKey)
    }

    /// Account-slug segment (e.g. `"897362094"`) interpolated into URLs by
    /// `FizzyClient`. `nil` when not configured.
    var accountSlug: String? {
        KeychainHelper.load(key: slugKey)
    }

    /// Effective base URL. Returns the user-overridden value if set, else
    /// `defaultBaseURL`.
    var baseURL: URL {
        guard let string = KeychainHelper.load(key: urlKey),
              let url = URL(string: string)
        else { return Self.defaultBaseURL }
        return url
    }

    /// `true` when both `accessToken` and `accountSlug` are present.
    var isConfigured: Bool {
        accessToken != nil && accountSlug != nil
    }

    /// Sets or clears the access token. `nil` removes the Keychain entry.
    func setAccessToken(_ value: String?) {
        write(value, key: tokenKey)
    }

    /// Sets or clears the account slug.
    func setAccountSlug(_ value: String?) {
        write(value, key: slugKey)
    }

    /// Overrides the base URL. `nil` reverts to `defaultBaseURL`.
    func setBaseURL(_ value: URL?) {
        write(value?.absoluteString, key: urlKey)
    }

    /// Removes all three Keychain entries; `baseURL` reverts to default.
    func clear() {
        KeychainHelper.delete(key: tokenKey)
        KeychainHelper.delete(key: slugKey)
        KeychainHelper.delete(key: urlKey)
    }

    private func write(_ value: String?, key: String) {
        if let value {
            KeychainHelper.save(key: key, value: value)
        } else {
            KeychainHelper.delete(key: key)
        }
    }
}
