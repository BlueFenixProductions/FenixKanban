import CoreData
import StoreKit
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
                .task {
                    for await result in Transaction.updates {
                        if case .verified(let transaction) = result {
                            await transaction.finish()
                        }
                    }
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
                            #if os(iOS)
                            .adaptiveLayout()
                            #endif
                            // Force a fresh BoardView (and fresh @StateObject
                            // BoardViewModel) for each distinct board so
                            // selecting a different board actually updates
                            // the detail pane.
                            .id(boardID)
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
