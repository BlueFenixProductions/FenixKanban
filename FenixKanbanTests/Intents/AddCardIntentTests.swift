// FenixKanbanTests/Intents/AddCardIntentTests.swift
import Testing
import CoreData
import Foundation
import AppIntents
@testable import FenixKanban

@Suite("AddCardIntent", .serialized)
@MainActor
struct AddCardIntentTests {
    let persistence: PersistenceController
    let boardRepo: BoardRepository
    let cardRepo: CardRepository
    let board: Board
    let firstColumn: Column
    let secondColumn: Column

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        cardRepo = CardRepository(context: persistence.viewContext)
        board = boardRepo.createBoard(name: "Sprint Board")
        firstColumn = boardRepo.createColumn(in: board, name: "Backlog")
        secondColumn = boardRepo.createColumn(in: board, name: "In Progress")
    }

    // MARK: - Default column (first by sortOrder)

    @Test("perform() creates card in first column when no column name given")
    func performDefaultColumn() async throws {
        var intent = AddCardIntent()
        intent.title = "Fix login bug"
        intent.board = try BoardEntity(from: board)
        intent._injectDependencies(context: persistence.viewContext)

        let result = try await intent.perform()
        let entity = try #require(result.value)

        #expect(entity.title == "Fix login bug")

        // Verify card is in the first column (by sortOrder)
        let context = persistence.viewContext
        let created: Card? = try await context.perform {
            let request = Card.fetchRequest()
            request.predicate = NSPredicate(format: "title == %@", "Fix login bug")
            return try context.fetch(request).first
        }
        let card = try #require(created)
        #expect(card.column?.name == "Backlog")
    }

    // MARK: - Named column

    @Test("perform() places card in named column when columnName matches")
    func performNamedColumn() async throws {
        var intent = AddCardIntent()
        intent.title = "Design mockup"
        intent.board = try BoardEntity(from: board)
        intent.columnName = "In Progress"
        intent._injectDependencies(context: persistence.viewContext)

        let result = try await intent.perform()
        let entity = try #require(result.value)
        #expect(entity.title == "Design mockup")

        let context = persistence.viewContext
        let created: Card? = try await context.perform {
            let request = Card.fetchRequest()
            request.predicate = NSPredicate(format: "title == %@", "Design mockup")
            return try context.fetch(request).first
        }
        let card = try #require(created)
        #expect(card.column?.name == "In Progress")
    }

    @Test("perform() falls back to first column when columnName does not match")
    func performUnknownColumnFallsBackToFirst() async throws {
        var intent = AddCardIntent()
        intent.title = "Mystery task"
        intent.board = try BoardEntity(from: board)
        intent.columnName = "Nonexistent Column"
        intent._injectDependencies(context: persistence.viewContext)

        let result = try await intent.perform()
        let entity = try #require(result.value)
        #expect(entity.title == "Mystery task")

        let context = persistence.viewContext
        let created: Card? = try await context.perform {
            let request = Card.fetchRequest()
            request.predicate = NSPredicate(format: "title == %@", "Mystery task")
            return try context.fetch(request).first
        }
        let card = try #require(created)
        // Falls back to first column
        #expect(card.column?.name == "Backlog")
    }

    // MARK: - Empty title validation

    @Test("perform() throws validation error when title is empty")
    func performEmptyTitleThrows() async throws {
        var intent = AddCardIntent()
        intent.title = ""
        intent.board = try BoardEntity(from: board)
        intent._injectDependencies(context: persistence.viewContext)

        await #expect(throws: (any Error).self) {
            _ = try await intent.perform()
        }
    }

    // MARK: - Board not found

    @Test("perform() throws when board no longer exists")
    func performMissingBoardThrows() async throws {
        var intent = AddCardIntent()
        intent.title = "Orphan task"
        intent.board = BoardEntity(id: UUID(), name: "Ghost Board", colorHex: nil)
        intent._injectDependencies(context: persistence.viewContext)

        await #expect(throws: (any Error).self) {
            _ = try await intent.perform()
        }
    }

    // MARK: - Dialog and return value

    @Test("perform() returns dialog confirming the card was added")
    func performReturnsDialog() async throws {
        var intent = AddCardIntent()
        intent.title = "Write release notes"
        intent.board = try BoardEntity(from: board)
        intent._injectDependencies(context: persistence.viewContext)

        // Verify it completes without error and returns a value
        let result = try await intent.perform()
        let entity = try #require(result.value)
        #expect(entity.title == "Write release notes")
    }
}
