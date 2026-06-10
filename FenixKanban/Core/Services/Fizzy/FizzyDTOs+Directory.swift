import Foundation

// Wire shapes for the Fizzy tag, notification, and activity endpoints.
// Per fizzy docs/api/sections/tags.md, notifications.md, identity.md, and
// activities.md. User and identity response DTOs (`FizzyUser`,
// `FizzyIdentity`, `FizzyAccount`) live in FizzyDTOs.swift — they are shared
// with auth and board-access flows.

// MARK: - Tag

struct FizzyTag: Codable, Equatable {
    let id: String
    let title: String
    let createdAt: Date
    let url: URL?

    enum CodingKeys: String, CodingKey {
        case id, title, url
        case createdAt = "created_at"
    }
}

// MARK: - Timezone (identity.md)

/// Body for PATCH /:account/my/timezone. Flat (unwrapped) per identity.md.
struct FizzyTimezonePayload: Codable, Equatable {
    let timezoneName: String

    enum CodingKeys: String, CodingKey {
        case timezoneName = "timezone_name"
    }
}

// MARK: - Notification

struct FizzyNotification: Codable, Equatable {
    let id: String
    let read: Bool
    let readAt: Date?
    let createdAt: Date
    let title: String
    let body: String?
    let creator: FizzyUser
    let card: FizzyNotificationCard?
    let url: URL?

    enum CodingKeys: String, CodingKey {
        case id, read, title, body, creator, card, url
        case readAt = "read_at"
        case createdAt = "created_at"
    }
}

/// Minimal card reference embedded in a notification
/// (`{ "id": …, "title": …, "status": …, "url": … }`).
struct FizzyNotificationCard: Codable, Equatable {
    let id: String
    let title: String
    let status: String
    let url: URL?
}

// MARK: - Notification settings

struct FizzyNotificationSettings: Codable, Equatable {
    let bundleEmailFrequency: String

    enum CodingKeys: String, CodingKey {
        case bundleEmailFrequency = "bundle_email_frequency"
    }
}

/// Wrapper: Fizzy expects `{ "user_settings": { … } }` for the settings
/// update (notifications.md, PUT /:account_slug/notifications/settings).
struct FizzyNotificationSettingsPayload: Codable, Equatable {
    let userSettings: FizzyNotificationSettings

    enum CodingKeys: String, CodingKey {
        case userSettings = "user_settings"
    }
}

// MARK: - Activity

/// One entry in the account activity feed (activities.md). The polymorphic
/// `eventable` is split into typed optionals keyed off `eventable_type`:
/// `card` for `"Card"`, `comment` for `"Comment"`. Unknown future types
/// decode with both nil, per the doc's compatibility guidance.
struct FizzyActivity: Codable, Equatable {
    let id: String
    let action: String
    let createdAt: Date
    let description: String
    let particulars: FizzyActivityParticulars
    let url: URL?
    let eventableType: String
    let card: FizzyCard?
    let comment: FizzyComment?
    let board: FizzyActivityBoard?
    let creator: FizzyUser

    enum CodingKeys: String, CodingKey {
        case id, action, description, particulars, url, eventable, board, creator
        case createdAt = "created_at"
        case eventableType = "eventable_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        action = try container.decode(String.self, forKey: .action)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        description = try container.decode(String.self, forKey: .description)
        particulars = try container.decode(FizzyActivityParticulars.self, forKey: .particulars)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        eventableType = try container.decode(String.self, forKey: .eventableType)
        board = try container.decodeIfPresent(FizzyActivityBoard.self, forKey: .board)
        creator = try container.decode(FizzyUser.self, forKey: .creator)
        switch eventableType {
        case "Card":
            card = try container.decode(FizzyCard.self, forKey: .eventable)
            comment = nil
        case "Comment":
            comment = try container.decode(FizzyComment.self, forKey: .eventable)
            card = nil
        default:
            card = nil
            comment = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(action, forKey: .action)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(description, forKey: .description)
        try container.encode(particulars, forKey: .particulars)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encode(eventableType, forKey: .eventableType)
        try container.encodeIfPresent(board, forKey: .board)
        try container.encode(creator, forKey: .creator)
        if let card {
            try container.encode(card, forKey: .eventable)
        } else if let comment {
            try container.encode(comment, forKey: .eventable)
        }
    }
}

/// Action-specific activity metadata (activities.md "Supported actions"
/// table). All fields optional — each action populates its own subset, and
/// unknown future keys are ignored.
struct FizzyActivityParticulars: Codable, Equatable {
    let assigneeIds: [String]?
    let oldBoard: String?
    let newBoard: String?
    let oldTitle: String?
    let newTitle: String?
    let column: String?

    init(
        assigneeIds: [String]? = nil,
        oldBoard: String? = nil,
        newBoard: String? = nil,
        oldTitle: String? = nil,
        newTitle: String? = nil,
        column: String? = nil
    ) {
        self.assigneeIds = assigneeIds
        self.oldBoard = oldBoard
        self.newBoard = newBoard
        self.oldTitle = oldTitle
        self.newTitle = newTitle
        self.column = column
    }

    enum CodingKeys: String, CodingKey {
        case column
        case assigneeIds = "assignee_ids"
        case oldBoard = "old_board"
        case newBoard = "new_board"
        case oldTitle = "old_title"
        case newTitle = "new_title"
    }
}

/// Board reference embedded in an activity. Unlike `FizzyBoard` (boards
/// list endpoint) it carries no `creator`, so it gets its own DTO.
struct FizzyActivityBoard: Codable, Equatable {
    let id: String
    let name: String
    let allAccess: Bool
    let createdAt: Date
    let autoPostponePeriodInDays: Int
    let url: URL?

    enum CodingKeys: String, CodingKey {
        case id, name, url
        case allAccess = "all_access"
        case createdAt = "created_at"
        case autoPostponePeriodInDays = "auto_postpone_period_in_days"
    }
}
