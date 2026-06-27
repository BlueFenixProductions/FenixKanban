import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("Tombstone entities + Column fizzy attributes", .serialized)
@MainActor
struct TombstoneEntitiesTests {
    let persistence: PersistenceController
    let boardRepo: BoardRepository
    let cardRepo: CardRepository
    let board: Board
    let column: Column
    let pairingStore = FizzyCardPairingStore(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
    )

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext, pairingStore: pairingStore)
        cardRepo = CardRepository(context: persistence.viewContext, pairingStore: pairingStore)
        board = boardRepo.createBoard(name: "B")
        column = boardRepo.createColumn(in: board, name: "C")
    }

    private func cardTombstones() throws -> [CardTombstone] {
        let request: NSFetchRequest<CardTombstone> = CardTombstone.fetchRequest()
        return try persistence.viewContext.fetch(request)
    }

    private func columnTombstones() throws -> [ColumnTombstone] {
        let request: NSFetchRequest<ColumnTombstone> = ColumnTombstone.fetchRequest()
        return try persistence.viewContext.fetch(request)
    }

    @Test("Column.fizzyColumnID defaults to nil and round-trips through save/refresh")
    func columnFizzyColumnIDPersists() throws {
        #expect(column.fizzyColumnID == nil)
        column.fizzyColumnID = "03f5vb0p7c2k9qq0lsn9ohcm"
        try persistence.viewContext.save()
        persistence.viewContext.refresh(column, mergeChanges: false)
        #expect(column.fizzyColumnID == "03f5vb0p7c2k9qq0lsn9ohcm")
    }

    @Test("CardTombstone round-trips fizzyNumber + deletedAt")
    func cardTombstoneRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_734_567_890)
        let tombstone = CardTombstone(context: persistence.viewContext)
        tombstone.fizzyNumber = 42
        tombstone.deletedAt = date
        try persistence.viewContext.save()
        persistence.viewContext.refresh(tombstone, mergeChanges: false)
        #expect(tombstone.fizzyNumber == 42)
        let read = try #require(tombstone.deletedAt)
        #expect(abs(read.timeIntervalSince(date)) < 0.001)
    }

    @Test("ColumnTombstone round-trips fizzyColumnID, boardID, deletedAt")
    func columnTombstoneRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_734_567_890)
        let tombstone = ColumnTombstone(context: persistence.viewContext)
        tombstone.fizzyColumnID = "FC1"
        tombstone.boardID = "BOARD-UUID"
        tombstone.deletedAt = date
        try persistence.viewContext.save()
        persistence.viewContext.refresh(tombstone, mergeChanges: false)
        #expect(tombstone.fizzyColumnID == "FC1")
        #expect(tombstone.boardID == "BOARD-UUID")
        let read = try #require(tombstone.deletedAt)
        #expect(abs(read.timeIntervalSince(date)) < 0.001)
    }

    @Test("deleteCard on a fizzy-paired card writes a CardTombstone")
    func deletePairedCardWritesTombstone() throws {
        let card = cardRepo.createCard(in: column, title: "Paired")
        try persistence.viewContext.save()
        pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fz1", fizzyNumber: 7, fizzyUpdatedAt: .now),
            for: card.id!
        )

        cardRepo.deleteCard(card)

        let tombstones = try cardTombstones()
        #expect(tombstones.count == 1)
        #expect(tombstones.first?.fizzyNumber == 7)
        #expect(tombstones.first?.deletedAt != nil)
    }

    @Test("deleteCard on an unpaired card writes no tombstone")
    func deleteUnpairedCardWritesNoTombstone() throws {
        let card = cardRepo.createCard(in: column, title: "Local only")
        try persistence.viewContext.save()

        cardRepo.deleteCard(card)

        #expect(try cardTombstones().isEmpty)
    }

    @Test("deleteColumn on a fizzy-paired column writes a ColumnTombstone with the local board ID")
    func deletePairedColumnWritesTombstone() throws {
        column.fizzyColumnID = "FC1"
        try persistence.viewContext.save()

        boardRepo.deleteColumn(column)

        let tombstones = try columnTombstones()
        #expect(tombstones.count == 1)
        #expect(tombstones.first?.fizzyColumnID == "FC1")
        #expect(tombstones.first?.boardID == board.id?.uuidString)
        #expect(tombstones.first?.deletedAt != nil)
    }

    @Test("deleteColumn also tombstones the column's fizzy-paired cards (cascade)")
    func deleteColumnTombstonesPairedCards() throws {
        column.fizzyColumnID = "FC1"
        let paired = cardRepo.createCard(in: column, title: "Paired")
        _ = cardRepo.createCard(in: column, title: "Unpaired")
        try persistence.viewContext.save()
        pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fz9", fizzyNumber: 9, fizzyUpdatedAt: .now),
            for: paired.id!
        )

        boardRepo.deleteColumn(column)

        let tombstones = try cardTombstones()
        #expect(tombstones.count == 1)
        #expect(tombstones.first?.fizzyNumber == 9)
    }

    @Test("deleteColumn on an unpaired column writes no ColumnTombstone")
    func deleteUnpairedColumnWritesNoTombstone() throws {
        boardRepo.deleteColumn(column)
        #expect(try columnTombstones().isEmpty)
    }
}
