import Testing
import AppIntents
import CoreData
@testable import FenixKanban

@Suite("Open Card Intent", .serialized)
@MainActor
struct OpenCardIntentTests {

    private func setup() -> (PersistenceController, CardRepository, Column, NavigationModel) {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        return (persistence, cardRepo, column, NavigationModel())
    }

    @Test func performSelectsCardOnNavigator() async throws {
        let (persistence, cardRepo, column, navigator) = setup()
        let card = cardRepo.createCard(in: column, title: "Fix bug")
        let entity = try CardEntity(from: card)

        var intent = OpenCardIntent()
        intent.card = entity
        intent._injectDependencies(navigator: navigator, context: persistence.viewContext)

        _ = try await intent.perform()

        #expect(navigator.selectedCardID == card.objectID)
    }

    @Test func performThrowsWhenCardNoLongerExists() async throws {
        let (persistence, _, _, navigator) = setup()
        let entity = CardEntity(id: UUID(), title: "Ghost", cardDescription: nil, dueDate: nil, isCompleted: false, isGolden: false)

        var intent = OpenCardIntent()
        intent.card = entity
        intent._injectDependencies(navigator: navigator, context: persistence.viewContext)

        await #expect(throws: (any Error).self) {
            try await intent.perform()
        }
        #expect(navigator.selectedCardID == nil)
    }
}
