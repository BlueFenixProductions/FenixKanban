import Testing
import Foundation
@testable import FenixKanban

// Tests for the FizzyClient comment, reaction, and step convenience methods.
// Wire shapes per fizzy docs/api/sections/comments.md, reactions.md, steps.md.

private final class FixtureLocatorComments {}

@Suite("FizzyClient — comments, reactions & steps", .serialized)
struct FizzyClientCommentsTests {

    init() { MockURLProtocol.reset() }

    private func makeClient() -> FizzyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: session,
            clock: ImmediateClock()
        )
    }

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: FixtureLocatorComments.self)
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/fizzy") {
            return try Data(contentsOf: url)
        }
        if let url = bundle.url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        // Fallback: resolve via #file path (works when resources aren't bundled)
        let testFile = #file
        let testURL = URL(fileURLWithPath: testFile)
        let testBundleDir = testURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixturePath = testBundleDir
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("fizzy")
            .appendingPathComponent("\(name).json")
        guard FileManager.default.fileExists(atPath: fixturePath.path) else {
            Issue.record("Could not locate fixture \(name).json")
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: fixturePath)
    }

    /// Decodes the request's JSON body as a nested object (URLProtocol
    /// exposes the body as a stream). Comment/reaction/step payloads are
    /// wrapped — `{ "comment": { … } }` — unlike the flat card-action bodies.
    private func jsonObject(of request: URLRequest) -> [String: Any]? {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            data = collected
        }
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Comments: list

    @Test("GET /:account/cards/:number/comments decodes the verbatim doc response")
    func commentsListVerbatimDocShape() async throws {
        // Fixture comments_list_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/comments.md, section
        // "GET /:account_slug/cards/:card_number/comments".
        let data = try loadFixture("comments_list_doc")
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/3/comments")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer t")
            return (data, .ok(for: req))
        }

        let comments = try await makeClient().comments(cardNumber: 3)
        #expect(comments.count == 1)
        let comment = try #require(comments.first)
        #expect(comment.id == "03f5v9zo9qlcwwpyc0ascnikz")
        #expect(comment.body.plainText == "This looks great!")
        #expect(comment.body.html == "<div class=\"action-text-content\">This looks great!</div>")
        #expect(comment.creator.name == "David Heinemeier Hansson")
        #expect(comment.card.id == "03f5v9zo9qlcwwpyc0ascnikz")
        #expect(comment.reactionsURL?.absoluteString == "http://app.fizzy.localhost:3006/897362094/cards/3/comments/03f5v9zo9qlcwwpyc0ascnikz/reactions")
    }

    @Test("GET /comments follows Link rel=\"next\" pagination")
    func commentsListPaginates() async throws {
        let data = try loadFixture("comments_list_doc")
        MockURLProtocol.handler = { req in
            if req.url?.query == nil {
                let headers = ["Link": "<https://fizzy.bluefenix.net/ACCT/cards/3/comments?page=2>; rel=\"next\""]
                return (data, .ok(for: req, headers: headers))
            }
            #expect(req.url?.query == "page=2")
            return (data, .ok(for: req))
        }

        let comments = try await makeClient().comments(cardNumber: 3)
        #expect(comments.count == 2)
        #expect(MockURLProtocol.requests.count == 2)
    }

    // MARK: - Comments: detail

    @Test("GET /:account/cards/:number/comments/:id decodes the verbatim doc response")
    func commentDetailVerbatimDocShape() async throws {
        // Fixture comment_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/comments.md, section
        // "GET /:account_slug/cards/:card_number/comments/:comment_id".
        let data = try loadFixture("comment_doc")
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/3/comments/03f5v9zo9qlcwwpyc0ascnikz")
            return (data, .ok(for: req))
        }

        let comment = try await makeClient().comment(cardNumber: 3, id: "03f5v9zo9qlcwwpyc0ascnikz")
        #expect(comment.id == "03f5v9zo9qlcwwpyc0ascnikz")
        #expect(comment.body.plainText == "This looks great!")
        #expect(comment.creator.emailAddress == "david@example.com")
        #expect(comment.url?.absoluteString == "http://app.fizzy.localhost:3006/897362094/cards/3/comments/03f5v9zo9qlcwwpyc0ascnikz")
    }

    // MARK: - Comments: create

    @Test("POST /comments sends wrapped body, follows 201 Location, returns comment")
    func createComment() async throws {
        let data = try loadFixture("comment_doc")
        let body = LockedBox<[String: Any]?>(nil)
        MockURLProtocol.handler = { req in
            if req.httpMethod == "POST" {
                #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/3/comments")
                #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
                body.value = self.jsonObject(of: req)
                let headers = ["Location": "https://fizzy.bluefenix.net/ACCT/cards/3/comments/03f5v9zo9qlcwwpyc0ascnikz"]
                return (Data(), .response(for: req, status: 201, headers: headers))
            }
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/3/comments/03f5v9zo9qlcwwpyc0ascnikz")
            return (data, .ok(for: req))
        }

        let comment = try await makeClient().createComment(cardNumber: 3, body: "This looks great!")
        #expect(body.value?["comment"] as? [String: String] == ["body": "This looks great!"])
        #expect(comment.id == "03f5v9zo9qlcwwpyc0ascnikz")
        #expect(MockURLProtocol.requests.count == 2)
    }

    @Test("POST /comments includes created_at override when provided")
    func createCommentWithCreatedAtOverride() async throws {
        let data = try loadFixture("comment_doc")
        let body = LockedBox<[String: Any]?>(nil)
        MockURLProtocol.handler = { req in
            if req.httpMethod == "POST" {
                body.value = self.jsonObject(of: req)
                let headers = ["Location": "https://fizzy.bluefenix.net/ACCT/cards/3/comments/03f5v9zo9qlcwwpyc0ascnikz"]
                return (Data(), .response(for: req, status: 201, headers: headers))
            }
            return (data, .ok(for: req))
        }

        let createdAt = Date(timeIntervalSince1970: 1_765_000_000) // 2025-12-06T05:46:40Z
        _ = try await makeClient().createComment(
            cardNumber: 3,
            body: "Backdated",
            createdAt: createdAt
        )
        let wrapped = try #require(body.value?["comment"] as? [String: String])
        #expect(wrapped["body"] == "Backdated")
        #expect(wrapped["created_at"] == "2025-12-06T05:46:40Z")
    }

    // MARK: - Comments: update

    @Test("PUT /comments/:id sends wrapped body and returns the updated comment")
    func updateComment() async throws {
        let data = try loadFixture("comment_doc")
        let body = LockedBox<[String: Any]?>(nil)
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "PUT")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/3/comments/03f5v9zo9qlcwwpyc0ascnikz")
            body.value = self.jsonObject(of: req)
            return (data, .ok(for: req))
        }

        let updated = try await makeClient().updateComment(
            cardNumber: 3,
            id: "03f5v9zo9qlcwwpyc0ascnikz",
            body: "This looks even better now!"
        )
        #expect(body.value?["comment"] as? [String: String] == ["body": "This looks even better now!"])
        #expect(updated.id == "03f5v9zo9qlcwwpyc0ascnikz")
    }

    // MARK: - Comments: delete

    @Test("DELETE /comments/:id deletes the comment (204)")
    func deleteComment() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/3/comments/03f5v9zo9qlcwwpyc0ascnikz")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().deleteComment(cardNumber: 3, id: "03f5v9zo9qlcwwpyc0ascnikz")
        #expect(MockURLProtocol.requests.count == 1)
    }

    @Test("comment endpoints surface HTTP errors as FizzyError")
    func commentErrorMapping() async throws {
        MockURLProtocol.handler = { req in (Data(), .response(for: req, status: 404)) }
        await #expect(throws: FizzyError.notFound) {
            try await makeClient().comment(cardNumber: 3, id: "missing")
        }
    }

    // MARK: - Card reactions (boosts)

    @Test("GET /:account/cards/:number/reactions decodes the verbatim doc response")
    func cardReactionsVerbatimDocShape() async throws {
        // Fixture card_reactions_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/reactions.md, section
        // "GET /:account_slug/cards/:card_number/reactions" (Card Reactions).
        let data = try loadFixture("card_reactions_doc")
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/3/reactions")
            return (data, .ok(for: req))
        }

        let reactions = try await makeClient().cardReactions(cardNumber: 3)
        #expect(reactions.count == 1)
        let reaction = try #require(reactions.first)
        #expect(reaction.id == "03f5v9zo9qlcwwpyc0ascnikz")
        #expect(reaction.content == "👍")
        #expect(reaction.reacter.id == "03f5v9zjw7pz8717a4no1h8a7")
        #expect(reaction.url?.absoluteString == "http://app.fizzy.localhost:3006/897362094/cards/3/reactions/03f5v9zo9qlcwwpyc0ascnikz")
    }

    @Test("POST /reactions sends wrapped content body and accepts bare 201")
    func addCardReaction() async throws {
        let body = LockedBox<[String: Any]?>(nil)
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/3/reactions")
            #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
            body.value = self.jsonObject(of: req)
            return (Data(), .response(for: req, status: 201))
        }
        try await makeClient().addCardReaction(cardNumber: 3, content: "Great 👍")
        #expect(body.value?["reaction"] as? [String: String] == ["content": "Great 👍"])
        #expect(MockURLProtocol.requests.count == 1)
    }

    @Test("DELETE /reactions/:id removes a card reaction (204)")
    func deleteCardReaction() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/3/reactions/03f5v9zo9qlcwwpyc0ascnikz")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().deleteCardReaction(cardNumber: 3, reactionID: "03f5v9zo9qlcwwpyc0ascnikz")
    }

    // MARK: - Comment reactions

    @Test("GET /comments/:id/reactions decodes the verbatim doc response")
    func commentReactionsVerbatimDocShape() async throws {
        // Fixture comment_reactions_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/reactions.md, section
        // "GET /:account_slug/cards/:card_number/comments/:comment_id/reactions".
        let data = try loadFixture("comment_reactions_doc")
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/3/comments/03f5v9zo9qlcwwpyc0ascnikz/reactions")
            return (data, .ok(for: req))
        }

        let reactions = try await makeClient().commentReactions(
            cardNumber: 3,
            commentID: "03f5v9zo9qlcwwpyc0ascnikz"
        )
        #expect(reactions.count == 1)
        let reaction = try #require(reactions.first)
        #expect(reaction.content == "👍")
        #expect(reaction.reacter.name == "David Heinemeier Hansson")
        #expect(reaction.url?.absoluteString == "http://app.fizzy.localhost:3006/897362094/cards/3/comments/03f5v9zo9qlcwwpyc0ascnikz/reactions/03f5v9zo9qlcwwpyc0ascnikz")
    }

    @Test("POST /comments/:id/reactions sends wrapped content body (201)")
    func addCommentReaction() async throws {
        let body = LockedBox<[String: Any]?>(nil)
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/3/comments/03f5v9zo9qlcwwpyc0ascnikz/reactions")
            body.value = self.jsonObject(of: req)
            return (Data(), .response(for: req, status: 201))
        }
        try await makeClient().addCommentReaction(
            cardNumber: 3,
            commentID: "03f5v9zo9qlcwwpyc0ascnikz",
            content: "Great 👍"
        )
        #expect(body.value?["reaction"] as? [String: String] == ["content": "Great 👍"])
    }

    @Test("DELETE /comments/:id/reactions/:id removes a comment reaction (204)")
    func deleteCommentReaction() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/3/comments/03f5v9zo9qlcwwpyc0ascnikz/reactions/03f5v9zo9qlcwwpyc0ascnikz")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().deleteCommentReaction(
            cardNumber: 3,
            commentID: "03f5v9zo9qlcwwpyc0ascnikz",
            reactionID: "03f5v9zo9qlcwwpyc0ascnikz"
        )
    }

    // MARK: - Steps

    @Test("GET /:account/cards/:number/steps/:id decodes the verbatim doc response")
    func stepDetailVerbatimDocShape() async throws {
        // Fixture step_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/steps.md, section
        // "GET /:account_slug/cards/:card_number/steps/:step_id".
        let data = try loadFixture("step_doc")
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/3/steps/03f5v9zo9qlcwwpyc0ascnikz")
            return (data, .ok(for: req))
        }

        let step = try await makeClient().step(cardNumber: 3, id: "03f5v9zo9qlcwwpyc0ascnikz")
        #expect(step.id == "03f5v9zo9qlcwwpyc0ascnikz")
        #expect(step.content == "Write tests")
        #expect(step.completed == false)
    }

    @Test("POST /steps sends wrapped body, follows 201 Location, returns step")
    func createStep() async throws {
        let data = try loadFixture("step_doc")
        let body = LockedBox<[String: Any]?>(nil)
        MockURLProtocol.handler = { req in
            if req.httpMethod == "POST" {
                #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/3/steps")
                body.value = self.jsonObject(of: req)
                let headers = ["Location": "https://fizzy.bluefenix.net/ACCT/cards/3/steps/03f5v9zo9qlcwwpyc0ascnikz"]
                return (Data(), .response(for: req, status: 201, headers: headers))
            }
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/3/steps/03f5v9zo9qlcwwpyc0ascnikz")
            return (data, .ok(for: req))
        }

        let step = try await makeClient().createStep(cardNumber: 3, content: "Write tests")
        #expect(body.value?["step"] as? NSDictionary == ["content": "Write tests"])
        #expect(step.id == "03f5v9zo9qlcwwpyc0ascnikz")
        #expect(step.content == "Write tests")
        #expect(MockURLProtocol.requests.count == 2)
    }

    @Test("PUT /steps/:id sends only provided fields and returns the updated step")
    func updateStepCompletedOnly() async throws {
        let body = LockedBox<[String: Any]?>(nil)
        let updatedJSON = Data("""
        {"id": "03f5v9zo9qlcwwpyc0ascnikz", "content": "Write tests", "completed": true}
        """.utf8)
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "PUT")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/3/steps/03f5v9zo9qlcwwpyc0ascnikz")
            body.value = self.jsonObject(of: req)
            return (updatedJSON, .ok(for: req))
        }

        let step = try await makeClient().updateStep(
            cardNumber: 3,
            id: "03f5v9zo9qlcwwpyc0ascnikz",
            completed: true
        )
        // Per steps.md PUT example, only the provided field is sent —
        // `content` must be omitted, not serialized as null.
        #expect(body.value?["step"] as? NSDictionary == ["completed": true])
        #expect(step.completed == true)
    }

    @Test("DELETE /steps/:id deletes the step (204)")
    func deleteStep() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/3/steps/03f5v9zo9qlcwwpyc0ascnikz")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().deleteStep(cardNumber: 3, id: "03f5v9zo9qlcwwpyc0ascnikz")
        #expect(MockURLProtocol.requests.count == 1)
    }
}

/// Tiny reference box so the MockURLProtocol handler (a sync closure) can
/// pass captured request data back to the async test body.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
