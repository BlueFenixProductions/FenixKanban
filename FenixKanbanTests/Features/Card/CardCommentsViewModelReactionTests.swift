import Testing
import CoreData
import Foundation
@testable import FenixKanban

// MARK: - Reaction tests for CardCommentsViewModel (#16)

@Suite("CardComments ViewModel — reactions", .serialized)
@MainActor
struct CardCommentsViewModelReactionTests {

    let persistence: PersistenceController
    let context: NSManagedObjectContext
    let mock = MockHTTPState()

    // Current user's Fizzy ID — matches reacter.id in fixture/inline JSON.
    static let currentUserID = "user-current"
    static let otherUserID = "user-other"
    static let commentID = "cmt-001"
    static let reactionID = "rxn-001"

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        context = persistence.viewContext
    }

    private func makeClient() -> FizzyClient {
        FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: mock.makeSession(),
            clock: ImmediateClock()
        )
    }

    private func makeVM(userID: String? = currentUserID) -> CardCommentsViewModel {
        CardCommentsViewModel(
            cardFizzyNumber: 3,
            client: makeClient(),
            context: context,
            currentFizzyUserID: userID
        )
    }

    /// Builds a minimal FizzyReaction JSON array.
    private func reactionsJSON(
        id: String = reactionID,
        content: String = "👍",
        reacterID: String = currentUserID
    ) -> Data {
        Data("""
        [
          {
            "id": "\(id)",
            "content": "\(content)",
            "reacter": {
              "id": "\(reacterID)",
              "name": "Test User",
              "role": "member",
              "active": true,
              "email_address": "test@example.com",
              "created_at": "2025-12-05T19:36:35.401Z"
            },
            "url": null
          }
        ]
        """.utf8)
    }

    // MARK: (a) loadReactions populates the cache

    @Test("loadReactions: fetches reactions and populates the reactions dict")
    func loadReactionsPopulatesCache() async throws {
        mock.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.path.contains("/comments/\(Self.commentID)/reactions") == true)
            return (self.reactionsJSON(), .ok(for: req))
        }

        let vm = makeVM()
        await vm.loadReactions(for: Self.commentID)

        let cached = try #require(vm.reactions[Self.commentID])
        #expect(cached.count == 1)
        #expect(cached.first?.content == "👍")
        #expect(cached.first?.reacter.id == Self.currentUserID)
    }

    @Test("loadReactions: empty commentID is a no-op")
    func loadReactionsIgnoresEmptyID() async {
        mock.handler = { _ in throw URLError(.unsupportedURL) }
        let vm = makeVM()
        await vm.loadReactions(for: "")
        #expect(vm.reactions.isEmpty)
        #expect(mock.requests.isEmpty)
    }

    @Test("loadReactions: network error leaves existing cache intact")
    func loadReactionsNetworkErrorPreservesCache() async {
        // Pre-seed cache.
        let vm = makeVM()
        let seedReaction = FizzyReaction(
            id: "old-rxn",
            content: "🎉",
            reacter: FizzyUser(
                id: Self.otherUserID,
                name: "Alice",
                role: "member",
                active: true,
                emailAddress: "alice@example.com",
                createdAt: Date(),
                url: nil,
                avatarURL: nil
            ),
            url: nil
        )
        vm.reactions[Self.commentID] = [seedReaction]

        // Network errors on the reactions fetch.
        mock.handler = { _ in throw URLError(.networkConnectionLost) }
        await vm.loadReactions(for: Self.commentID)

        // Cache should still hold the seeded entry.
        #expect(vm.reactions[Self.commentID]?.count == 1)
        #expect(vm.reactions[Self.commentID]?.first?.content == "🎉")
    }

    // MARK: (b) toggleReaction — add path

    @Test("toggleReaction: adds reaction when user has NOT reacted with that emoji")
    func toggleReactionCallsAdd() async throws {
        // No existing reaction for the current user.
        var requestMethods: [String] = []
        mock.handler = { req in
            requestMethods.append(req.httpMethod ?? "")
            if req.httpMethod == "POST" {
                // POST to /reactions — bare 201, no Location (postCreated pattern).
                #expect(req.url?.path.contains("/comments/\(Self.commentID)/reactions") == true)
                return (Data(), .response(for: req, status: 201))
            }
            // Subsequent GET to refresh reactions cache.
            return (self.reactionsJSON(reacterID: Self.currentUserID), .ok(for: req))
        }

        let vm = makeVM()
        // Reactions cache is empty — no prior reaction.
        vm.reactions[Self.commentID] = []
        await vm.toggleReaction(emoji: "👍", for: Self.commentID)

        #expect(requestMethods.contains("POST"))
        #expect(!requestMethods.contains("DELETE"))
        // Cache should be refreshed after toggle.
        #expect(vm.reactions[Self.commentID]?.first?.content == "👍")
    }

    // MARK: (c) toggleReaction — delete path

    @Test("toggleReaction: deletes reaction when user HAS already reacted with that emoji")
    func toggleReactionCallsDelete() async throws {
        var requestMethods: [String] = []
        mock.handler = { req in
            requestMethods.append(req.httpMethod ?? "")
            if req.httpMethod == "DELETE" {
                #expect(req.url?.path.contains("/comments/\(Self.commentID)/reactions/\(Self.reactionID)") == true)
                return (Data(), .response(for: req, status: 204))
            }
            // GET to refresh reactions cache — return empty array after delete.
            return (Data("[]".utf8), .ok(for: req))
        }

        let vm = makeVM()
        // Pre-seed cache with the current user's existing reaction.
        let existing = FizzyReaction(
            id: Self.reactionID,
            content: "👍",
            reacter: FizzyUser(
                id: Self.currentUserID,
                name: "Me",
                role: "member",
                active: true,
                emailAddress: "me@example.com",
                createdAt: Date(),
                url: nil,
                avatarURL: nil
            ),
            url: nil
        )
        vm.reactions[Self.commentID] = [existing]

        await vm.toggleReaction(emoji: "👍", for: Self.commentID)

        #expect(requestMethods.contains("DELETE"))
        #expect(!requestMethods.contains("POST"))
        // Cache refreshed: empty after deletion.
        #expect(vm.reactions[Self.commentID]?.isEmpty == true)
    }

    // MARK: (d) toggleReaction — different user reaction does not trigger delete

    @Test("toggleReaction: adds reaction even when another user reacted with same emoji")
    func toggleReactionDoesNotDeleteOtherUserReaction() async throws {
        var requestMethods: [String] = []
        mock.handler = { req in
            requestMethods.append(req.httpMethod ?? "")
            if req.httpMethod == "POST" {
                return (Data(), .response(for: req, status: 201))
            }
            return (self.reactionsJSON(reacterID: Self.otherUserID), .ok(for: req))
        }

        let vm = makeVM()
        // Seed: another user has reacted with 👍, but NOT the current user.
        let otherReaction = FizzyReaction(
            id: "other-rxn",
            content: "👍",
            reacter: FizzyUser(
                id: Self.otherUserID,
                name: "Other",
                role: "member",
                active: true,
                emailAddress: "other@example.com",
                createdAt: Date(),
                url: nil,
                avatarURL: nil
            ),
            url: nil
        )
        vm.reactions[Self.commentID] = [otherReaction]

        await vm.toggleReaction(emoji: "👍", for: Self.commentID)

        // Should POST (add), not DELETE.
        #expect(requestMethods.contains("POST"))
        #expect(!requestMethods.contains("DELETE"))
    }
}
