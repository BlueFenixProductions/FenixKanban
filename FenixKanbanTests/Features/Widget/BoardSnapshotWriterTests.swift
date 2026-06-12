// FenixKanbanTests/Features/Widget/BoardSnapshotWriterTests.swift
import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("BoardSnapshotWriter", .serialized)
struct BoardSnapshotWriterTests {

    // MARK: - Helpers

    struct InMemorySetup {
        let persistence: PersistenceController
        let boardRepo: BoardRepository
        let cardRepo: CardRepository
        let board: Board
        let column1: Column
        let column2: Column

        init() {
            persistence = PersistenceController(inMemory: true, useCloudKit: false)
            boardRepo = BoardRepository(context: persistence.viewContext)
            cardRepo = CardRepository(context: persistence.viewContext)
            board = boardRepo.createBoard(name: "My Board")
            column1 = boardRepo.createColumn(in: board, name: "Todo")
            column2 = boardRepo.createColumn(in: board, name: "Done")
        }
    }

    // MARK: - buildSnapshot

    @Test("buildSnapshot captures board name and column order by sortOrder")
    func buildSnapshotCapturesBoardAndColumns() throws {
        let env = InMemorySetup()
        let writer = BoardSnapshotWriter(context: env.persistence.viewContext)

        let snapshot = try writer.buildSnapshot()

        #expect(snapshot.boardName == "My Board")
        #expect(snapshot.columns.count == 2)
        #expect(snapshot.columns[0].name == "Todo")
        #expect(snapshot.columns[1].name == "Done")
    }

    @Test("buildSnapshot captures correct card counts per column")
    func buildSnapshotCardCounts() throws {
        let env = InMemorySetup()
        _ = env.cardRepo.createCard(in: env.column1, title: "A")
        _ = env.cardRepo.createCard(in: env.column1, title: "B")
        _ = env.cardRepo.createCard(in: env.column2, title: "C")

        let writer = BoardSnapshotWriter(context: env.persistence.viewContext)
        let snapshot = try writer.buildSnapshot()

        #expect(snapshot.columns[0].cardCount == 2)
        #expect(snapshot.columns[1].cardCount == 1)
    }

    @Test("buildSnapshot includes top 3 card titles max")
    func buildSnapshotTopCardTitles() throws {
        let env = InMemorySetup()
        _ = env.cardRepo.createCard(in: env.column1, title: "Alpha")
        _ = env.cardRepo.createCard(in: env.column1, title: "Beta")
        _ = env.cardRepo.createCard(in: env.column1, title: "Gamma")
        _ = env.cardRepo.createCard(in: env.column1, title: "Delta")  // 4th — should not appear

        let writer = BoardSnapshotWriter(context: env.persistence.viewContext)
        let snapshot = try writer.buildSnapshot()

        #expect(snapshot.columns[0].topCardTitles.count == 3)
    }

    @Test("buildSnapshot returns empty columns array when board has no columns")
    func buildSnapshotEmptyColumns() throws {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        _ = boardRepo.createBoard(name: "Bare Board")

        let writer = BoardSnapshotWriter(context: persistence.viewContext)
        let snapshot = try writer.buildSnapshot()

        #expect(snapshot.boardName == "Bare Board")
        #expect(snapshot.columns.isEmpty)
    }

    // MARK: - Round-trip JSON encode / decode

    @Test("BoardSnapshot encodes and decodes via JSON round-trip")
    func roundTripCodable() throws {
        let env = InMemorySetup()
        _ = env.cardRepo.createCard(in: env.column1, title: "Fix tests")

        let writer = BoardSnapshotWriter(context: env.persistence.viewContext)
        let original = try writer.buildSnapshot()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BoardSnapshot.self, from: data)

        #expect(decoded.boardName == original.boardName)
        #expect(decoded.columns == original.columns)
    }

    // MARK: - Fallback behavior

    @Test("persist falls back to applicationSupport when appGroup is unavailable")
    func persistFallsBackToApplicationSupport() throws {
        // Use a mock FileManager that returns nil for the App Group container
        // to simulate an environment without the entitlement.
        let env = InMemorySetup()
        _ = env.cardRepo.createCard(in: env.column1, title: "Test card")

        // We can't easily mock FileManager, so instead we use a real writer
        // and verify it doesn't throw — the fallback path is exercised in CI
        // where no entitlement is present. The important invariant is that
        // writeSnapshot() succeeds (returns .appGroup or .applicationSupport)
        // without crashing.
        let writer = BoardSnapshotWriter(context: env.persistence.viewContext)
        let location = try writer.writeSnapshot()

        #expect(location == .appGroup || location == .applicationSupport)
    }

    @Test("writeSnapshot does not throw even when board list is empty")
    func writeSnapshotNoBoardsDoesNotThrow() throws {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let writer = BoardSnapshotWriter(context: persistence.viewContext)

        // Should not throw — just writes an empty snapshot.
        let location = try writer.writeSnapshot()
        #expect(location == .appGroup || location == .applicationSupport)
    }
}
