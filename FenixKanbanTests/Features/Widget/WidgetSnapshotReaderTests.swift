// FenixKanbanTests/Features/Widget/WidgetSnapshotReaderTests.swift
//
// Verifies that BoardSnapshot (the shared Codable model) correctly decodes the
// canonical wire shape produced by the app and consumed by WidgetSnapshotReader.
//
// Why here, not in a widget-extension test target? WidgetSnapshotReader lives in
// the FenixKanbanWidgets extension target (not @testable from FenixKanban), but
// BoardSnapshot — the model both sides share — is in the main app. Testing the
// JSON fixture here validates that the serialisation contract between writer and
// reader doesn't silently break. Any real decode regression will also break the
// existing BoardSnapshotWriterTests round-trip, so coverage is symmetric.

import Testing
import Foundation
@testable import FenixKanban

@Suite("BoardSnapshot wire-shape")
struct WidgetSnapshotReaderTests {

    // MARK: - Helpers

    /// Loads board_snapshot.json from the test bundle and decodes it exactly as
    /// WidgetSnapshotReader.readSnapshot() does in production.
    ///
    /// Mirrors the fixture-loading pattern used by FizzySyncEngineTests: try the
    /// bundle resource index first (works in CI build-for-testing), then fall back
    /// to the source-tree path via #file (works when resources aren't bundled into
    /// the .xctest, which is the case for CODE_SIGNING_ALLOWED=NO local runs).
    private static func decodeFixture(file: StaticString = #file) throws -> BoardSnapshot {
        let bundle = Bundle(for: BundleLocator.self)

        // 1. Bundle resource index (preferred: CI, production test runs).
        let bundleURL = bundle.url(forResource: "board_snapshot", withExtension: "json")
                     ?? bundle.url(forResource: "board_snapshot", withExtension: "json",
                                   subdirectory: "Fixtures")

        // 2. Source-tree fallback via #file (local dev with CODE_SIGNING_ALLOWED=NO).
        let fileURL: URL? = {
            guard bundleURL == nil else { return nil }
            let srcURL = URL(fileURLWithPath: "\(file)")
            // WidgetSnapshotReaderTests.swift is at
            //   .../FenixKanbanTests/Features/Widget/WidgetSnapshotReaderTests.swift
            // board_snapshot.json is at
            //   .../FenixKanbanTests/Fixtures/board_snapshot.json
            let fixturesDir = srcURL
                .deletingLastPathComponent()  // Widget/
                .deletingLastPathComponent()  // Features/
                .deletingLastPathComponent()  // FenixKanbanTests/
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("board_snapshot.json")
            return FileManager.default.fileExists(atPath: fixturesDir.path) ? fixturesDir : nil
        }()

        guard let resolvedURL = bundleURL ?? fileURL else {
            throw FixtureError.fileNotFound
        }
        let data = try Data(contentsOf: resolvedURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BoardSnapshot.self, from: data)
    }

    enum FixtureError: Error {
        case fileNotFound
    }

    // MARK: - Fixture decode (wire-shape test)

    @Test("board_snapshot.json fixture decodes to correct BoardSnapshot fields")
    func fixtureDecodesCorrectly() throws {
        let snapshot = try Self.decodeFixture()

        #expect(snapshot.boardName == "Sprint Board")
        #expect(snapshot.columns.count == 3)
        #expect(snapshot.columns[0].name == "Backlog")
        #expect(snapshot.columns[0].cardCount == 4)
        #expect(snapshot.columns[0].topCardTitles.count == 3)
        #expect(snapshot.columns[0].topCardTitles[0] == "Write unit tests")
        #expect(snapshot.columns[1].name == "In Progress")
        #expect(snapshot.columns[1].cardCount == 2)
        #expect(snapshot.columns[2].name == "Done")
        #expect(snapshot.columns[2].cardCount == 7)
    }

    @Test("board_snapshot.json fixture generatedAt parses as expected ISO-8601 date")
    func fixtureGeneratedAtIsValidDate() throws {
        let snapshot = try Self.decodeFixture()

        let formatter = ISO8601DateFormatter()
        let referenceDate = try #require(formatter.date(from: "2026-06-12T10:00:00Z"))
        #expect(snapshot.generatedAt == referenceDate)
    }
}

// MARK: - Bundle locator

/// Empty class used solely to resolve the test bundle via `Bundle(for:)`.
private final class BundleLocator {}
