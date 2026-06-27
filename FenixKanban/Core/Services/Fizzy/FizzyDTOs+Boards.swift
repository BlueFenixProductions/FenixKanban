import Foundation

// DTOs for the Fizzy board + column endpoints (Batch 2).
// Wire shapes per fizzy docs/api/sections/boards.md and columns.md.
// `FizzyBoard` (list shape) and `FizzyColumn` stay untouched in FizzyDTOs.swift
// because the sync engine depends on them; the detail-only fields live here.

// MARK: - Board detail

/// Single-board shape returned by `GET/PUT /:account/boards/:board_id` and
/// `POST /:account/boards/:board_id/publication`. Superset of `FizzyBoard`:
/// `public_description`, `public_description_html`, and `public_url` appear
/// only when the board is published; `user_ids` only when `all_access` is
/// false — all optional here.
struct FizzyBoardDetail: Codable, Equatable {
    let id: String
    let name: String
    let allAccess: Bool
    let createdAt: Date
    let autoPostponePeriodInDays: Int
    let url: URL?
    let creator: FizzyUser
    let publicDescription: String?
    let publicDescriptionHTML: String?
    let userIds: [String]?
    let publicURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, name, url, creator
        case allAccess = "all_access"
        case createdAt = "created_at"
        case autoPostponePeriodInDays = "auto_postpone_period_in_days"
        case publicDescription = "public_description"
        case publicDescriptionHTML = "public_description_html"
        case userIds = "user_ids"
        case publicURL = "public_url"
    }
}

// MARK: - Board write payload

/// Body fields for POST /:account/boards and PUT /:account/boards/:id.
/// All optional — nil fields are omitted from the wire.
struct FizzyBoardWrite: Codable, Equatable {
    var name: String?
    var allAccess: Bool?
    var autoPostponePeriodInDays: Int?
    var publicDescription: String?
    var userIds: [String]?

    init(name: String? = nil) {
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case name
        case allAccess = "all_access"
        case autoPostponePeriodInDays = "auto_postpone_period_in_days"
        case publicDescription = "public_description"
        case userIds = "user_ids"
    }
}

/// Wrapper: Fizzy expects `{ "board": <FizzyBoardWrite> }`.
struct FizzyBoardWritePayload: Codable, Equatable {
    let board: FizzyBoardWrite
}

// MARK: - Board accesses

/// Envelope returned by `GET /:account/boards/:board_id/accesses`. The `users`
/// array is paginated via the `Link: rel="next"` header; `FizzyClient`
/// accumulates all pages before returning.
struct FizzyBoardAccesses: Codable, Equatable {
    let boardId: String
    let allAccess: Bool
    let users: [FizzyBoardAccessUser]

    enum CodingKeys: String, CodingKey {
        case users
        case boardId = "board_id"
        case allAccess = "all_access"
    }
}

/// User record in the accesses envelope: the standard user shape plus
/// `avatar_url`, `has_access`, and `involvement` ("watching", "access_only",
/// or null when the user has no access).
struct FizzyBoardAccessUser: Codable, Equatable {
    let id: String
    let name: String
    let role: String
    let active: Bool
    let emailAddress: String
    let createdAt: Date
    let url: URL?
    let avatarURL: URL?
    let hasAccess: Bool
    let involvement: String?

    enum CodingKeys: String, CodingKey {
        case id, name, role, active, url, involvement
        case emailAddress = "email_address"
        case createdAt = "created_at"
        case avatarURL = "avatar_url"
        case hasAccess = "has_access"
    }
}

// MARK: - Column write payload

/// Body fields for POST /:account/boards/:id/columns and
/// PUT /:account/boards/:id/columns/:column_id. Nil fields are omitted.
struct FizzyColumnWrite: Codable, Equatable {
    var name: String?
    var color: String?      // CSS variable, e.g. "var(--color-card-4)"

    init(name: String? = nil) {
        self.name = name
    }
}

/// Wrapper: Fizzy expects `{ "column": <FizzyColumnWrite> }`.
struct FizzyColumnWritePayload: Codable, Equatable {
    let column: FizzyColumnWrite
}
