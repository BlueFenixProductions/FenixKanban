import SwiftUI

/// Sheet showing the current user's Fizzy server notifications.
///
/// Presented via `NotificationBellButton` when the toolbar bell is tapped.
/// Load on appear — no background polling. Empty states and a loading
/// spinner are shown inline. "Mark All Read" appears only when there are
/// unread notifications.
struct FizzyNotificationsView: View {
    @State var viewModel: FizzyNotificationsViewModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Notifications")
                .toolbar {
                    if viewModel.unreadCount > 0 {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Mark All Read") {
                                Task { await viewModel.markAllRead() }
                            }
                        }
                    }
                }
                .task {
                    await viewModel.refresh()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.notifications.isEmpty {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.notifications.isEmpty {
            emptyState
        } else {
            notificationList
        }
    }

    private var emptyState: some View {
        Group {
            if #available(iOS 17, macOS 14, *) {
                ContentUnavailableView(
                    "No Notifications",
                    systemImage: "bell.slash",
                    description: Text("You're all caught up.")
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No Notifications")
                        .font(.headline)
                    Text("You're all caught up.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var notificationList: some View {
        List {
            ForEach(viewModel.notifications, id: \.id) { notification in
                NotificationRow(notification: notification)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task { await viewModel.markRead(id: notification.id) }
                    }
                    .listRowBackground(
                        notification.readAt == nil
                            ? Color.accentColor.opacity(0.08)
                            : Color.clear
                    )
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Row

private struct NotificationRow: View {
    let notification: FizzyNotification

    private var isUnread: Bool { notification.readAt == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(notification.title)
                .font(.crossPlatformBody)
                .fontWeight(isUnread ? .semibold : .regular)
                .foregroundStyle(isUnread ? .primary : .secondary)

            if let body = notification.body, !body.isEmpty {
                Text(body)
                    .font(.crossPlatformSubheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text(notification.createdAt.relativeDisplay)
                .font(.crossPlatformCaption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
