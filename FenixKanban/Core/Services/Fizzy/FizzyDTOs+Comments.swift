import Foundation

// Wire shapes for the Fizzy comment, reaction, and step endpoints.
// Per fizzy docs/api/sections/comments.md, reactions.md, and steps.md.
// Unlike the flat card-action payloads (FizzyDTOs+CardActions.swift), these
// request bodies are wrapped: `{ "comment": { … } }`, `{ "reaction": { … } }`,
// `{ "step": { … } }`. The `FizzyStep` response DTO lives in FizzyDTOs.swift
// (it is shared with the single-card endpoint).

// MARK: - Comment

struct FizzyComment: Codable, Equatable {
    let id: String
    let createdAt: Date
    let updatedAt: Date
    let body: FizzyCommentBody
    let creator: FizzyUser
    let card: FizzyCardRef
    let reactionsURL: URL?
    let url: URL?

    enum CodingKeys: String, CodingKey {
        case id, body, creator, card, url
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case reactionsURL = "reactions_url"
    }
}

/// Rich-text comment body — Fizzy sends both renditions.
struct FizzyCommentBody: Codable, Equatable {
    let plainText: String
    let html: String

    enum CodingKeys: String, CodingKey {
        case html
        case plainText = "plain_text"
    }
}

/// Minimal card reference embedded in a comment (`{ "id": …, "url": … }`).
struct FizzyCardRef: Codable, Equatable {
    let id: String
    let url: URL?
}

// MARK: - Comment write payload

/// Body fields for POST/PUT comment endpoints. `createdAt` is the optional
/// creation-timestamp override (POST only); nil fields are omitted on the wire.
struct FizzyCommentWrite: Codable, Equatable {
    var body: String
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case body
        case createdAt = "created_at"
    }
}

/// Wrapper: Fizzy expects `{ "comment": <FizzyCommentWrite> }`.
struct FizzyCommentWritePayload: Codable, Equatable {
    let comment: FizzyCommentWrite
}

// MARK: - Reaction

/// A reaction — on a card ("boost") or on a comment; both wire shapes are
/// identical per docs/api/sections/reactions.md. Content is ≤ 16 characters.
struct FizzyReaction: Codable, Equatable {
    let id: String
    let content: String
    let reacter: FizzyUser
    let url: URL?
}

// MARK: - Reaction write payload

struct FizzyReactionWrite: Codable, Equatable {
    let content: String
}

/// Wrapper: Fizzy expects `{ "reaction": <FizzyReactionWrite> }`.
struct FizzyReactionWritePayload: Codable, Equatable {
    let reaction: FizzyReactionWrite
}

// MARK: - Step write payload

/// Body fields for POST/PUT step endpoints. Both fields are optional on PUT
/// (send only what changes); POST requires `content`. Nil fields are omitted
/// on the wire — steps.md's PUT example sends `{ "step": { "completed": true } }`
/// with no `content` key.
struct FizzyStepWrite: Codable, Equatable {
    var content: String?
    var completed: Bool?
}

/// Wrapper: Fizzy expects `{ "step": <FizzyStepWrite> }`.
struct FizzyStepWritePayload: Codable, Equatable {
    let step: FizzyStepWrite
}
