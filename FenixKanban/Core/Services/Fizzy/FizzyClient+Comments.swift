import Foundation

// Convenience methods for the Fizzy comment, reaction, and step endpoints.
// Wire shapes per fizzy docs/api/sections/comments.md, reactions.md, and
// steps.md. All routes are scoped by the integer card *number* (not the ULID
// id). Creates follow the `201 + Location` convention except reactions, which
// respond with a bare `201` (see `postCreated` in FizzyClient.swift).
extension FizzyClient {

    // MARK: - Comments

    /// `GET /:account/cards/:number/comments` — all comments on a card,
    /// oldest first. Paginated via `Link: rel="next"`.
    func comments(cardNumber: Int) async throws -> [FizzyComment] {
        try await getAllPages("/cards/\(cardNumber)/comments", as: [FizzyComment].self)
    }

    /// `GET /:account/cards/:number/comments/:comment_id` — a single comment.
    func comment(cardNumber: Int, id: String) async throws -> FizzyComment {
        try await get("/cards/\(cardNumber)/comments/\(id)", as: FizzyComment.self)
    }

    /// `POST /:account/cards/:number/comments` — create a comment. Responds
    /// `201 + Location`; the new comment is fetched and returned.
    /// `createdAt` optionally overrides the creation timestamp (e.g. imports).
    func createComment(cardNumber: Int, body: String, createdAt: Date? = nil) async throws -> FizzyComment {
        try await post(
            "/cards/\(cardNumber)/comments",
            body: FizzyCommentWritePayload(comment: FizzyCommentWrite(body: body, createdAt: createdAt)),
            as: FizzyComment.self
        )
    }

    /// `PUT /:account/cards/:number/comments/:comment_id` — update a comment
    /// (creator only). Returns the updated comment.
    func updateComment(cardNumber: Int, id: String, body: String) async throws -> FizzyComment {
        try await put(
            "/cards/\(cardNumber)/comments/\(id)",
            body: FizzyCommentWritePayload(comment: FizzyCommentWrite(body: body)),
            as: FizzyComment.self
        )
    }

    /// `DELETE /:account/cards/:number/comments/:comment_id` — delete a
    /// comment (creator only).
    func deleteComment(cardNumber: Int, id: String) async throws {
        try await delete("/cards/\(cardNumber)/comments/\(id)")
    }

    // MARK: - Card reactions (boosts)

    /// `GET /:account/cards/:number/reactions` — reactions on a card.
    func cardReactions(cardNumber: Int) async throws -> [FizzyReaction] {
        try await getAllPages("/cards/\(cardNumber)/reactions", as: [FizzyReaction].self)
    }

    /// `POST /:account/cards/:number/reactions` — add a reaction (boost,
    /// max 16 characters) to a card. Responds bare `201`.
    func addCardReaction(cardNumber: Int, content: String) async throws {
        try await postCreated(
            "/cards/\(cardNumber)/reactions",
            body: FizzyReactionWritePayload(reaction: FizzyReactionWrite(content: content))
        )
    }

    /// `DELETE /:account/cards/:number/reactions/:reaction_id` — remove your
    /// own reaction from a card.
    func deleteCardReaction(cardNumber: Int, reactionID: String) async throws {
        try await delete("/cards/\(cardNumber)/reactions/\(reactionID)")
    }

    // MARK: - Comment reactions

    /// `GET /:account/cards/:number/comments/:comment_id/reactions` —
    /// reactions on a comment.
    func commentReactions(cardNumber: Int, commentID: String) async throws -> [FizzyReaction] {
        try await getAllPages(
            "/cards/\(cardNumber)/comments/\(commentID)/reactions",
            as: [FizzyReaction].self
        )
    }

    /// `POST /:account/cards/:number/comments/:comment_id/reactions` — add a
    /// reaction to a comment. Responds bare `201`.
    func addCommentReaction(cardNumber: Int, commentID: String, content: String) async throws {
        try await postCreated(
            "/cards/\(cardNumber)/comments/\(commentID)/reactions",
            body: FizzyReactionWritePayload(reaction: FizzyReactionWrite(content: content))
        )
    }

    /// `DELETE /:account/cards/:number/comments/:comment_id/reactions/:reaction_id`
    /// — remove your own reaction from a comment.
    func deleteCommentReaction(cardNumber: Int, commentID: String, reactionID: String) async throws {
        try await delete("/cards/\(cardNumber)/comments/\(commentID)/reactions/\(reactionID)")
    }

    // MARK: - Steps

    /// `GET /:account/cards/:number/steps/:step_id` — a single step.
    func step(cardNumber: Int, id: String) async throws -> FizzyStep {
        try await get("/cards/\(cardNumber)/steps/\(id)", as: FizzyStep.self)
    }

    /// `POST /:account/cards/:number/steps` — create a step. Responds
    /// `201 + Location`; the new step is fetched and returned.
    func createStep(cardNumber: Int, content: String, completed: Bool? = nil) async throws -> FizzyStep {
        try await post(
            "/cards/\(cardNumber)/steps",
            body: FizzyStepWritePayload(step: FizzyStepWrite(content: content, completed: completed)),
            as: FizzyStep.self
        )
    }

    /// `PUT /:account/cards/:number/steps/:step_id` — update a step. Both
    /// fields optional; nil fields are omitted from the request body.
    /// Returns the updated step.
    func updateStep(
        cardNumber: Int,
        id: String,
        content: String? = nil,
        completed: Bool? = nil
    ) async throws -> FizzyStep {
        try await put(
            "/cards/\(cardNumber)/steps/\(id)",
            body: FizzyStepWritePayload(step: FizzyStepWrite(content: content, completed: completed)),
            as: FizzyStep.self
        )
    }

    /// `DELETE /:account/cards/:number/steps/:step_id` — delete a step.
    func deleteStep(cardNumber: Int, id: String) async throws {
        try await delete("/cards/\(cardNumber)/steps/\(id)")
    }
}
