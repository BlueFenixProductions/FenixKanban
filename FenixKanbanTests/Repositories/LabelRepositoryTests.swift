import XCTest
import CoreData
@testable import FenixKanban

final class LabelRepositoryTests: XCTestCase {
    var persistence: PersistenceController!
    var repository: LabelRepository!

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        repository = LabelRepository(context: persistence.viewContext)
    }

    override func tearDown() {
        repository = nil
        persistence = nil
        super.tearDown()
    }

    func testCreateLabel() {
        let label = repository.createLabel(name: "Urgent", colorHex: "#E94560")

        XCTAssertNotNil(label.id)
        XCTAssertEqual(label.name, "Urgent")
        XCTAssertEqual(label.colorHex, "#E94560")
        XCTAssertNotNil(label.createdAt)
    }

    func testFetchAllLabels() {
        _ = repository.createLabel(name: "Bug", colorHex: "#FF0000")
        _ = repository.createLabel(name: "Feature", colorHex: "#00FF00")

        let labels = repository.fetchAllLabels()
        XCTAssertEqual(labels.count, 2)
        // Sorted by name
        XCTAssertEqual(labels[0].name, "Bug")
        XCTAssertEqual(labels[1].name, "Feature")
    }

    func testUpdateLabel() {
        let label = repository.createLabel(name: "Original", colorHex: "#000000")

        repository.updateLabel(label, name: "Renamed", colorHex: "#FFFFFF")

        XCTAssertEqual(label.name, "Renamed")
        XCTAssertEqual(label.colorHex, "#FFFFFF")
    }

    func testDeleteLabel() {
        let label = repository.createLabel(name: "ToDelete", colorHex: "#000000")
        XCTAssertEqual(repository.fetchAllLabels().count, 1)

        repository.deleteLabel(label)
        XCTAssertEqual(repository.fetchAllLabels().count, 0)
    }

    func testDeleteLabelNullifiesCardRelationship() {
        let label = repository.createLabel(name: "Bug", colorHex: "#FF0000")

        let boardRepo = BoardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        let cardRepo = CardRepository(context: persistence.viewContext)
        let card = cardRepo.createCard(in: column, title: "Card")
        cardRepo.updateCard(card, label: label)
        XCTAssertNotNil(card.label)

        repository.deleteLabel(label)
        XCTAssertNil(card.label)
    }
}
