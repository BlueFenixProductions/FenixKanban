import CoreData
import SwiftUI

final class LabelManagementViewModel: ObservableObject {
    @Published var labels: [Label] = []
    @Published var showEditor = false
    @Published var editingLabel: Label?

    private let repository: LabelRepository

    init(context: NSManagedObjectContext) {
        self.repository = LabelRepository(context: context)
        fetchLabels()
    }

    func fetchLabels() {
        labels = repository.fetchAllLabels()
    }

    func createLabel(name: String, colorHex: String) {
        _ = repository.createLabel(name: name, colorHex: colorHex)
        fetchLabels()
    }

    func updateLabel(_ label: Label, name: String, colorHex: String) {
        repository.updateLabel(label, name: name, colorHex: colorHex)
        fetchLabels()
    }

    func deleteLabel(_ label: Label) {
        repository.deleteLabel(label)
        fetchLabels()
    }
}
