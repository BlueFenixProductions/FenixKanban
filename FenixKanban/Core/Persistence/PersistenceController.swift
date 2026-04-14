import CoreData
import CloudKit

final class PersistenceController: ObservableObject {
    static let shared = PersistenceController()

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
        card.label = label

        try? context.save()
        return controller
    }()

    let container: NSPersistentContainer

    var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    init(inMemory: Bool = false, useCloudKit: Bool = true) {
        if useCloudKit && !inMemory {
            container = NSPersistentCloudKitContainer(name: "FenixKanban")
        } else {
            container = NSPersistentContainer(name: "FenixKanban")
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
