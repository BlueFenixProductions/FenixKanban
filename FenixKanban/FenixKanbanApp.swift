import AppIntents
import CoreData
import StoreKit
import SwiftUI
#if os(iOS)
import BackgroundTasks
#endif

@main
struct FenixKanbanApp: App {
    @StateObject private var persistence = PersistenceController.shared
    @StateObject private var authService = AuthenticationService()
    @StateObject private var syncMonitor: SyncMonitor
    @State private var navigator = NavigationModel()
    @State private var syncScheduler: SyncScheduler
    @AppStorage("appearanceMode") private var appearanceRaw: String = AppearanceMode.system.rawValue
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @State private var bgRefreshCoordinator: BackgroundRefreshCoordinator
    #endif

    /// BGAppRefreshTask identifier for Fizzy board sync.
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info-Partial.plist.
    static let bgRefreshIdentifier = "com.bluefenixproductions.FenixKanban.fizzy-refresh"

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

        // Task #62: background refresh coordinator (iOS-only).
        // Shares the same FizzySyncProvider so background cycles use identical
        // auth/mapping/persistence as foreground cycles.
        #if os(iOS)
        _bgRefreshCoordinator = State(
            wrappedValue: BackgroundRefreshCoordinator(provider: fizzyProvider)
        )
        #endif
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
            // The unit-test host must not run the production sync loop or
            // touch BGTaskScheduler: a scheduler tick firing mid-test-run
            // (interval is 300 s; CI test phases can exceed that under load)
            // races the test suites. Same detection PersistenceController uses.
            guard !FenixKanbanApp.isRunningUnitTests else { return }
            syncScheduler.setSceneActive(newPhase == .active)
            #if os(iOS)
            // Schedule the next background refresh whenever the app moves
            // to background (covers both initial background and re-background
            // after the task handler fires).
            if newPhase == .background {
                FenixKanbanApp.submitBackgroundRefreshRequest()
            }
            #endif
        }
        #if os(iOS)
        // BGAppRefreshTask handler. The system wakes the app, SwiftUI calls
        // this closure, and we race one sync cycle against the 25 s budget.
        // After each run we reschedule so the cycle repeats.
        .backgroundTask(.appRefresh(FenixKanbanApp.bgRefreshIdentifier)) {
            let success = await bgRefreshCoordinator.performBackgroundRefresh()
            // Reschedule regardless of success so the next wake is always
            // pending. (Failure just means this wake was a no-op.)
            FenixKanbanApp.submitBackgroundRefreshRequest()
            // Return value is ignored by SwiftUI's backgroundTask modifier;
            // BGTask.setTaskCompleted(success:) is called automatically.
            _ = success
        }
        #endif
    }

    /// True when running inside the unit-test host (XCTest injects this env
    /// var). Gates the production sync machinery off during test runs.
    static let isRunningUnitTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    #if os(iOS)
    /// Submit a BGAppRefreshTaskRequest so the system schedules the next wake.
    ///
    /// Static + nonisolated so it can be called from both `@MainActor` context
    /// (the scenePhase onChange) and the non-isolated `.backgroundTask` closure
    /// without triggering Swift 6 actor-isolation warnings.
    /// Safe to call multiple times — duplicates are coalesced by BGTaskScheduler.
    nonisolated static func submitBackgroundRefreshRequest() {
        let request = BGAppRefreshTaskRequest(identifier: bgRefreshIdentifier)
        // Earliest date: 15 minutes from now. The OS decides the actual wake
        // time based on usage patterns; this is a lower bound.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Non-fatal: the task may already be scheduled, or the simulator
            // may not support BGTaskScheduler. Log and continue.
            print("[BgRefresh] BGTaskScheduler.submit failed: \(error)")
        }
    }
    #endif
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
