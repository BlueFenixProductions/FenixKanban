import Testing
import Foundation
@testable import FenixKanban

// Tests for the FizzyClient board + column convenience methods (Batch 2).
// Wire shapes per fizzy docs/api/sections/boards.md and columns.md.

private final class FixtureLocatorBoards {}

@Suite("FizzyClient — boards & columns", .serialized)
struct FizzyClientBoardsTests {

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
        let bundle = Bundle(for: FixtureLocatorBoards.self)
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

    /// Decodes the request's JSON body (URLProtocol exposes it as a stream).
    private func jsonBody(of request: URLRequest) -> [String: Any]? {
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

    // MARK: - Boards list

    @Test("GET /:account/boards decodes the verbatim doc response")
    func boardsListVerbatimDocShape() async throws {
        // Fixture boards_list_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/boards.md, section "GET /:account_slug/boards".
        let data = try loadFixture("boards_list_doc")
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/boards")
            return (data, .ok(for: req))
        }

        let boards = try await makeClient().boards()
        #expect(boards.count == 1)
        let board = try #require(boards.first)
        #expect(board.id == "03f5v9zkft4hj9qq0lsn9ohcm")
        #expect(board.name == "Fizzy")
        #expect(board.allAccess == true)
        #expect(board.autoPostponePeriodInDays == 30)
        #expect(board.creator.name == "David Heinemeier Hansson")
        #expect(board.creator.role == "owner")
    }

    // MARK: - Board detail

    @Test("GET /:account/boards/:id decodes the verbatim doc response incl. publication fields")
    func boardDetailVerbatimDocShape() async throws {
        // Fixture board_detail_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/boards.md, section "GET /:account_slug/boards/:board_id".
        let data = try loadFixture("board_detail_doc")
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/boards/B1")
            return (data, .ok(for: req))
        }

