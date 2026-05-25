import Testing
import CoreData
@testable import FenixKanban

@Suite("Label Repository", .serialized)
@MainActor
struct LabelRepositoryTests {
    let persistence: PersistenceController
    let repository: LabelRepository

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        repository = LabelRepository(context: persistence.viewContext)
    }

    @Test func createLabel() {
        let label = repository.createLabel(name: "Urgent", colorHex: "#E94560")

        #expect(label.id != nil)
        #expect(label.name == "Urgent")
        #expect(label.colorHex == "#E94560")
        #expect(label.createdAt != nil)
    }

    @Test func fetchAllLabels() {
        _ = repository.createLabel(name: "Bug", colorHex: "#FF0000")
        _ = repository.createLabel(name: "Feature", colorHex: "#00FF00")

        let labels = repository.fetchAllLabels()
        #expect(labels.count == 2)
        // Sorted by name
        #expect(labels[0].name == "Bug")
        #expect(labels[1].name == "Feature")
    }

    @Test func updateLabel() {
        let label = repository.createLabel(name: "Original", colorHex: "#000000")

        repository.updateLabel(label, name: "Renamed", colorHex: "#FFFFFF")

        #expect(label.name == "Renamed")
        #expect(label.colorHex == "#FFFFFF")
    }

    @Test func deleteLabel() {
        let label = repository.createLabel(name: "ToDelete", colorHex: "#000000")
        #expect(repository.fetchAllLabels().count == 1)

        repository.deleteLabel(label)
        #expect(repository.fetchAllLabels().count == 0)
    }

    @Test func deleteLabelNullifiesCardRelationship() {
        let label = repository.createLabel(name: "Bug", colorHex: "#FF0000")

        let boardRepo = BoardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        let cardRepo = CardRepository(context: persistence.viewContext)
        let card = cardRepo.createCard(in: column, title: "Card")
        cardRepo.updateCard(card, label: label)
        #expect(card.label != nil)

        repository.deleteLabel(label)
        #expect(card.label == nil)
    }
}
