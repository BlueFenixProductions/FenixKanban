import Foundation

// Request payloads for the Fizzy card-action endpoints.
// Wire shapes per fizzy docs/api/sections/cards.md — these bodies are flat
// (NOT wrapped in `{ "card": … }` like FizzyCardWritePayload).

// MARK: - Move card to board

/// Body for `PUT /:account/cards/:number/board`.
struct FizzyBoardMovePayload: Codable, Equatable {
    let boardId: String

    enum CodingKeys: String, CodingKey {
        case boardId = "board_id"
    }
}

// MARK: - Triage

/// Body for `POST /:account/cards/:number/triage`.
struct FizzyTriagePayload: Codable, Equatable {
    let columnId: String

    enum CodingKeys: String, CodingKey {
        case columnId = "column_id"
    }
}

// MARK: - Taggings

/// Body for `POST /:account/cards/:number/taggings` (toggles the tag; the
/// leading `#` is stripped server-side, and unknown tags are created).
struct FizzyTaggingPayload: Codable, Equatable {
    let tagTitle: String

    enum CodingKeys: String, CodingKey {
        case tagTitle = "tag_title"
    }
}

// MARK: - Assignments

/// Body for `POST /:account/cards/:number/assignments` (toggles assignment).
struct FizzyAssignmentPayload: Codable, Equatable {
    let assigneeId: String

    enum CodingKeys: String, CodingKey {
        case assigneeId = "assignee_id"
    }
}
