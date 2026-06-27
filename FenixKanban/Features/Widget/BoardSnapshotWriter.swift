// FenixKanban/Features/Widget/BoardSnapshotWriter.swift

import Foundation
import CoreData

/// Indicates where the snapshot was successfully written.
enum SnapshotWriteLocation: Equatable {
    /// Written to the shared App Group container (readable by the widget extension).
    case appGroup
    /// Fell back to Application Support because the App Group container was
    /// unavailable (e.g., entitlement not present in dev builds / CI).
    case applicationSupport
}

/// Errors thrown by `BoardSnapshotWriter`.
enum SnapshotWriteError: Error {
    case encodingFailed(underlying: Error)
    case noContainerURL
    case writeFailed(underlying: Error)
}

/// Serialises the "first board" (by sortOrder) into a JSON snapshot file and
/// writes it into the shared App Group container. Falls back to Application
/// Support when the group container is unavailable so nothing crashes in dev
/// or CI environments that lack the entitlement.
///
/// The file is always named `board_snapshot.json` inside whichever container
/// is used so the widget can locate it without extra negotiation.
struct BoardSnapshotWriter {
    static let appGroupIdentifier = "group.com.bluefenixproductions.FenixKanban"
    static let snapshotFileName = "board_snapshot.json"

    private let context: NSManagedObjectContext
    private let fileManager: FileManager

    init(context: NSManagedObjectContext, fileManager: FileManager = .default) {
        self.context = context
        self.fileManager = fileManager
    }

    // MARK: - Public API

    /// Builds a `BoardSnapshot` for the first board (by sortOrder), encodes it
    /// to JSON, and writes it to the appropriate container.
    ///
    /// - Returns: The location where the snapshot was written.
    /// - Throws: `SnapshotWriteError` on encode / IO failure.
    @discardableResult
    func writeSnapshot() throws -> SnapshotWriteLocation {
        let snapshot = try buildSnapshot()
        return try persist(snapshot: snapshot)
    }

    // MARK: - Internal helpers (exposed internal for tests)

    func buildSnapshot() throws -> BoardSnapshot {
        var snapshot: BoardSnapshot?
        var thrownError: Error?

        context.performAndWait {
            do {
                let request = Board.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(keyPath: \Board.sortOrder, ascending: true)]
                request.fetchLimit = 1
                let boards = try context.fetch(request)

                guard let board = boards.first else {
                    snapshot = BoardSnapshot(boardName: "", columns: [], generatedAt: Date())
                    return
                }

                let columnSummaries: [BoardSnapshot.ColumnSummary] = board.sortedColumns.map { column in
                    let sorted = column.sortedCards
                    let topTitles = sorted.prefix(3).compactMap { $0.title }
                    return BoardSnapshot.ColumnSummary(
                        name: column.name ?? "Untitled",
                        cardCount: sorted.count,
                        topCardTitles: Array(topTitles)
                    )
                }

                snapshot = BoardSnapshot(
                    boardName: board.name ?? "Untitled Board",
                    columns: columnSummaries,
                    generatedAt: Date()
                )
            } catch {
                thrownError = error
            }
        }

        if let error = thrownError { throw error }
        return snapshot!
    }

    func persist(snapshot: BoardSnapshot) throws -> SnapshotWriteLocation {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            throw SnapshotWriteError.encodingFailed(underlying: error)
        }

        // Try App Group container first.
        if let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) {
            let fileURL = groupURL.appendingPathComponent(Self.snapshotFileName)
            do {
                try data.write(to: fileURL, options: .atomic)
                return .appGroup
            } catch {
                // Fall through to Application Support on write failure.
            }
        }

        // Fallback: Application Support directory.
        let appSupportURL: URL
        do {
            appSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw SnapshotWriteError.noContainerURL
        }

        let fileURL = appSupportURL.appendingPathComponent(Self.snapshotFileName)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw SnapshotWriteError.writeFailed(underlying: error)
        }
        return .applicationSupport
    }

    // MARK: - Read helper (used by widget)

    /// Reads the most recently written snapshot from either the App Group
    /// container or Application Support, returning `nil` if neither exists or
    /// the JSON cannot be decoded.
    static func readSnapshot(fileManager: FileManager = .default) -> BoardSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Try App Group first.
        if let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            let fileURL = groupURL.appendingPathComponent(snapshotFileName)
            if let data = try? Data(contentsOf: fileURL),
               let snapshot = try? decoder.decode(BoardSnapshot.self, from: data) {
                return snapshot
            }
        }

        // Fallback: Application Support.
        if let appSupportURL = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            let fileURL = appSupportURL.appendingPathComponent(snapshotFileName)
            if let data = try? Data(contentsOf: fileURL),
               let snapshot = try? decoder.decode(BoardSnapshot.self, from: data) {
                return snapshot
            }
        }

        return nil
    }
}
