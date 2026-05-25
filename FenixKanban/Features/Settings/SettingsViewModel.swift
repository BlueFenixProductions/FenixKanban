import SwiftUI
import CoreData

final class SettingsViewModel: ObservableObject {
    @Published var showDeleteConfirmation = false
    @Published var syncEnabled: Bool

    let authService: AuthenticationService
    private let persistence: PersistenceController

    var userEmail: String? {
        authService.isAuthenticated ? "Signed In" : nil
    }

    init(authService: AuthenticationService, persistence: PersistenceController) {
        self.authService = authService
        self.persistence = persistence
        self.syncEnabled = authService.isAuthenticated
    }

    func signOut() {
        authService.signOut()
    }

    func deleteAllData() {
        let context = persistence.viewContext
        let entities = ["Card", "Column", "Board", "Label"]
        for entity in entities {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
            _ = try? context.execute(deleteRequest)
        }
        _ = try? context.save()
    }
}
