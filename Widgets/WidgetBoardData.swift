// Widgets/WidgetBoardData.swift
//
// The value type the board widget's SwiftUI views render, plus the Board →
// WidgetBoardData mapping that turns a live CoreData context (the App Group
// store, read-only, opened by WidgetBoardReader) into it.
//
// Dual membership: this file is compiled into BOTH the FenixKanbanWidgets
// extension target AND the FenixKanbanTests target. In the widget the entity
// classes + NSManagedObject extensions are compiled in-module, so no app import
// is needed. In the test target the entities and the (internal) sort/count
// extensions are reached via `@testable import FenixKanban`. The
// WIDGET_EXTENSION compilation condition (set on the widget target only) picks
// the right path, so the unit test exercises the exact production mapping.

import CoreData
#if !WIDGET_EXTENSION
@testable import FenixKanban
#endif

/// A plain, non-Codable summary of a single board for the widget layer.
/// Same shape the UI consumed from `BoardSnapshot`, minus the Codable /
/// `generatedAt` plumbing (the widget now reads CoreData directly).
struct WidgetBoardData {
    let boardName: String
    let columns: [ColumnSummary]

    struct ColumnSummary {
        let name: String
        let cardCount: Int
        /// Up to three card titles from the top of the column, golden cards
        /// first then by sortOrder (matching `Column.sortedCards`).
        let topCardTitles: [String]
    }
}

/// Builds a `WidgetBoardData` for the first board (by `sortOrder` ascending)
/// in `context`, or returns `nil` when there is no board (the widget view
/// renders a "No board data" empty state in that case).
///
/// Replicates `BoardSnapshotWriter.buildSnapshot()` semantics exactly:
/// per column (`board.sortedColumns`) the name falls back to "Untitled",
/// `cardCount` is the full count, and `topCardTitles` is the first three
/// non-nil titles of `column.sortedCards` (golden-first ordering comes free).
func makeWidgetBoardData(from context: NSManagedObjectContext) -> WidgetBoardData? {
    var result: WidgetBoardData?

    context.performAndWait {
        let request = Board.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Board.sortOrder, ascending: true)]
        request.fetchLimit = 1

        guard let board = (try? context.fetch(request))?.first else {
            return
        }

        let columnSummaries: [WidgetBoardData.ColumnSummary] = board.sortedColumns.map { column in
            let sorted = column.sortedCards
            let topTitles = sorted.prefix(3).compactMap { $0.title }
            return WidgetBoardData.ColumnSummary(
                name: column.name ?? "Untitled",
                cardCount: sorted.count,
                topCardTitles: Array(topTitles)
            )
        }

        result = WidgetBoardData(
            boardName: board.name ?? "Untitled Board",
            columns: columnSummaries
        )
    }

    return result
}
