import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzyAuthState", .serialized)
struct FizzyAuthStateTests {

    private let prefix: String
    private let state: FizzyAuthState

    init() {
        prefix = "test.fizzy.\(UUID().uuidString)"
        state = FizzyAuthState(keyPrefix: prefix)
    }

    private func tearDown() {
        state.clear()
    }

    @Test("default state: nil token, nil slug, default baseURL, not configured")
    func defaultState() {
        defer { tearDown() }
        #expect(state.accessToken == nil)
        #expect(state.accountSlug == nil)
        #expect(state.baseURL == FizzyAuthState.defaultBaseURL)
        #expect(state.isConfigured == false)
    }

    @Test("setAccessToken + setAccountSlug round-trip; isConfigured flips true")
    func tokenAndSlugRoundTrip() {
        defer { tearDown() }
        state.setAccessToken("claude-dev-token")
        state.setAccountSlug("897362094")

        #expect(state.accessToken == "claude-dev-token")
        #expect(state.accountSlug == "897362094")
        #expect(state.isConfigured == true)
    }

    @Test("setBaseURL overrides default; nil reverts to default")
    func baseURLOverrideAndRevert() throws {
        defer { tearDown() }
        let custom = URL(string: "http://localhost:3006")!
        state.setBaseURL(custom)
        #expect(state.baseURL == custom)

        state.setBaseURL(nil)
        #expect(state.baseURL == FizzyAuthState.defaultBaseURL)
    }

    @Test("clear() removes all three keys; isConfigured returns to false")
    func clearResets() {
        state.setAccessToken("t")
        state.setAccountSlug("s")
        state.setBaseURL(URL(string: "http://localhost:3006")!)
        #expect(state.isConfigured == true)

        state.clear()

        #expect(state.accessToken == nil)
        #expect(state.accountSlug == nil)
        #expect(state.baseURL == FizzyAuthState.defaultBaseURL)
        #expect(state.isConfigured == false)
    }
}