        let board = try await makeClient().board(id: "B1")
        #expect(board.id == "03f5v9zkft4hj9qq0lsn9ohcm")
        #expect(board.allAccess == false)
        #expect(board.publicDescription == "Follow along with public product updates.")
        #expect(board.publicDescriptionHTML?.contains("trix-content") == true)
        #expect(board.userIds == ["03f5v9zjw7pz8717a4no1h8a7", "03f5v9zppzlksuj4mxba2nbzn"])
        #expect(board.publicURL?.absoluteString == "http://app.fizzy.localhost:3006/897362094/public/boards/aB3dEfGhIjKlMnOp")
    }

    // MARK: - Create board

    @Test("POST /:account/boards sends {board:{…}}, follows Location to GET the new board")
    func createBoardFollowsLocation() async throws {
        let detail = try loadFixture("board_detail_doc")
        MockURLProtocol.handler = { req in
            if req.httpMethod == "POST" {
                #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/boards")
                let body = self.jsonBody(of: req)
                let board = body?["board"] as? [String: Any]
                #expect(board?["name"] as? String == "My new board")
                return (Data(), .response(
                    for: req, status: 201,
                    headers: ["Location": "https://fizzy.bluefenix.net/ACCT/boards/03f5v9zkft4hj9qq0lsn9ohcm"]
                ))
            }
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/boards/03f5v9zkft4hj9qq0lsn9ohcm")
            return (detail, .ok(for: req))
        }

        let created = try await makeClient().createBoard(FizzyBoardWrite(name: "My new board"))
        #expect(created.id == "03f5v9zkft4hj9qq0lsn9ohcm")
        #expect(MockURLProtocol.requests.count == 2)
    }

    // MARK: - Update board

    @Test("PUT /:account/boards/:id sends {board:{…}} and returns the updated board")
    func updateBoardReturnsUpdatedBoard() async throws {
        let detail = try loadFixture("board_detail_doc")
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "PUT")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/boards/B1")
            let body = self.jsonBody(of: req)
            let board = body?["board"] as? [String: Any]
            #expect(board?["name"] as? String == "Updated board name")
            #expect(board?["all_access"] as? Bool == false)
            #expect(board?["user_ids"] as? [String] == ["u1", "u2"])
            return (detail, .ok(for: req))
        }

        var write = FizzyBoardWrite(name: "Updated board name")
        write.allAccess = false
        write.userIds = ["u1", "u2"]
        let updated = try await makeClient().updateBoard(id: "B1", with: write)
        #expect(updated?.id == "03f5v9zkft4hj9qq0lsn9ohcm")
    }

    @Test("PUT /:account/boards/:id returning 204 (self access removal) yields nil")
    func updateBoardSelfRemovalReturnsNil() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "PUT")
            return (Data(), .response(for: req, status: 204))
        }
        var write = FizzyBoardWrite(name: nil)
        write.userIds = []
        let updated = try await makeClient().updateBoard(id: "B1", with: write)
        #expect(updated == nil)
    }

    // MARK: - Delete board

    @Test("DELETE /:account/boards/:id deletes the board (204)")
    func deleteBoard() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/boards/B1")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().deleteBoard(id: "B1")
        #expect(MockURLProtocol.requests.count == 1)
    }

    // MARK: - Board accesses

    @Test("GET /:account/boards/:id/accesses decodes the verbatim doc response")
    func boardAccessesVerbatimDocShape() async throws {
        // Fixture board_accesses_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/boards.md, section "GET /:account_slug/boards/:board_id/accesses".
        let data = try loadFixture("board_accesses_doc")
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/boards/B1/accesses")
            return (data, .ok(for: req))
        }

        let accesses = try await makeClient().boardAccesses(boardID: "B1")
        #expect(accesses.boardId == "03f5v9zkft4hj9qq0lsn9ohcm")
        #expect(accesses.allAccess == false)
        #expect(accesses.users.count == 2)
        #expect(accesses.users[0].hasAccess == true)
        #expect(accesses.users[0].involvement == "watching")
        #expect(accesses.users[0].avatarURL != nil)
        #expect(accesses.users[1].hasAccess == false)
        #expect(accesses.users[1].involvement == nil)
    }

    @Test("GET accesses follows Link rel=next and merges users across pages")
    func boardAccessesFollowsLinkPagination() async throws {
        let page1 = try loadFixture("board_accesses_doc")
        let page2 = Data("""
        {
          "board_id": "03f5v9zkft4hj9qq0lsn9ohcm",
          "all_access": false,
          "users": [
            {
              "id": "u3",
              "name": "Third User",
              "role": "member",
              "active": true,
              "email_address": "third@example.com",
              "created_at": "2025-12-05T19:36:35.401Z",
              "url": "http://fizzy.localhost:3006/897362094/users/u3",
              "avatar_url": "http://fizzy.localhost:3006/897362094/users/u3/avatar",
              "has_access": true,
              "involvement": "access_only"
            }
          ]
        }
        """.utf8)
        MockURLProtocol.handler = { req in
            if req.url?.query() == nil {
                let headers = ["Link": "<https://fizzy.bluefenix.net/ACCT/boards/B1/accesses?page=2>; rel=\"next\""]
                return (page1, .ok(for: req, headers: headers))
            }
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/boards/B1/accesses?page=2")
            return (page2, .ok(for: req))
        }

        let accesses = try await makeClient().boardAccesses(boardID: "B1")
        #expect(accesses.users.count == 3)
        #expect(accesses.users[2].involvement == "access_only")
        #expect(MockURLProtocol.requests.count == 2)
    }

    // MARK: - Board publication

    @Test("POST /:account/boards/:id/publication returns 201 with the verbatim doc body")
    func publishBoardVerbatimDocShape() async throws {
        // Fixture board_publication_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/boards.md, section "POST /:account_slug/boards/:board_id/publication".
        let data = try loadFixture("board_publication_doc")
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/boards/B1/publication")
            return (data, .response(for: req, status: 201))
        }

        let board = try await makeClient().publishBoard(id: "B1")
        #expect(board.id == "03f5v9zkft4hj9qq0lsn9ohcm")
        #expect(board.publicURL?.absoluteString == "http://app.fizzy.localhost:3006/897362094/public/boards/aB3dEfGhIjKlMnOp")
        #expect(MockURLProtocol.requests.count == 1)
    }

    @Test("DELETE /:account/boards/:id/publication unpublishes the board (204)")
    func unpublishBoard() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/boards/B1/publication")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().unpublishBoard(id: "B1")
        #expect(MockURLProtocol.requests.count == 1)
    }

    // MARK: - Column detail

    @Test("GET /:account/boards/:id/columns/:column_id decodes the verbatim doc response (string color)")
    func columnDetailVerbatimDocShape() async throws {
        // Fixture column_detail_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/columns.md, section
        // "GET /:account_slug/boards/:board_id/columns/:column_id".
        // Note the wire `color` here is a bare CSS-variable string, unlike the
        // `{name, value}` object shape in cards.md — FizzyColor accepts both.
        let data = try loadFixture("column_detail_doc")
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/boards/B1/columns/C1")
            return (data, .ok(for: req))
        }

        let column = try await makeClient().column(boardID: "B1", columnID: "C1")
        #expect(column.id == "03f5v9zkft4hj9qq0lsn9ohcm")
        #expect(column.name == "In Progress")
        #expect(column.color.value == "var(--color-card-default)")
    }

    // MARK: - Column cards

    @Test("GET /:account/boards/:id/columns/:column_id/cards decodes the verbatim doc response")
    func columnCardsVerbatimDocShape() async throws {
        // Fixture column_cards_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/columns.md, section
        // "GET /:account_slug/boards/:board_id/columns/:column_id/cards".
        let data = try loadFixture("column_cards_doc")
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/boards/B1/columns/C1/cards")
            return (data, .ok(for: req))
        }

        let cards = try await makeClient().cards(boardID: "B1", columnID: "C1")
        #expect(cards.count == 1)
        let card = try #require(cards.first)
        #expect(card.id == "03f5vaeq985jlvwv3arl4srq2")
        #expect(card.number == 1)
        #expect(card.title == "First!")
        #expect(card.tags == ["programming"])
        #expect(card.closed == false)
        #expect(card.golden == false)
        #expect(card.column?.color.value == "var(--color-card-4)")
    }

    // MARK: - Create column

    @Test("POST /:account/boards/:id/columns sends {column:{…}}, follows Location")
    func createColumnFollowsLocation() async throws {
        let detail = try loadFixture("column_detail_doc")
        MockURLProtocol.handler = { req in
            if req.httpMethod == "POST" {
                #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/boards/B1/columns")
                let body = self.jsonBody(of: req)
                let column = body?["column"] as? [String: Any]
                #expect(column?["name"] as? String == "In Progress")
                #expect(column?["color"] as? String == "var(--color-card-4)")
                return (Data(), .response(
                    for: req, status: 201,
                    headers: ["Location": "https://fizzy.bluefenix.net/ACCT/boards/B1/columns/03f5v9zkft4hj9qq0lsn9ohcm"]
                ))
            }
            #expect(req.httpMethod == "GET")
            return (detail, .ok(for: req))
        }

        var write = FizzyColumnWrite(name: "In Progress")
        write.color = "var(--color-card-4)"
        let created = try await makeClient().createColumn(boardID: "B1", write)
        #expect(created.id == "03f5v9zkft4hj9qq0lsn9ohcm")
        #expect(MockURLProtocol.requests.count == 2)
    }

    // MARK: - Update column

    @Test("PUT /:account/boards/:id/columns/:column_id sends {column:{…}} and returns the column")
    func updateColumn() async throws {
        let detail = try loadFixture("column_detail_doc")
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "PUT")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/boards/B1/columns/C1")
            let body = self.jsonBody(of: req)
            let column = body?["column"] as? [String: Any]
            #expect(column?["name"] as? String == "Done")
            #expect(column?["color"] == nil)   // nil fields are omitted from the wire
            return (detail, .ok(for: req))
        }

        let updated = try await makeClient().updateColumn(boardID: "B1", columnID: "C1", with: FizzyColumnWrite(name: "Done"))
        #expect(updated.name == "In Progress")  // server-returned shape wins
    }

    // MARK: - Delete column

    @Test("DELETE /:account/boards/:id/columns/:column_id deletes the column (204)")
    func deleteColumn() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/boards/B1/columns/C1")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().deleteColumn(boardID: "B1", columnID: "C1")
        #expect(MockURLProtocol.requests.count == 1)
    }
}
