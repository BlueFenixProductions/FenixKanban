import AppIntents
import CoreData
import StoreKit
import SwiftUI

@main
struct FenixKanbanApp: App {
    @StateObject private var persistence = PersistenceController.shared
    @StateObject private var authService = AuthenticationService()
    @StateObject private var syncMonitor: SyncMonitor
    @State private var navigator = NavigationModel()
    @State private var syncScheduler: SyncScheduler
    @AppStorage("appearanceMode") private var appearanceRaw: String = AppearanceMode.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let launchArgs = ProcessInfo.processInfo.arguments

        // UI-test bypass: skip the auth gate so the board list is
        // reachable from a fresh launch without needing Sign in with
        // Apple. Paired with PersistenceController's in-memory store
        // override on the same launch flag.
        if launchArgs.contains("-uitest-reset-store") {
            UserDefaults.standard.set(true, forKey: "hasSkippedAuth")
        }

        let monitor = SyncMonitor(container: PersistenceController.shared.container)
        _syncMonitor = StateObject(wrappedValue: monitor)

        // Register App Intent dependencies synchronously so cold-launch
        // from Siri / Shortcuts resolves before any perform() runs.
        // `add(dependency:)` takes an @autoclosure, so the NavigationModel
        // is materialized to a local first — otherwise the autoclosure
        // captures mutating `self` to read `_navigator`.
        let viewContext = PersistenceController.shared.container.viewContext
        let navigatorValue = _navigator.wrappedValue

        // UI-test seed: pre-create Board → Column → Card and select
        // the board so tests that exercise card-level behavior
        // (drag, tap) skip 20–30s of UI-driven setup. The seed-flow
        // test itself doesn't pass this arg — it still drives the
        // creation UI to assert that surface works.
        if launchArgs.contains("-uitest-seed-board") {
            let boardID = PersistenceController.seedUITestBoardColumnAndCard()
            navigatorValue.selectedBoardID = boardID
        }

        AppDependencyManager.shared.add(dependency: viewContext)
        AppDependencyManager.shared.add(dependency: navigatorValue)

        // Register Fizzy as a BoardSyncProvider. The provider is constructed
        // with the production singletons (Keychain-backed FizzyAuthState,
        // standard UserDefaults-backed FizzyBoardMapping, the shared
        // PersistenceController). It is registered before the first scene
        // renders so SyncSettingsView's list is populated on cold launch.
        let fizzyProvider = FizzySyncProvider(
            authState: FizzyAuthState(),
            mapping: FizzyBoardMapping(),
            persistence: PersistenceController.shared
        )
        PluginRegistry.shared.register(fizzyProvider)

        // Phase 6: foreground auto-refresh scheduler (default 300 s interval).
        // The scheduler is `@State` (not @StateObject) because it is
        // @Observable (not ObservableObject). `_syncScheduler` follows the
        // same pattern as `_navigator` above.
        _syncScheduler = State(wrappedValue: SyncScheduler(provider: fizzyProvider))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(navigator: navigator, syncScheduler: syncScheduler)
                .environment(\.managedObjectContext, persistence.viewContext)
                .environmentObject(authService)
                .environmentObject(syncMonitor)
                .preferredColorScheme(AppearanceMode(rawValue: appearanceRaw)?.colorScheme)
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
        .onChange(of: scenePhase) { _, newPhase in
            // The unit-test host must not run the production sync loop: a
            // scheduler tick firing mid-test-run (interval is 300 s; CI test
            // phases can exceed that under load) races the test suites. Same
            // detection PersistenceController uses for its in-memory store.
            guard !FenixKanbanApp.isRunningUnitTests else { return }
            syncScheduler.setSceneActive(newPhase == .active)
        }
    }

    /// True when running inside the unit-test host (XCTest injects this env
    /// var). Gates the production sync machinery off during test runs.
    static let isRunningUnitTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

struct ContentView: View {
    @Bindable var navigator: NavigationModel
    var syncScheduler: SyncScheduler
    @EnvironmentObject var authService: AuthenticationService
    @EnvironmentObject var syncMonitor: SyncMonitor
    @Environment(\.managedObjectContext) private var context
    @State private var showSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @AppStorage("hasSkippedAuth") private var hasSkippedAuth = false

    var body: some View {
        Group {
            if !authService.isAuthenticated && authService.userID == nil && !hasSkippedAuth {
                AuthView(viewModel: AuthViewModel(authService: authService))
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    BoardListView(context: context, selection: $navigator.selectedBoardID)
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
                    if let boardID = navigator.selectedBoardID,
                       let board = try? context.existingObject(with: boardID) as? Board {
                        BoardView(board: board, context: context)
                            .adaptiveLayout()
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
                .sheet(isPresented: Binding(
                    get: { navigator.selectedCardID != nil },
                    set: { if !$0 { navigator.selectedCardID = nil } }
                )) {
                    if let cardID = navigator.selectedCardID,
                       let card = try? context.existingObject(with: cardID) as? Card {
                        CardDetailView(card: card, context: context)
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(authService: authService, persistence: .shared, syncScheduler: syncScheduler)
                .environment(\.managedObjectContext, context)
        }
    }
}
