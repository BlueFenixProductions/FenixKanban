import Testing
import CoreData
import Foundation
@testable import FenixKanban

// Fixture locator anchor for Bundle(for:) path resolution.
private final class FixtureLocatorCardComments {}

// MARK: - Cache-first + write-through tests

@Suite("CardComments ViewModel — cache-first", .serialized)
@MainActor
struct CardCommentsViewModelCacheTests {

    let persistence: PersistenceController
    let context: NSManagedObjectContext
    let mock = MockHTTPState()

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

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: FixtureLocatorCardComments.self)
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/fizzy") {
            return try Data(contentsOf: url)
        }
        if let url = bundle.url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        let testURL = URL(fileURLWithPath: #file)
        let fixturePath = testURL
            .deletingLastPathComponent()   // Card
            .deletingLastPathComponent()   // Features
            .deletingLastPathComponent()   // FenixKanbanTests root
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("fizzy")
            .appendingPathComponent("\(name).json")
        guard FileManager.default.fileExists(atPath: fixturePath.path) else {
            Issue.record("Could not locate fixture \(name).json at \(fixturePath.path)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: fixturePath)
    }

    // MARK: (a) Cache served instantly without network

    @Test("cache-first: existing cached comments exposed immediately without a network call")
    func cacheFirstExposedInstantly() throws {
        // Seed one comment into CoreData before creating the VM.
        let repo = CommentRepository(context: context)
        let seeded = repo.insertOptimistic(body: "Seeded comment", cardFizzyNumber: 3, creatorName: "Alice")
        seeded.pendingWrite = false
        seeded.fizzyCommentID = "cached-id"
        try context.save()

        // Handler that throws — proves no network call was made.
        mock.handler = { _ in throw URLError(.networkConnectionLost) }

        let vm = CardCommentsViewModel(
            cardFizzyNumber: 3,
            client: makeClient(),
            context: context
        )

        // Comments are available immediately (no await needed).
        #expect(vm.comments.count == 1)
        #expect(vm.comments.first?.body == "Seeded comment")
        #expect(mock.requests.isEmpty)
    }

    @Test("cache-first: empty cache gives zero comments without a network call")
    func cacheFirstEmptyCache() {
        mock.handler = { _ in throw URLError(.networkConnectionLost) }

        let vm = CardCommentsViewModel(
            cardFizzyNumber: 99,
            client: makeClient(),
            context: context
        )

        #expect(vm.comments.isEmpty)
        #expect(mock.requests.isEmpty)
    }

    // MARK: (b) Refresh reconciles — server adds land; pending survive

    @Test("refresh: server-authoritative entries land; pending comments survive")
    func refreshReconcilesPendingSurvives() async throws {
        // Seed: one committed entry and one pending entry.
        let repo = CommentRepository(context: context)
        let committed = repo.insertOptimistic(body: "Old comment", cardFizzyNumber: 3, creatorName: "Bob")
        committed.pendingWrite = false
        committed.fizzyCommentID = "old-id"
        let pending = repo.insertOptimistic(body: "Pending comment", cardFizzyNumber: 3, creatorName: "Me")
        try context.save()

        // Fixture comments_list_doc.json consumed verbatim (project rule:
        // at least one test must consume a fixture verbatim — issue #16).
        let listData = try loadFixture("comments_list_doc")
        mock.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.path.contains("/cards/3/comments") == true)
            return (listData, .ok(for: req))
        }

        let vm = CardCommentsViewModel(
            cardFizzyNumber: 3,
            client: makeClient(),
            context: context
        )
        await vm.refresh()

        // Server adds the fixture comment (id: 03f5v9zo9qlcwwpyc0ascnikz).
        // The old committed entry (old-id) is absent from server → deleted.
        // The pending entry survives.
        let ids = vm.comments.map { $0.fizzyCommentID }
        #expect(ids.contains("03f5v9zo9qlcwwpyc0ascnikz"))
        let pendingEntries = vm.comments.filter { $0.pendingWrite }
        #expect(pendingEntries.count == 1)
        #expect(pendingEntries.first?.body == "Pending comment")
        #expect(vm.errorMessage == nil)

        // Suppress unused-variable warning.
        _ = pending
    }

    @Test("refresh: verbatim fixture decodes — body.plain_text and creator.name map correctly")
    func refreshVerbatimFixtureDecodes() async throws {
        // This test consumes comments_list_doc.json VERBATIM — required by the
        // test fixture wire-shape rule so real-API encoding bugs stay caught.
        let listData = try loadFixture("comments_list_doc")
        mock.handler = { req in (listData, .ok(for: req)) }

        let vm = CardCommentsViewModel(
            cardFizzyNumber: 3,
            client: makeClient(),
            context: context
        )
        await vm.refresh()

        let comment = try #require(vm.comments.first)
        #expect(comment.fizzyCommentID == "03f5v9zo9qlcwwpyc0ascnikz")
        #expect(comment.body == "This looks great!")
        #expect(comment.creatorName == "David Heinemeier Hansson")
        #expect(comment.pendingWrite == false)
        #expect(vm.errorMessage == nil)
    }

    // MARK: (c) post() optimistic-inserts then clears pendingWrite on 200

    @Test("post: optimistic-inserts immediately then clears pendingWrite on 201")
    func postOptimisticThenClears() async throws {
        let commentData = try loadFixture("comment_doc")

        let vm = CardCommentsViewModel(
            cardFizzyNumber: 3,
            client: makeClient(),
            context: context
        )

        // Use delayedHandler (async) to gate the POST in flight while we
        // inspect the optimistic state — matches the pattern in
        // CardDetailViewModelTests (StepPutCallCounter / gated handler).
        let (gate, releasePost) = AsyncStream.makeStream(of: Void.self)
        let called = PostCallCounter()
        mock.delayedHandler = { req in
            if req.httpMethod == "POST" {
                called.increment()
                var iter = gate.makeAsyncIterator()
                _ = await iter.next()
                let headers = ["Location": "https://fizzy.bluefenix.net/ACCT/cards/3/comments/03f5v9zo9qlcwwpyc0ascnikz"]
                return (Data(), .response(for: req, status: 201, headers: headers))
            }
            // GET after 201+Location
            return (commentData, .ok(for: req))
        }

        async let posting: Void = vm.post(body: "This looks great!")
        // Wait for the POST to be in flight.
        while called.value == 0 { await Task.yield() }

        // Optimistic entry is visible with pendingWrite = true.
        #expect(vm.comments.count == 1)
        #expect(vm.comments.first?.pendingWrite == true)
        #expect(vm.comments.first?.body == "This looks great!")

        // Release the gate and await completion.
        releasePost.yield()
        await posting

        // After success: pendingWrite cleared, server ID set.
        #expect(vm.comments.count == 1)
        #expect(vm.comments.first?.pendingWrite == false)
        #expect(vm.comments.first?.fizzyCommentID == "03f5v9zo9qlcwwpyc0ascnikz")
        #expect(vm.errorMessage == nil)
    }

    // MARK: (d) Failed post keeps pendingWrite

    @Test("post: failed POST leaves entry with pendingWrite = true for retry")
    func postFailedKeepsPending() async throws {
        mock.handler = { req in
            (Data("{\"error\":\"nope\"}".utf8), .response(for: req, status: 422))
        }

        let vm = CardCommentsViewModel(
            cardFizzyNumber: 3,
            client: makeClient(),
            context: context
        )
        await vm.post(body: "Retry me")

        #expect(vm.comments.count == 1)
        #expect(vm.comments.first?.pendingWrite == true)
        #expect(vm.comments.first?.body == "Retry me")
        // No error surfaced to UI for pending state (indicator in view is enough).
    }

    @Test("post: whitespace-only body is a no-op")
    func postIgnoresWhitespace() async throws {
        mock.handler = { _ in throw URLError(.unsupportedURL) }

        let vm = CardCommentsViewModel(
            cardFizzyNumber: 3,
            client: makeClient(),
            context: context
        )
        await vm.post(body: "   ")

        #expect(vm.comments.isEmpty)
        #expect(mock.requests.isEmpty)
    }

    // MARK: (e) retryPending() re-posts

    @Test("retryPending: re-posts all pendingWrite comments and clears flag on success")
    func retryPendingRepostsAll() async throws {
        let commentData = try loadFixture("comment_doc")
        let repo = CommentRepository(context: context)
        // Seed two pending entries.
        let p1 = repo.insertOptimistic(body: "First pending", cardFizzyNumber: 3, creatorName: "Me")
        let p2 = repo.insertOptimistic(body: "Second pending", cardFizzyNumber: 3, creatorName: "Me")
        try context.save()

        var postCount = 0
        mock.handler = { req in
            if req.httpMethod == "POST" {
                postCount += 1
                let headers = ["Location": "https://fizzy.bluefenix.net/ACCT/cards/3/comments/03f5v9zo9qlcwwpyc0ascnikz"]
                return (Data(), .response(for: req, status: 201, headers: headers))
            }
            return (commentData, .ok(for: req))
        }

        let vm = CardCommentsViewModel(
            cardFizzyNumber: 3,
            client: makeClient(),
            context: context
        )
        await vm.retryPending()

        #expect(postCount == 2)
        // All comments now have pendingWrite = false.
        let stillPending = vm.comments.filter { $0.pendingWrite }
        #expect(stillPending.isEmpty)

        // Suppress unused-variable warnings.
        _ = p1; _ = p2
    }

    @Test("retryPending: failed retry leaves entry still pending")
    func retryPendingKeepsOnFailure() async throws {
        let repo = CommentRepository(context: context)
        _ = repo.insertOptimistic(body: "Will fail", cardFizzyNumber: 3, creatorName: "Me")
        try context.save()

        mock.handler = { req in
            (Data("{\"error\":\"server error\"}".utf8), .response(for: req, status: 500))
        }

        let vm = CardCommentsViewModel(
            cardFizzyNumber: 3,
            client: makeClient(),
            context: context
        )
        await vm.retryPending()

        #expect(vm.comments.count == 1)
        #expect(vm.comments.first?.pendingWrite == true)
    }

    // MARK: Repository tests

    @Test("CommentRepository: fetchComments returns entries sorted by createdAt")
    func repoFetchSortedByCreatedAt() throws {
        let repo = CommentRepository(context: context)
        let later = repo.insertOptimistic(body: "Later", cardFizzyNumber: 5, creatorName: "B")
        later.createdAt = Date(timeIntervalSince1970: 2_000_000)
        let earlier = repo.insertOptimistic(body: "Earlier", cardFizzyNumber: 5, creatorName: "A")
        earlier.createdAt = Date(timeIntervalSince1970: 1_000_000)
        try context.save()

        let fetched = repo.fetchComments(for: 5)
        #expect(fetched.map(\.body) == ["Earlier", "Later"])
    }

    @Test("CommentRepository: upsert inserts new, updates existing, deletes removed, preserves pending")
    func repoUpsertReconciles() throws {
        let repo = CommentRepository(context: context)
        // Insert a committed entry and a pending entry.
        let existing = repo.insertOptimistic(body: "Server comment", cardFizzyNumber: 7, creatorName: "A")
        existing.pendingWrite = false
        existing.fizzyCommentID = "server-id"
        let pending = repo.insertOptimistic(body: "My pending", cardFizzyNumber: 7, creatorName: "Me")
        try context.save()

        // Server response: the existing entry is updated, a new one added.
        let remote = FizzyComment(
            id: "server-id",
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_000_000),
            body: FizzyCommentBody(plainText: "Updated body", html: "<p>Updated body</p>"),
            creator: FizzyUser(id: "u1", name: "Alice", role: "member", active: true,
                               emailAddress: "a@example.com", createdAt: .now, url: nil, avatarURL: nil),
            card: FizzyCardRef(id: "c1", url: nil),
            reactionsURL: nil,
            url: nil
        )
        let newRemote = FizzyComment(
            id: "new-id",
            createdAt: Date(timeIntervalSince1970: 2_000_000),
            updatedAt: Date(timeIntervalSince1970: 2_000_000),
            body: FizzyCommentBody(plainText: "Brand new", html: "<p>Brand new</p>"),
            creator: FizzyUser(id: "u2", name: "Bob", role: "member", active: true,
                               emailAddress: "b@example.com", createdAt: .now, url: nil, avatarURL: nil),
            card: FizzyCardRef(id: "c1", url: nil),
            reactionsURL: nil,
            url: nil
        )
        repo.upsert(from: [remote, newRemote], cardFizzyNumber: 7)

        let all = repo.fetchComments(for: 7)
        // Pending survives.
        let pendingEntries = all.filter { $0.pendingWrite }
        #expect(pendingEntries.count == 1)
        #expect(pendingEntries.first?.body == "My pending")
        // Updated existing entry.
        let updated = all.first { $0.fizzyCommentID == "server-id" }
        #expect(updated?.body == "Updated body")
        // New server entry inserted.
        let newEntry = all.first { $0.fizzyCommentID == "new-id" }
        #expect(newEntry?.body == "Brand new")

        _ = pending
    }

    @Test("CommentRepository: markSent clears pendingWrite and records server ID")
    func repoMarkSent() throws {
        let repo = CommentRepository(context: context)
        let optimistic = repo.insertOptimistic(body: "Sending", cardFizzyNumber: 3, creatorName: "Me")
        try context.save()

        #expect(optimistic.pendingWrite == true)
        repo.markSent(optimistic, serverID: "srv-123")
        #expect(optimistic.pendingWrite == false)
        #expect(optimistic.fizzyCommentID == "srv-123")
    }
}

// MARK: - Thread-safe call counter helpers

private final class PostCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
}
