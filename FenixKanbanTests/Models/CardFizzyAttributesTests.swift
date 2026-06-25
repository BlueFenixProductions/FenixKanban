import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("Card Fizzy sync attributes", .serialized)
@MainActor
struct CardFizzyAttributesTests {
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
        card = cardRepo.createCard(in: column, title: "T")
    }

    @Test("fizzyID, fizzyEtag, fizzyUpdatedAt all default to nil on insert")
    func defaultsAreNil() {
        #expect(card.fizzyID == nil)
        #expect(card.fizzyEtag == nil)
        #expect(card.fizzyUpdatedAt == nil)
    }

    @Test("fizzyID round-trips through save/refresh")
    func fizzyIDPersists() throws {
        card.fizzyID = "03f5vaeq985jlvwv3arl4srq2"
        try persistence.viewContext.save()
        persistence.viewContext.refresh(card, mergeChanges: false)
        #expect(card.fizzyID == "03f5vaeq985jlvwv3arl4srq2")
    }

    @Test("fizzyEtag round-trips through save/refresh")
    func fizzyEtagPersists() throws {
        card.fizzyEtag = "\"abc123\""
        try persistence.viewContext.save()
        persistence.viewContext.refresh(card, mergeChanges: false)
        #expect(card.fizzyEtag == "\"abc123\"")
    }

    @Test("fizzyNumber defaults to 0 (unset) and round-trips through save/refresh")
    func fizzyNumberPersists() throws {
        #expect(card.fizzyNumber == 0)
        card.fizzyNumber = 42
        try persistence.viewContext.save()
        persistence.viewContext.refresh(card, mergeChanges: false)
        #expect(card.fizzyNumber == 42)
    }

    @Test("fizzyUpdatedAt round-trips through save/refresh")
    func fizzyUpdatedAtPersists() throws {
        let date = Date(timeIntervalSince1970: 1_734_567_890)
        card.fizzyUpdatedAt = date
        try persistence.viewContext.save()
        persistence.viewContext.refresh(card, mergeChanges: false)
        let read = try #require(card.fizzyUpdatedAt)
        #expect(abs(read.timeIntervalSince(date)) < 0.001)
    }
}
