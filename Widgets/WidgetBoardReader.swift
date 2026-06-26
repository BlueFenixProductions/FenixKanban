// Widgets/WidgetBoardReader.swift
//
// Read-only CoreData entry point for the FenixKanbanWidgets extension.
//
// Opens the App Group store (the same FenixKanban.sqlite the app relocated there
// in Task 1) as a plain, read-only NSPersistentContainer — NOT a CloudKit
// container — and hands its viewContext to `makeWidgetBoardData(from:)`. The
// widget only reads the local replica; it never syncs. Referencing
// PersistenceController's static members (`appGroupStoreURL`, `sharedModel`)
// does not instantiate `PersistenceController.shared`, so no CloudKit stack is
// created here.
//
// Widget-target only (NOT in the test target): the read path needs the App
// Group container, which the test host lacks. The mapping it delegates to
// (WidgetBoardData.swift) is the part covered by unit tests.

import CoreData

struct WidgetBoardReader {

    /// Opens the App Group store read-only and returns the first board's summary,
    /// or `nil` if the store is unavailable (no entitlement), cannot be opened,
    /// or contains no board.
    func read() -> WidgetBoardData? {
        guard let storeURL = PersistenceController.appGroupStoreURL() else {
            return nil
        }

        let container = NSPersistentContainer(
            name: "FenixKanban",
            managedObjectModel: PersistenceController.sharedModel
        )

        let description = NSPersistentStoreDescription(url: storeURL)
        description.isReadOnly = true
        // Local replica only — no CloudKit, no history tracking writes.
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
        }
        if loadError != nil {
            return nil
        }

        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        return makeWidgetBoardData(from: container.viewContext)
    }
}
