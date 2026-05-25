// FenixKanbanTests/Intents/FindGoldenCardsIntentTests.swift
import Testing
import CoreData
import Foundation
import AppIntents
@testable import FenixKanban

@Suite("FindGoldenCardsIntent", .serialized)
@MainActor
struct FindGoldenCardsIntentTests {
    let persistence: PersistenceController
    let boardRepo: BoardRepository
    let cardRepo: CardRepository

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        cardRepo = CardRepository(context: persistence.viewContext)
    }

    private func makeCard(in column: Column, title: String, golden: Bool) -> Card {
        let card = cardRepo.createCard(in: column, title: title)
        card.isGolden = golden
        try? persistence.viewContext.save()
        return card
    }

    @Test("Without a board param, returns all golden cards across boards")
    func allBoards() async throws {
        let bA = boardRepo.createBoard(name: "A")
        let cA = boardRepo.createColumn(in: bA, name: "C")
        let bB = boardRepo.createBoard(name: "B")
        let cB = boardRepo.createColumn(in: bB, name: "C")
        _ = makeCard(in: cA, title: "A-Gold", golden: true)
        _ = makeCard(in: cA, title: "A-Plain", golden: false)
        _ = makeCard(in: cB, title: "B-Gold", golden: true)

        var intent = FindGoldenCardsIntent()
        intent._injectDependencies(context: persistence.viewContext)
        let result = try await intent.perform()
        let titles = Set(result.value?.map(\.title) ?? [])
        #expect(titles == ["A-Gold", "B-Gold"])
    }

    @Test("With a board param, scopes results to that board")
    func boardScoped() async throws {
        let bA = boardRepo.createBoard(name: "A")
        let cA = boardRepo.createColumn(in: bA, name: "C")
        let bB = boardRepo.createBoard(name: "B")
        let cB = boardRepo.createColumn(in: bB, name: "C")
        _ = makeCard(in: cA, title: "A-Gold", golden: true)
        _ = makeCard(in: cB, title: "B-Gold", golden: true)

        var intent = FindGoldenCardsIntent()
        intent.board = try BoardEntity(from: bA)
        intent._injectDependencies(context: persistence.viewContext)
        let result = try await intent.perform()
        let titles = result.value?.map(\.title) ?? []
        #expect(titles == ["A-Gold"])
    }

    @Test("Empty when no golden cards exist")
    func emptyResult() async throws {
        let b = boardRepo.createBoard(name: "A")
        let c = boardRepo.createColumn(in: b, name: "C")
        _ = makeCard(in: c, title: "P", golden: false)

        var intent = FindGoldenCardsIntent()
        intent._injectDependencies(context: persistence.viewContext)
        let result = try await intent.perform()
        #expect((result.value ?? []).isEmpty)
    }
}
