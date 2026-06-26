// FenixKanbanTests/Features/Widget/WidgetBoardDataTests.swift
//
// Exercises the REAL production mapping `makeWidgetBoardData(from:)` that the
// widget extension uses to turn the App Group CoreData store into the value
// type its SwiftUI views render. The mapping lives in Widgets/WidgetBoardData.swift,
// which is compiled into BOTH the FenixKanbanWidgets target and this test target
// (guarded by the WIDGET_EXTENSION compilation condition), so this test covers the
// exact code path the widget runs — not a parallel reimplementation.
//
// Semantics under test mirror the legacy BoardSnapshotWriter.buildSnapshot():
//   - first Board by sortOrder ascending,
//   - per column (board.sortedColumns) → name, cardCount, top-3 titles,
//   - card ordering is golden-first then sortOrder (Column.sortedCards),
//   - nil when there is no board.

import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("WidgetBoardData mapping", .serialized)
struct WidgetBoardDataTests {

    // MARK: - Helpers

    /// Builds a hermetic in-memory CoreData stack on the shared model so we can
    /// seed Board/Column/Card graphs without touching disk, iCloud, or the App
    /// Group container.
    private func makeInMemoryContext() -> NSManagedObjectContext {
        let container = NSPersistentContainer(
            name: "FenixKanban",
            managedObjectModel: PersistenceController.sharedModel
        )
        let description = NSPersistentStoreDescription()
        description.url = URL(fileURLWithPath: "/dev/null")
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            precondition(error == nil, "in-memory store failed to load: \(String(describing: error))")
        }
        return container.viewContext
    }

    @discardableResult
    private func makeBoard(_ name: String, sortOrder: Int32, in context: NSManagedObjectContext) -> Board {
        let board = Board(context: context)
        board.id = UUID()
        board.name = name
        board.sortOrder = sortOrder
        return board
    }

    @discardableResult
    private func makeColumn(_ name: String?, sortOrder: Int32, board: Board, in context: NSManagedObjectContext) -> Column {
        let column = Column(context: context)
        column.id = UUID()
        column.name = name
        column.sortOrder = sortOrder
        column.board = board
        return column
    }

    @discardableResult
    private func makeCard(_ title: String, sortOrder: Int32, isGolden: Bool = false, column: Column, in context: NSManagedObjectContext) -> Card {
        let card = Card(context: context)
        card.id = UUID()
        card.title = title
        card.sortOrder = sortOrder
        card.isGolden = isGolden
        card.column = column
        return card
    }

    // MARK: - Tests

    @Test("maps board name and orders columns by sortOrder")
    func mapsBoardNameAndColumnOrder() throws {
        let context = makeInMemoryContext()
        let board = makeBoard("My Board", sortOrder: 0, in: context)
        // Intentionally insert out of order; mapping must sort by sortOrder.
        makeColumn("Done", sortOrder: 2000, board: board, in: context)
        makeColumn("Todo", sortOrder: 0, board: board, in: context)
        makeColumn("In Progress", sortOrder: 1000, board: board, in: context)
        try context.save()

        let data = try #require(makeWidgetBoardData(from: context))

        #expect(data.boardName == "My Board")
        #expect(data.columns.map(\.name) == ["Todo", "In Progress", "Done"])
    }

    @Test("counts cards per column")
    func cardCountsPerColumn() throws {
        let context = makeInMemoryContext()
        let board = makeBoard("Counts", sortOrder: 0, in: context)
        let todo = makeColumn("Todo", sortOrder: 0, board: board, in: context)
        let done = makeColumn("Done", sortOrder: 1000, board: board, in: context)
        makeCard("A", sortOrder: 0, column: todo, in: context)
        makeCard("B", sortOrder: 1000, column: todo, in: context)
        makeCard("C", sortOrder: 0, column: done, in: context)
        try context.save()

        let data = try #require(makeWidgetBoardData(from: context))

        #expect(data.columns[0].cardCount == 2)
        #expect(data.columns[1].cardCount == 1)
    }

    @Test("top card titles are golden-first then sortOrder, capped at 3")
    func topCardTitlesGoldenFirstCappedAtThree() throws {
        let context = makeInMemoryContext()
        let board = makeBoard("Golden", sortOrder: 0, in: context)
        let todo = makeColumn("Todo", sortOrder: 0, board: board, in: context)
        // 5 cards: a golden one buried at the highest sortOrder must surface first,
        // and only the first 3 (golden-first, then by sortOrder) become titles.
        makeCard("First", sortOrder: 0, column: todo, in: context)
        makeCard("Second", sortOrder: 1000, column: todo, in: context)
        makeCard("Third", sortOrder: 2000, column: todo, in: context)
        makeCard("Fourth", sortOrder: 3000, column: todo, in: context)
        makeCard("GoldenLast", sortOrder: 4000, isGolden: true, column: todo, in: context)
        try context.save()

        let data = try #require(makeWidgetBoardData(from: context))

        #expect(data.columns[0].cardCount == 5)
        // Golden card outranks sortOrder; remainder follow by sortOrder; capped at 3.
        #expect(data.columns[0].topCardTitles == ["GoldenLast", "First", "Second"])
    }

    @Test("selects the first board by sortOrder ascending")
    func selectsFirstBoardBySortOrder() throws {
        let context = makeInMemoryContext()
        // Insert the higher-sortOrder board first to prove ordering, not ins't order.
        let second = makeBoard("Second Board", sortOrder: 1000, in: context)
        makeColumn("Z", sortOrder: 0, board: second, in: context)
        let first = makeBoard("First Board", sortOrder: 0, in: context)
        makeColumn("A", sortOrder: 0, board: first, in: context)
        try context.save()

        let data = try #require(makeWidgetBoardData(from: context))

        #expect(data.boardName == "First Board")
        #expect(data.columns.map(\.name) == ["A"])
    }

    @Test("falls back to placeholder names for nil board/column names")
    func fallbackNames() throws {
        let context = makeInMemoryContext()
        // `name` is a required attribute, so seed valid names and save, then null
        // them out in the registered (unsaved) objects. The mapping fetch includes
        // pending changes, so it observes the nil values and must fall back —
        // mirroring how the generated `String?` accessors can hand back nil.
        let board = makeBoard("placeholder-probe", sortOrder: 0, in: context)
        let column = makeColumn("placeholder-col", sortOrder: 0, board: board, in: context)
        try context.save()

        board.name = nil
        column.name = nil

        let data = try #require(makeWidgetBoardData(from: context))

        #expect(data.boardName == "Untitled Board")
        #expect(data.columns[0].name == "Untitled")
    }

    @Test("returns nil when there is no board")
    func nilWhenNoBoard() throws {
        let context = makeInMemoryContext()

        #expect(makeWidgetBoardData(from: context) == nil)
    }
}
