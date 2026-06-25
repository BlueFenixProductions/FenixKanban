import Foundation

// Convenience methods for the Fizzy tag, user, identity, notification, and
// activity endpoints. Wire shapes per fizzy docs/api/sections/tags.md,
// users.md, identity.md, notifications.md, and activities.md. All list
// endpoints paginate via `Link: rel="next"`. Action endpoints (reading,
// bulk_reading, timezone, settings update) respond `204 No Content`.
extension FizzyClient {

    // MARK: - Tags

    /// `GET /:account/tags` — all tags in the account, sorted alphabetically.
    func tags() async throws -> [FizzyTag] {
        try await getAllPages("/tags", as: [FizzyTag].self)
    }

    // MARK: - Users

    /// `GET /:account/users` — active users in the account.
    func users() async throws -> [FizzyUser] {
        try await getAllPages("/users", as: [FizzyUser].self)
    }

    /// `GET /:account/users/:user_id` — a single user.
    func user(id: String) async throws -> FizzyUser {
        try await get("/users/\(id)", as: FizzyUser.self)
    }

    // MARK: - Identity

    /// `GET /my/identity` — the accounts this identity can access, with the
    /// per-account user. NOT account-scoped (`/my/identity` skips the slug).
    func identity() async throws -> FizzyIdentity {
        try await get("/my/identity", as: FizzyIdentity.self)
    }

    /// `PATCH /:account/my/timezone` — update the current user's timezone
    /// (IANA identifier, e.g. `America/New_York`). Account-scoped despite the
    /// `/my/` prefix (like `/my/pins`). Responds `204`.
    func updateTimezone(_ timezoneName: String) async throws {
        try await patchNoContent(
            accountScopedMyPath: "/my/timezone",
            body: FizzyTimezonePayload(timezoneName: timezoneName)
        )
    }

    // MARK: - Notifications

    /// `GET /:account/notifications` — the current user's notifications,
    /// unread first.
    func notifications() async throws -> [FizzyNotification] {
        try await getAllPages("/notifications", as: [FizzyNotification].self)
    }

    /// `POST /:account/notifications/:id/reading` — mark a notification read.
    func markNotificationRead(id: String) async throws {
        try await postNoContent("/notifications/\(id)/reading")
    }

    /// `DELETE /:account/notifications/:id/reading` — mark a notification
    /// unread.
    func markNotificationUnread(id: String) async throws {
        try await delete("/notifications/\(id)/reading")
    }

    /// `POST /:account/notifications/bulk_reading` — mark all unread
    /// notifications read.
    func markAllNotificationsRead() async throws {
        try await postNoContent("/notifications/bulk_reading")
    }

    /// `GET /:account/notifications/settings` — the current user's
    /// notification settings.
    func notificationSettings() async throws -> FizzyNotificationSettings {
        try await get("/notifications/settings", as: FizzyNotificationSettings.self)
    }

    /// `PUT /:account/notifications/settings` — update the current user's
    /// notification settings. `bundleEmailFrequency` is one of `never`,
    /// `every_few_hours`, `daily`, `weekly`. Responds `204`.
    func updateNotificationSettings(bundleEmailFrequency: String) async throws {
        try await putNoContent(
            "/notifications/settings",
            body: FizzyNotificationSettingsPayload(
                userSettings: FizzyNotificationSettings(bundleEmailFrequency: bundleEmailFrequency)
            )
        )
    }

    // MARK: - Activities

    /// `GET /:account/activities` — the account activity feed, newest first.
    /// Optional filters: `creatorIDs` (activities created by any of these
    /// users) and `boardIDs` (activities on any of these boards); the two
    /// filters are ANDed by the server. Brackets are pre-percent-encoded
    /// (`%5B%5D`) so the path survives `URL(string:)` round-trips intact.
    func activities(creatorIDs: [String] = [], boardIDs: [String] = []) async throws -> [FizzyActivity] {
        var query: [String] = []
        query += creatorIDs.map { "creator_ids%5B%5D=\($0)" }
        query += boardIDs.map { "board_ids%5B%5D=\($0)" }
        let path = query.isEmpty ? "/activities" : "/activities?" + query.joined(separator: "&")
        return try await getAllPages(path, as: [FizzyActivity].self)
    }
}
