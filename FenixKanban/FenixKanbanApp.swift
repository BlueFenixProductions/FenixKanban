import CoreData
import SwiftUI

@main
struct FenixKanbanApp: App {
    @StateObject private var persistence = PersistenceController.shared
    @StateObject private var authService = AuthenticationService()
    @StateObject private var syncMonitor: SyncMonitor

    init() {
        let monitor = SyncMonitor(container: PersistenceController.shared.container)
        _syncMonitor = StateObject(wrappedValue: monitor)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistence.viewContext)
                .environmentObject(authService)
                .environmentObject(syncMonitor)
                .preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)) { _ in
                    NotificationService.shared.refreshAllReminders(context: persistence.viewContext)
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var authService: AuthenticationService
    @EnvironmentObject var syncMonitor: SyncMonitor
    @Environment(\.managedObjectContext) private var context
    @State private var selectedBoardID: NSManagedObjectID?
    @State private var showSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @AppStorage("hasSkippedAuth") private var hasSkippedAuth = false

    var body: some View {
        Group {
            if !authService.isAuthenticated && authService.userID == nil && !hasSkippedAuth {
                AuthView(viewModel: AuthViewModel(authService: authService))
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    BoardListView(context: context, selection: $selectedBoardID)
                        .toolbar {
                            ToolbarItem(placement: .automatic) {
                                HStack(spacing: 12) {
                                    SyncStatusIndicator(status: syncMonitor.status)
                                    Button { showSettings = true } label: {
                                        Image(systemName: "gearshape")
                                    }
                                }
                            }
                        }
                } detail: {
                    if let boardID = selectedBoardID,
                       let board = try? context.existingObject(with: boardID) as? Board {
                        BoardView(board: board, context: context)
                            .adaptiveLayout()
                    } else {
                        EmptyStateView(
                            icon: "sidebar.squares.left",
                            title: "Select a Board",
                            message: "Choose a board from the sidebar"
                        )
                    }
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(authService: authService, persistence: .shared)
                .environment(\.managedObjectContext, context)
        }
    }
}
