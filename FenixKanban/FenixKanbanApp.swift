import SwiftUI

@main
struct FenixKanbanApp: App {
    @StateObject private var persistence = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            Text("FenixKanban")
                .environment(\.managedObjectContext, persistence.viewContext)
                .preferredColorScheme(.dark)
        }
    }
}
