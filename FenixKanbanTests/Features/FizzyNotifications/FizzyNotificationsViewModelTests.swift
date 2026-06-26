import Testing
import Foundation
@testable import FenixKanban

// MARK: - Helpers

/// Creates a minimal `FizzyNotification` value for test use.
private func makeNotification(
    id: String = UUID().uuidString,
    readAt: Date? = nil,
    createdAt: Date = Date()
) -> FizzyNotification {
    FizzyNotification(
        id: id,
        read: readAt != nil,
        readAt: readAt,
        createdAt: createdAt,
        title: "Test notification \(id)",
        body: nil,
        creator: FizzyUser(
            id: "u1",
            name: "Alice",
            role: "member",
            active: true,
            emailAddress: "alice@example.com",
            createdAt: Date(timeIntervalSince1970: 0),
            url: nil,
            avatarURL: nil
        ),
        card: nil,
        url: nil
    )
}

// MARK: - Suite

@Suite("FizzyNotificationsViewModel", .serialized)
@MainActor
struct FizzyNotificationsViewModelTests {

    let mock = MockHTTPState()

    private func makeClient() -> FizzyClient {
        FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: mock.makeSession(),
            clock: ImmediateClock()
        )
    }

    // MARK: (1) refreshPopulatesNotifications

    @Test("refresh populates notifications from server")
    func refreshPopulatesNotifications() async throws {
        let notifications = [
            makeNotification(id: "n1"),
            makeNotification(id: "n2"),
            makeNotification(id: "n3"),
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(notifications)

        mock.handler = { req in
            #expect(req.httpMethod == "GET")
            return (data, .ok(for: req))
        }

        let vm = FizzyNotificationsViewModel(client: makeClient())
        await vm.refresh()

        #expect(vm.notifications.count == 3)
        #expect(vm.errorMessage == nil)
    }

    // MARK: (2) unreadCountReflectsReadAt

    @Test("unreadCount reflects readAt nil vs non-nil")
    func unreadCountReflectsReadAt() async throws {
        let notifications = [
            makeNotification(id: "n1", readAt: nil),
            makeNotification(id: "n2", readAt: nil),
            makeNotification(id: "n3", readAt: Date(timeIntervalSince1970: 1_000_000)),
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(notifications)

        mock.handler = { req in (data, .ok(for: req)) }

        let vm = FizzyNotificationsViewModel(client: makeClient())
        await vm.refresh()

        #expect(vm.notifications.count == 3)
        #expect(vm.unreadCount == 2)
    }

    // MARK: (3) markReadUpdatesLocalState

    @Test("markRead updates local state — readAt becomes non-nil")
    func markReadUpdatesLocalState() async throws {
        let target = makeNotification(id: "n-read-me", readAt: nil)
        let other = makeNotification(id: "n-other", readAt: nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let listData = try encoder.encode([target, other])

        mock.handler = { req in
            if req.httpMethod == "GET" {
                return (listData, .ok(for: req))
            }
            // POST /notifications/n-read-me/reading → 204
            return (Data(), .response(for: req, status: 204))
        }

        let vm = FizzyNotificationsViewModel(client: makeClient())
        await vm.refresh()
        #expect(vm.notifications.count == 2)
        #expect(vm.unreadCount == 2)

        await vm.markRead(id: "n-read-me")

        let marked = vm.notifications.first { $0.id == "n-read-me" }
        #expect(marked?.readAt != nil)
        #expect(vm.unreadCount == 1)
    }

    // MARK: (4) markAllReadClearsUnreadCount

    @Test("markAllRead clears unread count")
    func markAllReadClearsUnreadCount() async throws {
        let notifications = [
            makeNotification(id: "n1", readAt: nil),
            makeNotification(id: "n2", readAt: nil),
            makeNotification(id: "n3", readAt: nil),
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let listData = try encoder.encode(notifications)

        mock.handler = { req in
            if req.httpMethod == "GET" {
                return (listData, .ok(for: req))
            }
            // POST /notifications/bulk_reading → 204
            return (Data(), .response(for: req, status: 204))
        }

        let vm = FizzyNotificationsViewModel(client: makeClient())
        await vm.refresh()
        #expect(vm.unreadCount == 3)

        await vm.markAllRead()

        #expect(vm.unreadCount == 0)
        #expect(vm.errorMessage == nil)
    }
}
