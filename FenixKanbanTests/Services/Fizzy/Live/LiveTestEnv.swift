import Foundation
@testable import FenixKanban

/// Environment configuration for live-API integration tests.
///
/// Values are read from `ProcessInfo.processInfo.environment`. When running
/// via `make integration-test`, `xcodebuild` forwards the shell env with the
/// `TEST_RUNNER_` prefix stripped — so `TEST_RUNNER_FIZZY_TOKEN` in the shell
/// becomes `FIZZY_TOKEN` inside the test process.
///
/// The suite is gated on `isConfigured`; when credentials are absent (CI by
/// construction), Swift Testing marks the entire suite as skipped rather than
/// failing.
enum LiveTestEnv {

    private static let env = ProcessInfo.processInfo.environment

    // MARK: - Required credentials

    /// Bearer token for Fizzy API authentication.
    static var token: String { env["FIZZY_TOKEN"] ?? "" }

    /// Account slug (with or without leading `/`).
    static var accountSlug: String { env["FIZZY_ACCOUNT"] ?? "" }

    // MARK: - Optional overrides

    /// Base URL for the Fizzy server. Defaults to https://fizzy.bluefenix.net.
    static var baseURL: URL {
        if let raw = env["FIZZY_BASE_URL"], !raw.isEmpty, let url = URL(string: raw) {
            return url
        }
        return URL(string: "https://fizzy.bluefenix.net")!
    }

    /// Expected number of cards in the configured account (used by future
    /// load-validation tests). Defaults to 32.
    static var expectedCards: Int {
        if let raw = env["FIZZY_EXPECTED_CARDS"], let n = Int(raw) { return n }
        return 32
    }

    /// Whether mutation tests (POST, PUT, DELETE) may run. Set
    /// `FIZZY_ALLOW_MUTATION=1` to enable. Defaults to false.
    static var allowsMutation: Bool {
        env["FIZZY_ALLOW_MUTATION"] == "1"
    }

    // MARK: - Gate

    /// True when both `FIZZY_TOKEN` and `FIZZY_ACCOUNT` are non-empty.
    /// Used as the `.enabled(if:)` condition on live test suites.
    static var isConfigured: Bool {
        !token.isEmpty && !accountSlug.isEmpty
    }

    // MARK: - Factory

    /// Builds a live `FizzyClient` from the current environment values.
    /// The client uses `URLSession.shared` and the default `ContinuousClock`.
    static func makeClient() -> FizzyClient {
        FizzyClient(
            baseURL: baseURL,
            accessToken: token,
            accountSlug: accountSlug
        )
    }
}
