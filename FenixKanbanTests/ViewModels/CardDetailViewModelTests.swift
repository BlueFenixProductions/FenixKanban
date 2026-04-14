import XCTest
import CoreData
@testable import FenixKanban

final class CardDetailViewModelTests: XCTestCase {
    var persistence: PersistenceController!
    var boardRepo: BoardRepository!
    var cardRepo: CardRepository!
    var card: Card!
    var viewModel: CardDetailViewModel!

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        card = cardRepo.createCard(in: column, title: "Test Card")
        viewModel = CardDetailViewModel(card: card, context: persistence.viewContext)
    }

    override func tearDown() {
        viewModel = nil
        card = nil
        cardRepo = nil
        boardRepo = nil
        persistence = nil
        super.tearDown()
    }

    func testInitialValues() {
        XCTAssertEqual(viewModel.title, "Test Card")
        XCTAssertEqual(viewModel.cardDescription, "")
        XCTAssertNil(viewModel.dueDate)
        XCTAssertFalse(viewModel.isCompleted)
        XCTAssertNil(viewModel.selectedLabel)
    }

    func testSaveUpdatesCard() {
        viewModel.title = "Updated Title"
        viewModel.cardDescription = "A description"
        viewModel.isCompleted = true
        viewModel.save()

        XCTAssertEqual(card.title, "Updated Title")
        XCTAssertEqual(card.cardDescription, "A description")
        XCTAssertTrue(card.isCompleted)
    }

    func testClearDueDate() {
        viewModel.dueDate = Date()
        viewModel.save()
        XCTAssertNotNil(card.dueDate)

        viewModel.clearDueDate()
        XCTAssertNil(card.dueDate)
        XCTAssertNil(viewModel.dueDate)
    }

    func testSelectLabel() {
        let labelRepo = LabelRepository(context: persistence.viewContext)
        let label = labelRepo.createLabel(name: "Bug", colorHex: "#FF0000")

        viewModel.selectLabel(label)
        XCTAssertEqual(viewModel.selectedLabel, label)
        XCTAssertEqual(card.label, label)
    }

    func testClearLabel() {
        let labelRepo = LabelRepository(context: persistence.viewContext)
        let label = labelRepo.createLabel(name: "Bug", colorHex: "#FF0000")
        viewModel.selectLabel(label)

        viewModel.clearLabel()
        XCTAssertNil(viewModel.selectedLabel)
        XCTAssertNil(card.label)
    }
}
