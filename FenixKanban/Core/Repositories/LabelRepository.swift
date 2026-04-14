import CoreData

protocol LabelRepositoryProtocol {
    func fetchAllLabels() -> [Label]
    func createLabel(name: String, colorHex: String) -> Label
    func updateLabel(_ label: Label, name: String?, colorHex: String?)
    func deleteLabel(_ label: Label)
}

final class LabelRepository: LabelRepositoryProtocol {
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func fetchAllLabels() -> [Label] {
        let request = Label.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Label.name, ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    func createLabel(name: String, colorHex: String) -> Label {
        let label = Label(context: context)
        label.id = UUID()
        label.name = name
        label.colorHex = colorHex
        label.createdAt = Date()
        save()
        return label
    }

    func updateLabel(_ label: Label, name: String? = nil, colorHex: String? = nil) {
        if let name = name { label.name = name }
        if let colorHex = colorHex { label.colorHex = colorHex }
        save()
    }

    func deleteLabel(_ label: Label) {
        context.delete(label)
        save()
    }

    private func save() {
        guard context.hasChanges else { return }
        try? context.save()
    }
}
