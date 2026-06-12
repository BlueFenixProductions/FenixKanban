// Widgets/WidgetSnapshotReader.swift
//
// Foundation-only snapshot reader for the widget extension.
// Reads the JSON file written by BoardSnapshotWriter in the main app.
// No CoreData dependency — safe to compile in the extension sandbox.

import Foundation

struct WidgetSnapshotReader {
    static let appGroupIdentifier = "group.com.bluefenixproductions.FenixKanban"
    static let snapshotFileName = "board_snapshot.json"

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
