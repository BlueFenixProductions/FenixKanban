import CoreData
import CloudKit

final class PersistenceController: ObservableObject {

    // MARK: - App Group

    /// The App Group identifier shared by the app and widget extension.
    /// Single source of truth — snapshot files that also define this will
    /// be removed in Task 3.
    static let appGroupIdentifier = "group.com.bluefenixproductions.FenixKanban"

    /// Returns the preferred store URL inside the shared App Group container,
    /// or `nil` if the container is unavailable (e.g. entitlement missing in
    /// a test host).
    static func appGroupStoreURL(fileManager: FileManager = .default) -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("FenixKanban.sqlite")
    }

    /// Copies the persistent store at `oldURL` to `newURL` using
    /// `NSPersistentStoreCoordinator.replacePersistentStore`, which carries
    /// the WAL/SHM files and CloudKit sync metadata along for the ride.
    ///
    /// Rules:
    /// - If `newURL` already exists → no-op (never clobber the live store).
    /// - If `oldURL` does not exist → no-op (fresh install; CloudKit will
    ///   populate the new store on first sync).
    /// - Otherwise → copy `oldURL` → `newURL` and leave `oldURL` in place
    ///   as an inert backup.
    static func migrateStoreIfNeeded(
        to newURL: URL,
        from oldURL: URL,
        fileManager: FileManager = .default
    ) {
        // Guard 1: destination already present — never clobber.
        guard !fileManager.fileExists(atPath: newURL.path) else { return }
        // Guard 2: nothing to migrate.
        guard fileManager.fileExists(atPath: oldURL.path) else { return }

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: sharedModel)
        do {
            try coordinator.replacePersistentStore(
                at: newURL,
                destinationOptions: nil,
                withPersistentStoreFrom: oldURL,
                sourceOptions: nil,
                type: .sqlite
            )
        } catch {
            // Log and fall through — the app will open the old store location
            // as a safe fallback (the init path checks newURL after migration).
            print("PersistenceController: store migration failed — \(error). Falling back to default location.")
        }
    }

    /// Test hosts (XCTest + UI tests) get an in-memory, non-CloudKit
    /// store so the suite is hermetic — no iCloud creds, no disk
    /// writes, no cross-test bleed. Production launches behave
    /// identically to before.
    ///
    /// Triggers:
    /// - `XCTestConfigurationFilePath` env var is present whenever
    ///   xctest hosts the bundle (unit tests run inside the app's
    ///   test-host process and would otherwise hit the real
    ///   PersistenceController init).
    /// - `-uitest-reset-store` is the explicit launchArguments flag
    ///   set by FenixKanbanUITests for the same reason.
    static let shared: PersistenceController = {
        let processInfo = ProcessInfo.processInfo
        let isUnderTest = processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || processInfo.arguments.contains("-uitest-reset-store")
        if isUnderTest {
            return PersistenceController(inMemory: true, useCloudKit: false)
        }
        return PersistenceController()
    }()

    static var preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.viewContext
        // Sample data for previews
        let board = Board(context: context)
        board.id = UUID()
        board.name = "Sample Board"
        board.createdAt = Date()
        board.modifiedAt = Date()
        board.sortOrder = 0

        let column1 = Column(context: context)
        column1.id = UUID()
        column1.name = "To Do"
        column1.createdAt = Date()
        column1.modifiedAt = Date()
        column1.sortOrder = 0
        column1.board = board

        let column2 = Column(context: context)
        column2.id = UUID()
        column2.name = "In Progress"
        column2.createdAt = Date()
        column2.modifiedAt = Date()
        column2.sortOrder = 1000
        column2.board = board

        let label = Label(context: context)
        label.id = UUID()
        label.name = "Urgent"
        label.colorHex = "#E94560"
        label.createdAt = Date()

        let card = Card(context: context)
        card.id = UUID()
        card.title = "Sample Card"
        card.cardDescription = "A sample card description"
        card.createdAt = Date()
        card.modifiedAt = Date()
        card.sortOrder = 0
        card.column = column1
        card.addToLabels(label)

        try? context.save()
        return controller
    }()

    let container: NSPersistentContainer

    var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    // Loaded once and reused across every container instance. Without this,
    // creating multiple PersistenceControllers (e.g. in unit tests) loads
    // duplicate NSManagedObjectModels with the same entity names, which
    // makes +[Entity entity] ambiguous and routes fetches and inserts to
    // different stacks.
    /// Loaded once and reused. Exposed `internal` so `BackupExporter`'s
    /// verifier can build a throwaway `NSPersistentContainer` against the
    /// same managed-object model without duplicate-entity warnings.
    static let sharedModel: NSManagedObjectModel = {
        let bundle = Bundle(for: SharedModelLoader.self)
        guard let url = bundle.url(forResource: "FenixKanban", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: url) else {
            fatalError("Failed to locate FenixKanban.momd in the app bundle")
        }
        return model
    }()

    init(inMemory: Bool = false, useCloudKit: Bool = true) {
        if useCloudKit && !inMemory {
            container = NSPersistentCloudKitContainer(name: "FenixKanban", managedObjectModel: Self.sharedModel)
        } else {
            container = NSPersistentContainer(name: "FenixKanban", managedObjectModel: Self.sharedModel)
        }

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        if let description = container.persistentStoreDescriptions.first {
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

            if useCloudKit && !inMemory {
                description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                    containerIdentifier: "iCloud.com.bluefenixproductions.FenixKanban"
                )

                // Relocate the production store into the App Group container so the
                // WidgetKit extension (and future read paths) can reach it directly.
                // Migrate any existing default-location store on first launch.
                if let groupURL = Self.appGroupStoreURL() {
                    let defaultURL = NSPersistentContainer.defaultDirectoryURL()
                        .appendingPathComponent("FenixKanban.sqlite")
                    Self.migrateStoreIfNeeded(to: groupURL, from: defaultURL)
                    description.url = groupURL
                }
                // If appGroupStoreURL() returns nil (entitlement unavailable),
                // fall through and use the default location unchanged — defensive
                // at the OS boundary, do not crash.
            }
        }

        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                fatalError("CoreData store failed to load: \(error), \(error.userInfo)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    /// Inserts a minimal Board → Column → Card graph into the shared
    /// in-memory store and returns the board's objectID. Used by
    /// FenixKanbanApp when the `-uitest-seed-board` launch arg is
    /// present so UI tests skip 20–30s of UI-driven setup per test.
    /// Production never invokes this — the launch arg is only set
    /// by FenixKanbanUITests.
    @discardableResult
    static func seedUITestBoardColumnAndCard() -> NSManagedObjectID {
        let context = shared.viewContext
        let board = Board(context: context)
        board.id = UUID()
        board.name = "Test Board"
        board.createdAt = Date()
        board.modifiedAt = Date()
        board.sortOrder = 0

        let column = Column(context: context)
        column.id = UUID()
        column.name = "Todo"
        column.createdAt = Date()
        column.modifiedAt = Date()
        column.sortOrder = 0
        column.board = board

        let card = Card(context: context)
        card.id = UUID()
        card.title = "Test Card"
        card.createdAt = Date()
        card.modifiedAt = Date()
        card.sortOrder = 0
        card.column = column

        try? context.save()
        return board.objectID
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }

    func save(context: NSManagedObjectContext) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            let nsError = error as NSError
            print("CoreData save error: \(nsError), \(nsError.userInfo)")
        }
    }
}

// Lightweight NSObject anchor so Bundle(for:) can find the bundle that
// contains FenixKanban.momd. The PersistenceController itself is a plain
// Swift class — making it NSObject just to call Bundle(for:) would be
// heavier than introducing this tiny helper.
private final class SharedModelLoader: NSObject {}
