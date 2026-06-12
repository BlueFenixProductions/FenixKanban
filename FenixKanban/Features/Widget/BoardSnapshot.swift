// FenixKanban/Features/Widget/BoardSnapshot.swift
//
// Shared data model between the main app and the FenixKanbanWidgets extension.
// Must be included in both targets (no dynamic linking across app extension boundary).
//
// Scope decision (issue #35): widget reads a shared JSON snapshot file, not
// the CoreData store directly. No App Group store relocation is performed.

import Foundation

/// Lightweight, Codable snapshot of a single board for the widget layer.
/// Written by `BoardSnapshotWriter` after each sync and after manual saves.
struct BoardSnapshot: Codable, Equatable {
    struct ColumnSummary: Codable, Equatable {
        let name: String
        let cardCount: Int
        /// Up to three card titles from the top of the column (by sortOrder,
        /// golden cards first — matching `Column.sortedCards` ordering).
        let topCardTitles: [String]
    }

    let boardName: String
    let columns: [ColumnSummary]
    let generatedAt: Date

    // MARK: - Coding

    enum CodingKeys: String, CodingKey {
        case boardName, columns, generatedAt
    }
}
