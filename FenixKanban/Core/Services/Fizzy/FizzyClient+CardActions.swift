import Foundation

// Convenience methods for the Fizzy card-action endpoints.
// Wire shapes per fizzy docs/api/sections/cards.md and pins.md. All action
// endpoints respond `204 No Content`; card detail and board-move return the
// full single-card shape (decoded as `FizzyCard`, which carries the
// detail-only `closed`/`column`/`steps` fields as optionals).
extension FizzyClient {

    // MARK: - Card detail / delete

    /// `GET /:account/cards/:number` — fetch a single card by number.
    func card(number: Int) async throws -> FizzyCard {
        try await get("/cards/\(number)", as: FizzyCard.self)
    }

    /// `DELETE /:account/cards/:number` — delete a card (creator/admin only).
    func deleteCard(number: Int) async throws {
        try await delete("/cards/\(number)")
    }

    // MARK: - Closure

    /// `POST /:account/cards/:number/closure` — close a card.
    func closeCard(number: Int) async throws {
        try await postNoContent("/cards/\(number)/closure")
    }

    /// `DELETE /:account/cards/:number/closure` — reopen a closed card.
    func reopenCard(number: Int) async throws {
        try await delete("/cards/\(number)/closure")
    }

    // MARK: - Not now

    /// `POST /:account/cards/:number/not_now` — move a card to "Not Now".
    func postponeCard(number: Int) async throws {
        try await postNoContent("/cards/\(number)/not_now")
    }

    // MARK: - Triage

    /// `POST /:account/cards/:number/triage` — move a card into a column.
    func triageCard(number: Int, columnID: String) async throws {
        try await postNoContent("/cards/\(number)/triage", body: FizzyTriagePayload(columnId: columnID))
    }

    /// `DELETE /:account/cards/:number/triage` — send a card back to triage.
    func untriageCard(number: Int) async throws {
        try await delete("/cards/\(number)/triage")
    }

    // MARK: - Move to board

    /// `PUT /:account/cards/:number/board` — move a card to another board.
    /// Returns the moved card (same shape as card detail).
    func moveCard(number: Int, toBoardID boardID: String) async throws -> FizzyCard {
        try await put("/cards/\(number)/board", body: FizzyBoardMovePayload(boardId: boardID), as: FizzyCard.self)
    }

    // MARK: - Watch

    /// `POST /:account/cards/:number/watch` — subscribe to card notifications.
    func watchCard(number: Int) async throws {
        try await postNoContent("/cards/\(number)/watch")
    }

    /// `DELETE /:account/cards/:number/watch` — unsubscribe from card notifications.
    func unwatchCard(number: Int) async throws {
        try await delete("/cards/\(number)/watch")
    }

    // MARK: - Goldness

    /// `POST /:account/cards/:number/goldness` — mark a card as golden.
    func markCardGolden(number: Int) async throws {
        try await postNoContent("/cards/\(number)/goldness")
    }

    /// `DELETE /:account/cards/:number/goldness` — remove golden status.
    func unmarkCardGolden(number: Int) async throws {
        try await delete("/cards/\(number)/goldness")
    }

    // MARK: - Pins

    /// `POST /:account/cards/:number/pin` — pin a card for the current user.
    func pinCard(number: Int) async throws {
        try await postNoContent("/cards/\(number)/pin")
    }

    /// `DELETE /:account/cards/:number/pin` — unpin a card for the current user.
    func unpinCard(number: Int) async throws {
        try await delete("/cards/\(number)/pin")
    }

    /// `GET /:account/my/pins` — the current user's pinned cards (not
    /// paginated; up to 100 cards). Account-scoped despite the `/my/` prefix.
    func myPins() async throws -> [FizzyCard] {
        try await getAccountScoped(myPath: "/my/pins", as: [FizzyCard].self)
    }

    // MARK: - Taggings

    /// `POST /:account/cards/:number/taggings` — toggle a tag on/off (creates
    /// the tag if it doesn't exist; leading `#` is stripped server-side).
    func toggleCardTag(number: Int, tagTitle: String) async throws {
        try await postNoContent("/cards/\(number)/taggings", body: FizzyTaggingPayload(tagTitle: tagTitle))
    }

    // MARK: - Assignments

    /// `POST /:account/cards/:number/assignments` — toggle a user assignment.
    func toggleCardAssignment(number: Int, assigneeID: String) async throws {
        try await postNoContent("/cards/\(number)/assignments", body: FizzyAssignmentPayload(assigneeId: assigneeID))
    }

    // MARK: - Image

    /// `DELETE /:account/cards/:number/image` — remove the card header image.
    func deleteCardImage(number: Int) async throws {
        try await delete("/cards/\(number)/image")
    }
}
