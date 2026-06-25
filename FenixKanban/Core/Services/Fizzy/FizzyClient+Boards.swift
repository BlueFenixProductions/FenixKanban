import Foundation

// Convenience methods for the Fizzy board + column endpoints (Batch 2).
// Wire shapes per fizzy docs/api/sections/boards.md and columns.md.
// POST /boards and POST /columns follow the 201 + Location convention;
// POST /publication returns 201 with the board in the body; DELETEs are 204.
extension FizzyClient {

    // MARK: - Boards

    /// `GET /:account/boards` — all boards the user can access (paginated).
    func boards() async throws -> [FizzyBoard] {
        try await getAllPages("/boards", as: [FizzyBoard].self)
    }

    /// `GET /:account/boards/:id` — a single board, including publication
    /// fields (`public_*`) and `user_ids` when present.
    func board(id: String) async throws -> FizzyBoardDetail {
        try await get("/boards/\(id)", as: FizzyBoardDetail.self)
    }

    /// `POST /:account/boards` — create a board. Follows the 201 Location to
    /// return the full new board.
    func createBoard(_ board: FizzyBoardWrite) async throws -> FizzyBoardDetail {
        try await post("/boards", body: FizzyBoardWritePayload(board: board), as: FizzyBoardDetail.self)
    }

    /// `PUT /:account/boards/:id` — update a board (admins only). Returns the
    /// updated board, or nil when the server answers `204 No Content` — which
    /// it does if the update removed the requesting user's own access.
    func updateBoard(id: String, with board: FizzyBoardWrite) async throws -> FizzyBoardDetail? {
        do {
            return try await put("/boards/\(id)", body: FizzyBoardWritePayload(board: board), as: FizzyBoardDetail.self)
        } catch FizzyError.unexpectedStatus(204) {
            return nil
        }
    }

    /// `DELETE /:account/boards/:id` — delete a board (admins only).
    func deleteBoard(id: String) async throws {
        try await delete("/boards/\(id)")
    }

    // MARK: - Board accesses

    /// `GET /:account/boards/:id/accesses` — who can access the board and
    /// their involvement. Follows `Link: rel="next"` pagination, merging the
    /// `users` arrays of all pages.
    func boardAccesses(boardID: String) async throws -> FizzyBoardAccesses {
        try await getAllEnvelopePages("/boards/\(boardID)/accesses", as: FizzyBoardAccesses.self) { merged, page in
            FizzyBoardAccesses(
                boardId: merged.boardId,
                allAccess: merged.allAccess,
                users: merged.users + page.users
            )
        }
    }

    // MARK: - Board publication

    /// `POST /:account/boards/:id/publication` — publish a board (admins
    /// only). Responds 201 with the board (including `public_url`) in the
    /// body; idempotent — re-publishing returns the existing publication.
    func publishBoard(id: String) async throws -> FizzyBoardDetail {
        try await postExpectingBody("/boards/\(id)/publication", as: FizzyBoardDetail.self)
    }

    /// `DELETE /:account/boards/:id/publication` — unpublish a board.
    func unpublishBoard(id: String) async throws {
        try await delete("/boards/\(id)/publication")
    }

    // MARK: - Columns

    /// `GET /:account/boards/:id/columns/:column_id` — column metadata.
    func column(boardID: String, columnID: String) async throws -> FizzyColumn {
        try await get("/boards/\(boardID)/columns/\(columnID)", as: FizzyColumn.self)
    }

    /// `GET /:account/boards/:id/columns/:column_id/cards` — open cards
    /// triaged into the column (paginated; excludes Maybe/Not Now/Done).
    func cards(boardID: String, columnID: String) async throws -> [FizzyCard] {
        try await getAllPages("/boards/\(boardID)/columns/\(columnID)/cards", as: [FizzyCard].self)
    }

    /// `POST /:account/boards/:id/columns` — create a column. Follows the 201
    /// Location to return the full new column.
    func createColumn(boardID: String, _ column: FizzyColumnWrite) async throws -> FizzyColumn {
        try await post("/boards/\(boardID)/columns", body: FizzyColumnWritePayload(column: column), as: FizzyColumn.self)
    }

    /// `PUT /:account/boards/:id/columns/:column_id` — update a column.
    func updateColumn(boardID: String, columnID: String, with column: FizzyColumnWrite) async throws -> FizzyColumn {
        try await put("/boards/\(boardID)/columns/\(columnID)", body: FizzyColumnWritePayload(column: column), as: FizzyColumn.self)
    }

    /// `DELETE /:account/boards/:id/columns/:column_id` — delete a column.
    func deleteColumn(boardID: String, columnID: String) async throws {
        try await delete("/boards/\(boardID)/columns/\(columnID)")
    }
}
