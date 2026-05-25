import AppIntents
import CoreData

struct OpenBoardIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Board"
    static var description = IntentDescription("Opens the specified board in FenixKanban.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Board") var board: BoardEntity

    // Optional test seams. Runtime resolves via AppDependencyManager;
    // tests inject directly via `_injectDependencies`.
    var navigatorOverride: NavigationModel?
    var contextOverride: NSManagedObjectContext?

    @Dependency private var navigator: NavigationModel
    @Dependency private var context: NSManagedObjectContext

    private var resolvedNavigator: NavigationModel { navigatorOverride ?? navigator }
    private var resolvedContext: NSManagedObjectContext { contextOverride ?? context }

    mutating func _injectDependencies(navigator: NavigationModel, context: NSManagedObjectContext) {
        self.navigatorOverride = navigator
        self.contextOverride = context
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let opened = resolvedNavigator.openBoard(uuid: board.id, in: resolvedContext)
        if !opened {
            throw $board.needsValueError("That board no longer exists.")
        }
        return .result()
    }
}
