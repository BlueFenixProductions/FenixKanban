import Testing
import CoreData
@testable import FenixKanban

@Suite("Navigation Model", .serialized)
@MainActor
struct NavigationModelTests {

    private func makeContext() -> (PersistenceController, BoardRepository, CardRepository) {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
        return (persistence, boardRepo, cardRepo)
    }

    @Test func initialStateIsEmpty() {
        let model = NavigationModel()
        #expect(model.selectedBoardID == nil)
        #expect(model.selectedCardID == nil)
    }

    @Test func openBoardSetsSelectedBoardIDForExistingUUID() throws {
        let (persistence, repo, _) = makeContext()
        let board = repo.createBoard(name: "Test")
        let uuid = try #require(board.id)
        let model = NavigationModel()

        let opened = model.openBoard(uuid: uuid, in: persistence.viewContext)

        #expect(opened == true)
        #expect(model.selectedBoardID == board.objectID)
    }

    @Test func openBoardReturnsFalseForMissingUUID() {
        let (persistence, _, _) = makeContext()
        let model = NavigationModel()

        let opened = model.openBoard(uuid: UUID(), in: persistence.viewContext)

        #expect(opened == false)
        #expect(model.selectedBoardID == nil)
    }

    @Test func openCardSetsSelectedCardIDForExistingUUID() throws {
        let (persistence, boardRepo, cardRepo) = makeContext()
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        let card = cardRepo.createCard(in: column, title: "Card")
        let uuid = try #require(card.id)
        let model = NavigationModel()

        let opened = model.openCard(uuid: uuid, in: persistence.viewContext)

        #expect(opened == true)
        #expect(model.selectedCardID == card.objectID)
    }

    @Test func openCardReturnsFalseForMissingUUID() {
        let (persistence, _, _) = makeContext()
        let model = NavigationModel()

        let opened = model.openCard(uuid: UUID(), in: persistence.viewContext)

        #expect(opened == false)
        #expect(model.selectedCardID == nil)
    }
}
