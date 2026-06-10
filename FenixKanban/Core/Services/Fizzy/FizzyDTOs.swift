import Foundation

// Codable mirror of the Fizzy API wire shapes. Field names use Swift
// camelCase; JSON keys are mapped explicitly via `CodingKeys` rather than a
// global keyDecodingStrategy, because some Fizzy keys (`description_html`,
// `image_url`) don't survive the round-trip cleanly under .convertFromSnakeCase
// (the encoder writes `descriptionHtml` back, losing the original snake form).
// Explicit keys also document the wire contract in-source.

// MARK: - Identity

struct FizzyIdentity: Codable, Equatable {
    let accounts: [FizzyAccount]
}

struct FizzyAccount: Codable, Equatable {
    let id: String
    let name: String
    let slug: String              // e.g. "/897362094"
    let createdAt: Date
    let user: FizzyUser

    enum CodingKeys: String, CodingKey {
        case id, name, slug, user
        case createdAt = "created_at"
    }
}

struct FizzyUser: Codable, Equatable {
    let id: String
    let name: String
    let role: String
    let active: Bool
    let emailAddress: String
    let createdAt: Date
    let url: URL?

    enum CodingKeys: String, CodingKey {
        case id, name, role, active, url
        case emailAddress = "email_address"
        case createdAt = "created_at"
    }
}

// MARK: - Board

struct FizzyBoard: Codable, Equatable {
    let id: String
    let name: String
    let allAccess: Bool
    let createdAt: Date
    let autoPostponePeriodInDays: Int
    let url: URL?
    let creator: FizzyUser

    enum CodingKeys: String, CodingKey {
        case id, name, url, creator
        case allAccess = "all_access"
        case createdAt = "created_at"
        case autoPostponePeriodInDays = "auto_postpone_period_in_days"
    }
}

// MARK: - Column

struct FizzyColumn: Codable, Equatable {
    let id: String
    let name: String
    let color: FizzyColor
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case createdAt = "created_at"
    }
}

/// Column color. The wire shape differs between docs/endpoints: cards.md
/// nests `{ "name": "Lime", "value": "var(--color-card-4)" }`, while
/// columns.md sends the bare CSS-variable string `"var(--color-card-4)"`.
/// Decoding accepts both (bare strings get `name == ""`); encoding always
/// writes the object form.
struct FizzyColor: Codable, Equatable {
    let name: String
    let value: String

    init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let raw = try? single.decode(String.self) {
            self.name = ""
            self.value = raw
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try container.decode(String.self, forKey: .name)
            self.value = try container.decode(String.self, forKey: .value)
        }
    }
}

// MARK: - Card

struct FizzyCard: Codable, Equatable {
    let id: String
    let number: Int
    let title: String
    let status: String
    let description: String?
    let descriptionHTML: String?
    let imageURL: URL?
    let hasAttachments: Bool
    let tags: [String]
    let closed: Bool?           // present only on single-card endpoint
    let golden: Bool
    let lastActiveAt: Date
    let createdAt: Date
    let url: URL?
    let column: FizzyColumn?    // present only on single-card endpoint per Fizzy docs
    let steps: [FizzyStep]?     // present only on single-card endpoint

    enum CodingKeys: String, CodingKey {
        case id, number, title, status, description, tags, closed, golden, url, column, steps
        case descriptionHTML = "description_html"
        case imageURL = "image_url"
        case hasAttachments = "has_attachments"
        case lastActiveAt = "last_active_at"
        case createdAt = "created_at"
    }
}

struct FizzyStep: Codable, Equatable, Identifiable {
    let id: String
    let content: String
    let completed: Bool
}

// MARK: - Card write payload

/// Body for POST /:account/boards/:board_id/cards and PUT /:account/cards/:n.
/// Wire shape is `{ "card": { ... } }` — see `FizzyCardWritePayload`.
struct FizzyCardWrite: Codable, Equatable {
    var title: String?
    var description: String?
    var status: String?         // "published" | "drafted"
    var tagIds: [String]?

    enum CodingKeys: String, CodingKey {
        case title, description, status
        case tagIds = "tag_ids"
    }
}

/// Wrapper: Fizzy expects `{ "card": <FizzyCardWrite> }` for create/update.
struct FizzyCardWritePayload: Codable, Equatable {
    let card: FizzyCardWrite
}
