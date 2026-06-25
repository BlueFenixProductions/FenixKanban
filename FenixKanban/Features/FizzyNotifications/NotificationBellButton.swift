import SwiftUI

/// Toolbar button that shows a bell icon (with badge when there are unread
/// Fizzy server notifications) and presents the notifications sheet on tap.
///
/// Placed in `BoardView`'s toolbar when the board is Fizzy-paired. The view
/// model is created once per board and shared between the button and the sheet.
struct NotificationBellButton: View {
    @State var viewModel: FizzyNotificationsViewModel
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            Image(systemName: viewModel.unreadCount > 0 ? "bell.badge" : "bell")
        }
        .sheet(isPresented: $showSheet) {
            FizzyNotificationsView(viewModel: viewModel)
        }
        .task {
            await viewModel.refresh()
        }
    }
}
