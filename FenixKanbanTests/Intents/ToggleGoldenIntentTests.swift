// FenixKanbanTests/Intents/ToggleGoldenIntentTests.swift
import Testing
import CoreData
import Foundation
import AppIntents
@testable import FenixKanban

@Suite("ToggleGoldenIntent", .serialized)
@MainActor
struct ToggleGoldenIntentTests {
    let persistence: PersistenceController
    let boardRepo: BoardRepository
    let cardRepo: CardRepository
    let card: Card

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "B")
        let column = boardRepo.createColumn(in: board, name: "C")
        card = cardRepo.createCard(in: column, title: "Pay rent")
    }

    @Test("perform() flips isGolden and returns the updated entity")
    func performToggles() async throws {
        var intent = ToggleGoldenIntent()
        intent.card = try CardEntity(from: card)
        intent._injectDependencies(context: persistence.viewContext)

        let result = try await intent.perform()
        #expect(result.value?.isGolden == true)

        let result2 = try await intent.perform()
        #expect(result2.value?.isGolden == false)
    }

    @Test("perform() throws needsValueError when card no longer exists")
    func performMissingCardThrows() async throws {
        var intent = ToggleGoldenIntent()
        intent.card = CardEntity(
            id: UUID(),
            title: "Ghost",
            cardDescription: nil,
            dueDate: nil,
            isCompleted: false,
            isGolden: false
        )
        intent._injectDependencies(context: persistence.viewContext)

        await #expect(throws: (any Error).self) {
            _ = try await intent.perform()
        }
    }
}
