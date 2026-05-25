import AppIntents
import CoreData

struct OpenCardIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Card"
    static var description = IntentDescription("Opens the specified card in FenixKanban.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Card") var card: CardEntity

    // Optional test seams. Runtime resolves via AppDependencyManager.
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
        let opened = resolvedNavigator.openCard(uuid: card.id, in: resolvedContext)
        if !opened {
            throw $card.needsValueError("That card no longer exists.")
        }
        return .result()
    }
}
