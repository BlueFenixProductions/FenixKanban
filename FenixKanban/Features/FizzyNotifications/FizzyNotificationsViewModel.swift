import Foundation
import Observation

/// In-memory view model for Fizzy server notifications.
///
/// Loads notifications from the server on demand (no Core Data persistence
/// — server-authoritative ephemeral data). Exposes an `unreadCount` so the
/// toolbar bell badge can show an indicator without requiring the sheet to open.
@Observable
@MainActor
final class FizzyNotificationsViewModel {

    // MARK: - Published state

    private(set) var notifications: [FizzyNotification] = []
    private(set) var isLoading = false
    var errorMessage: String?

    // MARK: - Derived

    var unreadCount: Int {
        notifications.filter { $0.readAt == nil }.count
    }

    // MARK: - Private

    private let client: FizzyClient

    // MARK: - Init

    init(client: FizzyClient) {
        self.client = client
    }

    // MARK: - Fetch

    /// Fetches all notifications from the server and replaces the local list.
    /// Guards against concurrent refreshes — calling while `isLoading` is a
    /// no-op.
    func refresh() async {
        guard !isLoading else { return }
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            notifications = try await client.notifications()
        } catch {
            errorMessage = "Couldn't load notifications."
        }
    }

    // MARK: - Mark read

    /// Marks a single notification read on the server and updates local state.
    /// Finds the entry by `id`, calls the server, then patches the local copy's
    /// `readAt` to `now` so the UI updates immediately.
    func markRead(id: String) async {
        guard let index = notifications.firstIndex(where: { $0.id == id }) else { return }
        guard notifications[index].readAt == nil else { return } // already read
        do {
            try await client.markNotificationRead(id: id)
            // Patch local state optimistically — mutate a copy of the struct.
            let old = notifications[index]
            notifications[index] = FizzyNotification(
                id: old.id,
                read: true,
                readAt: Date(),
                createdAt: old.createdAt,
                title: old.title,
                body: old.body,
                creator: old.creator,
                card: old.card,
                url: old.url
            )
        } catch {
            // Non-fatal: leave local state unchanged. Next refresh will reconcile.
        }
    }

    /// Bulk-marks all unread notifications read on the server using the
    /// `bulk_reading` endpoint, then sets `readAt` for each unread entry locally.
    func markAllRead() async {
        guard unreadCount > 0 else { return }
        do {
            try await client.markAllNotificationsRead()
            // Optimistically update every unread entry in local state.
            let now = Date()
            notifications = notifications.map { n in
                guard n.readAt == nil else { return n }
                return FizzyNotification(
                    id: n.id,
                    read: true,
                    readAt: now,
                    createdAt: n.createdAt,
                    title: n.title,
                    body: n.body,
                    creator: n.creator,
                    card: n.card,
                    url: n.url
                )
            }
        } catch {
            errorMessage = "Couldn't mark all notifications read."
        }
    }
}
