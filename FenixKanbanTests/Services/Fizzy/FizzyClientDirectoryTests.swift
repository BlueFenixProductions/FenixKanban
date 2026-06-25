import Testing
import Foundation
@testable import FenixKanban

// Tests for the FizzyClient directory-style convenience methods: tags, users,
// identity, notifications, and activities. Wire shapes per fizzy
// docs/api/sections/tags.md, users.md, identity.md, notifications.md, and
// activities.md.

private final class FixtureLocatorDirectory {}

@Suite("FizzyClient — tags, users, identity, notifications & activities")
struct FizzyClientDirectoryTests {

    let mock = MockHTTPState()

    private func makeClient() -> FizzyClient {
        let session = mock.makeSession()
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: session,
            clock: ImmediateClock()
        )
    }

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: FixtureLocatorDirectory.self)
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

    /// Decodes the request's JSON body as a nested object (URLProtocol
    /// exposes the body as a stream).
    private func jsonObject(of request: URLRequest) -> [String: Any]? {
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

    // MARK: - Tags

    @Test("GET /:account/tags decodes the verbatim doc response")
    func tagsListVerbatimDocShape() async throws {
        // Fixture tags_list_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/tags.md, section "GET /:account_slug/tags".
        let data = try loadFixture("tags_list_doc")
        mock.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/tags")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer t")
            return (data, .ok(for: req))
        }

        let tags = try await makeClient().tags()
        #expect(tags.count == 2)
        let first = try #require(tags.first)
        #expect(first.id == "03f5v9zo9qlcwwpyc0ascnikz")
        #expect(first.title == "bug")
        #expect(first.url?.absoluteString.contains("tag_ids") == true)
        #expect(tags.last?.title == "feature")
    }

    @Test("GET /tags follows Link rel=\"next\" pagination")
    func tagsListPaginates() async throws {
        let data = try loadFixture("tags_list_doc")
        mock.handler = { req in
            if req.url?.query == nil {
                let headers = ["Link": "<https://fizzy.bluefenix.net/ACCT/tags?page=2>; rel=\"next\""]
                return (data, .ok(for: req, headers: headers))
            }
            #expect(req.url?.query == "page=2")
            return (data, .ok(for: req))
        }

        let tags = try await makeClient().tags()
        #expect(tags.count == 4)
        #expect(mock.requests.count == 2)
    }

    // MARK: - Users

    @Test("GET /:account/users decodes the verbatim doc response")
    func usersListVerbatimDocShape() async throws {
        // Fixture users_list_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/users.md, section "GET /:account_slug/users".
        let data = try loadFixture("users_list_doc")
        mock.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/users")
            return (data, .ok(for: req))
        }

        let users = try await makeClient().users()
        #expect(users.count == 4)
        let first = try #require(users.first)
        #expect(first.id == "03f5v9zjw7pz8717a4no1h8a7")
        #expect(first.name == "David Heinemeier Hansson")
        #expect(first.role == "owner")
        #expect(first.active == true)
        #expect(first.emailAddress == "david@example.com")
        #expect(users.last?.name == "Kevin Mcconnell")
    }

    @Test("GET /:account/users/:id decodes the verbatim doc response")
    func userDetailVerbatimDocShape() async throws {
        // Fixture user_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/users.md, section "GET /:account_slug/users/:user_id".
        let data = try loadFixture("user_doc")
        mock.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/users/03f5v9zjw7pz8717a4no1h8a7")
            return (data, .ok(for: req))
        }

        let user = try await makeClient().user(id: "03f5v9zjw7pz8717a4no1h8a7")
        #expect(user.id == "03f5v9zjw7pz8717a4no1h8a7")
        #expect(user.role == "owner")
        #expect(user.url?.absoluteString == "http://app.fizzy.localhost:3006/897362094/users/03f5v9zjw7pz8717a4no1h8a7")
    }

    @Test("user endpoints surface HTTP errors as FizzyError")
    func userErrorMapping() async throws {
        mock.handler = { req in (Data(), .response(for: req, status: 404)) }
        await #expect(throws: FizzyError.notFound) {
            try await makeClient().user(id: "missing")
        }
    }

    // MARK: - Identity

    @Test("GET /my/identity skips the account slug and decodes the verbatim doc response")
    func identityVerbatimDocShape() async throws {
        // Fixture identity_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/identity.md, section "GET /my/identity".
        let data = try loadFixture("identity_doc")
        mock.handler = { req in
            #expect(req.httpMethod == "GET")
            // `/my/...` paths are NOT account-scoped — no /ACCT prefix.
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/my/identity")
            return (data, .ok(for: req))
        }

        let identity = try await makeClient().identity()
        #expect(identity.accounts.count == 2)
        let first = try #require(identity.accounts.first)
        #expect(first.name == "37signals")
        #expect(first.slug == "/897362094")
        #expect(first.user.role == "owner")
        #expect(identity.accounts.last?.name == "Honcho")
    }

    @Test("PATCH /:account/my/timezone sends timezone_name and accepts 204")
    func updateTimezone() async throws {
        // Per identity.md "PATCH /:account_slug/my/timezone" — this /my/ path
        // IS account-scoped (like /my/pins), and the body is flat (unwrapped).
        let body = LockedBox<[String: Any]?>(nil)
        mock.handler = { req in
            #expect(req.httpMethod == "PATCH")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/my/timezone")
            #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
            body.value = self.jsonObject(of: req)
            return (Data(), .response(for: req, status: 204))
        }

        try await makeClient().updateTimezone("America/New_York")
        #expect(body.value as? [String: String] == ["timezone_name": "America/New_York"])
        #expect(mock.requests.count == 1)
    }

    // MARK: - Notifications

    @Test("GET /:account/notifications decodes the verbatim doc response")
    func notificationsListVerbatimDocShape() async throws {
        // Fixture notifications_list_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/notifications.md, section
        // "GET /:account_slug/notifications".
        let data = try loadFixture("notifications_list_doc")
        mock.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/notifications")
            return (data, .ok(for: req))
        }

        let notifications = try await makeClient().notifications()
        #expect(notifications.count == 1)
        let notification = try #require(notifications.first)
        #expect(notification.id == "03f5va03bpuvkcjemcxl73ho2")
        #expect(notification.read == false)
        #expect(notification.readAt == nil)
        #expect(notification.title == "Plain text mentions")
        #expect(notification.body == "Assigned to self")
        #expect(notification.creator.name == "David Heinemeier Hansson")
        let card = try #require(notification.card)
        #expect(card.id == "03f5v9zo9qlcwwpyc0ascnikz")
        #expect(card.status == "published")
        #expect(notification.url?.absoluteString == "http://app.fizzy.localhost:3006/897362094/notifications/03f5va03bpuvkcjemcxl73ho2")
    }

    @Test("POST /notifications/:id/reading marks a notification read (204)")
    func markNotificationRead() async throws {
        mock.handler = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/notifications/03f5va03bpuvkcjemcxl73ho2/reading")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().markNotificationRead(id: "03f5va03bpuvkcjemcxl73ho2")
        #expect(mock.requests.count == 1)
    }

    @Test("DELETE /notifications/:id/reading marks a notification unread (204)")
    func markNotificationUnread() async throws {
        mock.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/notifications/03f5va03bpuvkcjemcxl73ho2/reading")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().markNotificationUnread(id: "03f5va03bpuvkcjemcxl73ho2")
        #expect(mock.requests.count == 1)
    }

    @Test("POST /notifications/bulk_reading marks all notifications read (204)")
    func markAllNotificationsRead() async throws {
        mock.handler = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/notifications/bulk_reading")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().markAllNotificationsRead()
        #expect(mock.requests.count == 1)
    }

    @Test("GET /notifications/settings decodes the verbatim doc response")
    func notificationSettingsVerbatimDocShape() async throws {
        // Fixture notification_settings_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/notifications.md, section
        // "GET /:account_slug/notifications/settings".
        let data = try loadFixture("notification_settings_doc")
        mock.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/notifications/settings")
            return (data, .ok(for: req))
        }

        let settings = try await makeClient().notificationSettings()
        #expect(settings.bundleEmailFrequency == "every_few_hours")
    }

    @Test("PUT /notifications/settings sends wrapped user_settings body and accepts 204")
    func updateNotificationSettings() async throws {
        let body = LockedBox<[String: Any]?>(nil)
        mock.handler = { req in
            #expect(req.httpMethod == "PUT")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/notifications/settings")
            body.value = self.jsonObject(of: req)
            return (Data(), .response(for: req, status: 204))
        }

        try await makeClient().updateNotificationSettings(bundleEmailFrequency: "daily")
        #expect(body.value?["user_settings"] as? [String: String] == ["bundle_email_frequency": "daily"])
        #expect(mock.requests.count == 1)
    }

    // MARK: - Activities

    @Test("GET /:account/activities decodes the verbatim doc response")
    func activitiesListVerbatimDocShape() async throws {
        // Fixture activities_list_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/activities.md, section "GET /:account_slug/activities".
        let data = try loadFixture("activities_list_doc")
        mock.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/activities")
            return (data, .ok(for: req))
        }

        let activities = try await makeClient().activities()
        #expect(activities.count == 2)

        let cardActivity = try #require(activities.first)
        #expect(cardActivity.id == "03faevt004")
        #expect(cardActivity.action == "card_closed")
        #expect(cardActivity.eventableType == "Card")
        #expect(cardActivity.description == "David Heinemeier Hansson moved \"Fix mobile login\" to \"Done\"")
        let card = try #require(cardActivity.card)
        #expect(card.number == 42)
        #expect(card.tags == ["ios", "auth"])
        #expect(card.closed == true)
        #expect(cardActivity.comment == nil)
        #expect(cardActivity.board?.name == "Mobile")
        #expect(cardActivity.board?.allAccess == true)
        #expect(cardActivity.creator.name == "David Heinemeier Hansson")
        #expect(cardActivity.particulars == FizzyActivityParticulars())

        let commentActivity = try #require(activities.last)
        #expect(commentActivity.action == "comment_created")
        #expect(commentActivity.eventableType == "Comment")
        let comment = try #require(commentActivity.comment)
        #expect(comment.id == "03facomment9")
        #expect(comment.body.plainText == "I found the regression in the callback flow.")
        #expect(comment.card.id == "03f6card042")
        #expect(commentActivity.card == nil)
    }

    @Test("GET /activities sends creator_ids[] and board_ids[] filters")
    func activitiesFilterQuery() async throws {
        let data = Data("[]".utf8)
        mock.handler = { req in
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/activities?creator_ids%5B%5D=A&board_ids%5B%5D=X")
            return (data, .ok(for: req))
        }

        let activities = try await makeClient().activities(creatorIDs: ["A"], boardIDs: ["X"])
        #expect(activities.isEmpty)
        #expect(mock.requests.count == 1)
    }

    @Test("GET /activities follows Link rel=\"next\" pagination")
    func activitiesPaginate() async throws {
        let data = try loadFixture("activities_list_doc")
        mock.handler = { req in
            if req.url?.query == nil {
                let headers = ["Link": "<https://fizzy.bluefenix.net/ACCT/activities?page=2>; rel=\"next\""]
                return (data, .ok(for: req, headers: headers))
            }
            #expect(req.url?.query == "page=2")
            return (data, .ok(for: req))
        }

        let activities = try await makeClient().activities()
        #expect(activities.count == 4)
        #expect(mock.requests.count == 2)
    }

    @Test("activity particulars decode action-specific keys and ignore unknown ones")
    func activityParticularsDecoding() async throws {
        // Shapes per activities.md "__`particulars` examples__" table.
        let decoder = JSONDecoder()

        let assigned = try decoder.decode(
            FizzyActivityParticulars.self,
            from: Data(#"{ "assignee_ids": ["03f5user123"] }"#.utf8)
        )
        #expect(assigned.assigneeIds == ["03f5user123"])

        let boardChanged = try decoder.decode(
            FizzyActivityParticulars.self,
            from: Data(#"{ "old_board": "Backlog", "new_board": "Mobile" }"#.utf8)
        )
        #expect(boardChanged.oldBoard == "Backlog")
        #expect(boardChanged.newBoard == "Mobile")

        let titleChanged = try decoder.decode(
            FizzyActivityParticulars.self,
            from: Data(#"{ "old_title": "Fix login", "new_title": "Fix mobile login" }"#.utf8)
        )
        #expect(titleChanged.oldTitle == "Fix login")
        #expect(titleChanged.newTitle == "Fix mobile login")

        let triaged = try decoder.decode(
            FizzyActivityParticulars.self,
            from: Data(#"{ "column": "In Progress", "future_unknown_key": 42 }"#.utf8)
        )
        #expect(triaged.column == "In Progress")
    }

    @Test("activity with unknown eventable_type decodes conservatively")
    func activityUnknownEventableType() async throws {
        // activities.md: "Clients should handle unknown future values
        // conservatively." Unknown eventable types must not fail decoding.
        let json = Data("""
        [
          {
            "id": "03faevt999",
            "action": "card_closed",
            "created_at": "2026-03-25T15:11:04.000Z",
            "description": "Something new happened",
            "particulars": {},
            "url": "http://app.fizzy.localhost:3006/897362094/cards/42",
            "eventable_type": "FutureThing",
            "eventable": { "id": "x", "brand_new_shape": true },
            "board": null,
            "creator": {
              "id": "03f5user123",
              "name": "David Heinemeier Hansson",
              "role": "owner",
              "active": true,
              "email_address": "david@example.com",
              "created_at": "2026-03-01T09:00:00.000Z",
              "url": "http://app.fizzy.localhost:3006/897362094/users/03f5user123"
            }
          }
        ]
        """.utf8)
        mock.handler = { req in (json, .ok(for: req)) }

        let activities = try await makeClient().activities()
        #expect(activities.count == 1)
        let activity = try #require(activities.first)
        #expect(activity.eventableType == "FutureThing")
        #expect(activity.card == nil)
        #expect(activity.comment == nil)
        #expect(activity.board == nil)
    }
}

/// Tiny reference box so the MockURLProtocol handler (a sync closure) can
/// pass captured request data back to the async test body.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
