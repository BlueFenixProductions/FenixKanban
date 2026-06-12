import Testing
import Foundation
@testable import FenixKanban

/// Hits the REAL Fizzy server. Auto-skips when `FIZZY_TOKEN` / `FIZZY_ACCOUNT`
/// are absent (CI has none by design). Run locally via `make integration-test`
/// after populating a `.env` file (see `.env.example`).
@Suite("Live: smoke", .enabled(if: LiveTestEnv.isConfigured), .serialized)
struct LiveSmokeTests {

    // MARK: - Identity

    @Test("GET /my/identity decodes and returned accounts contain FIZZY_ACCOUNT slug")
    func identityContainsConfiguredAccount() async throws {
        let client = LiveTestEnv.makeClient()
        let identity = try await client.identity()

        #expect(!identity.accounts.isEmpty, "Expected at least one account in /my/identity response")

        // Normalize the configured slug the same way FizzyClient does:
        // Fizzy returns slugs with a leading `/` (e.g. "/897362094").
        // FIZZY_ACCOUNT may or may not carry the leading slash — normalise both.
        let rawAccount = LiveTestEnv.accountSlug
        let normalizedExpected = rawAccount.hasPrefix("/") ? String(rawAccount.dropFirst()) : rawAccount

        let slugs = identity.accounts.map { account -> String in
            let s = account.slug
            return s.hasPrefix("/") ? String(s.dropFirst()) : s
        }

        #expect(
            slugs.contains(normalizedExpected),
            "Expected slug \(normalizedExpected) in \(slugs)"
        )
    }
}
