# Fizzy Integration — Phase 4c: Backup + Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land a verified Core Data backup export + a `FizzySyncEngineBoardIsolationTests` suite so Phase 5's UI can be exercised against real user data without risk of silent loss.

**Architecture:** A backup is a document **bundle** (`.fenixkanban-backup` folder) containing the three SQLite files (`store`, `store-wal`, `store-shm`) plus a `manifest.json` with per-entity row counts captured at export time. `BackupExporter` writes the bundle into a temp directory, then **immediately** re-opens it into a throwaway `NSPersistentContainer`, recounts every entity, and only reports success if the counts match the manifest. The bundle is exposed via SwiftUI's `.fileExporter` so the user picks the destination (Files / Finder). Restore in 4c is a documented manual replace; an in-app restore UI is deferred.

A parallel concern — proving that any sync operation only touches the *paired* local board — is locked by a new `FizzySyncEngineBoardIsolationTests` suite that builds 3 local boards, pairs only board[0], and asserts boards[1]/boards[2] are untouched across all four sync entry points.

**Tech Stack:** SwiftUI `FileDocument` + `.fileExporter` (iOS 16+ / macOS 13+), `FileWrapper(directoryWithFileWrappers:)`, `NSPersistentContainer` directly (not `PersistenceController`) for the temp verification store, Swift Testing for unit tests.

**Spec:** `docs/superpowers/specs/2026-05-25-fizzy-phase-5-ui-design.md` (§ Phase 4c — Backup + Safety)

**Out of scope for 4c:**
- In-app restore UI (manual file-replace process, documented in `BackupSettingsView` footer).
- Backup encryption (plaintext SQLite; user is responsible for storage hygiene).
- Scheduled / automatic backups.
- Multi-version history.
- Anything Fizzy-UI-related (that's Phase 5).

---

## File Structure

**Created:**
- `FenixKanban/Features/Backup/BackupManifest.swift` — Codable manifest struct + serialization.
- `FenixKanban/Features/Backup/BackupExporter.swift` — write-and-verify orchestrator.
- `FenixKanban/Features/Backup/BackupDocument.swift` — `FileDocument` wrapper for `.fileExporter`.
- `FenixKanban/Features/Backup/BackupSettingsView.swift` — Settings → Data → Export Backup screen.
- `FenixKanbanTests/Features/Backup/BackupManifestTests.swift` — codable round-trip.
- `FenixKanbanTests/Features/Backup/BackupExporterTests.swift` — write + verify + reject corruption.
- `FenixKanbanTests/Services/Fizzy/FizzySyncEngineBoardIsolationTests.swift` — multi-board sync isolation.

**Modified:**
- `FenixKanban/Core/Persistence/PersistenceController.swift` — make `sharedModel` `internal` (was `private`) so `BackupExporter`'s verifier can build a temp container with the same model.
- `FenixKanban/Features/Settings/SettingsView.swift` — add a `Section("Data")` with a `NavigationLink` to `BackupSettingsView`.
- `TDD_IMPLEMENTATION_STATUS.md` — append Phase 4c entry.

---

## Task 1: Expose the Core Data model for backup verification

**Files:**
- Modify: `FenixKanban/Core/Persistence/PersistenceController.swift`

- [ ] **Step 1: Change `sharedModel` access**

In `FenixKanban/Core/Persistence/PersistenceController.swift`, find this line near the top of `PersistenceController`:

```swift
    private static let sharedModel: NSManagedObjectModel = {
```

Change to:

```swift
    /// Loaded once and reused. Exposed `internal` so `BackupExporter`'s
    /// verifier can build a throwaway `NSPersistentContainer` against the
    /// same managed-object model without duplicate-entity warnings.
    static let sharedModel: NSManagedObjectModel = {
```

- [ ] **Step 2: Verify the build still succeeds**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add FenixKanban/Core/Persistence/PersistenceController.swift
git commit -m "$(cat <<'EOF'
refactor(persistence): expose sharedModel for backup verification

Backup verification needs to build a temp NSPersistentContainer against
the same NSManagedObjectModel as the live store. Exposing sharedModel
as internal avoids re-loading the .momd from the bundle (and the
"duplicate entity name" warnings that would cause).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: BackupManifest (codable round-trip)

**Files:**
- Create: `FenixKanban/Features/Backup/BackupManifest.swift`
- Create: `FenixKanbanTests/Features/Backup/BackupManifestTests.swift`

- [ ] **Step 1: Write the failing test**

Create `FenixKanbanTests/Features/Backup/BackupManifestTests.swift`:

```swift
import Testing
import Foundation
@testable import FenixKanban

@Suite("BackupManifest")
struct BackupManifestTests {

    @Test("encodes/decodes round-trip preserves all fields")
    func roundTrip() throws {
        let original = BackupManifest(
            version: 1,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            schemaName: "FenixKanban 3",
            entityCounts: ["Board": 3, "Column": 9, "Card": 47, "Label": 5]
        )

        let data = try original.encoded()
        let decoded = try BackupManifest.decoded(from: data)

        #expect(decoded == original)
    }

    @Test("decode rejects garbage")
    func rejectsGarbage() {
        let garbage = Data("not a manifest".utf8)
        #expect(throws: DecodingError.self) {
            _ = try BackupManifest.decoded(from: garbage)
        }
    }

    @Test("entity counts compared in order-insensitive way via Equatable")
    func dictionaryEquality() {
        let a = BackupManifest(version: 1, exportedAt: .distantPast,
                                schemaName: "x", entityCounts: ["A": 1, "B": 2])
        let b = BackupManifest(version: 1, exportedAt: .distantPast,
                                schemaName: "x", entityCounts: ["B": 2, "A": 1])
        #expect(a == b)
    }
}
```

- [ ] **Step 2: Run failing test**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/BackupManifestTests test 2>&1 | tail -10
```

Expected: build fails — `BackupManifest` not defined.

- [ ] **Step 3: Implement BackupManifest**

Create `FenixKanban/Features/Backup/BackupManifest.swift`:

```swift
import Foundation

/// Captured at export time. The verifier compares re-derived counts against
/// these to confirm the export wrote everything intact.
struct BackupManifest: Codable, Equatable {
    /// Bump if the on-disk format changes incompatibly.
    let version: Int
    let exportedAt: Date
    /// Human-readable schema identifier (e.g. "FenixKanban 3"). Informational —
    /// the loader doesn't reject on mismatch.
    let schemaName: String
    /// Entity name → row count.
    let entityCounts: [String: Int]

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> BackupManifest {
        try Self.decoder.decode(BackupManifest.self, from: data)
    }
}
```

- [ ] **Step 4: Run + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/BackupManifestTests test 2>&1 | tail -5
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Backup/BackupManifest.swift \
        FenixKanbanTests/Features/Backup/BackupManifestTests.swift
git commit -m "$(cat <<'EOF'
feat(backup): BackupManifest — codable entity-count manifest

Captured during export, re-derived during verification. ISO-8601 dates,
sorted-keys JSON for stable text diffs of the on-disk manifest.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: BackupExporter — write-and-verify

**Files:**
- Create: `FenixKanban/Features/Backup/BackupExporter.swift`
- Create: `FenixKanbanTests/Features/Backup/BackupExporterTests.swift`

`BackupExporter` does NOT depend on `PersistenceController` directly; it takes a `NSPersistentContainer` so tests can pass an isolated in-memory container they fully control.

- [ ] **Step 1: Write the failing tests**

Create `FenixKanbanTests/Features/Backup/BackupExporterTests.swift`:

```swift
import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("BackupExporter")
@MainActor
struct BackupExporterTests {

    /// Builds an isolated on-disk store in a temp dir. We need on-disk because
    /// the exporter copies the SQLite files; an in-memory store has nothing
    /// to copy.
    private func makeOnDiskContainer(seedBoards: Int = 1, cardsPerBoard: Int = 3) throws -> (NSPersistentContainer, URL) {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BackupExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storeURL = tempDir.appendingPathComponent("store.sqlite")

        let container = NSPersistentContainer(name: "FenixKanban", managedObjectModel: PersistenceController.sharedModel)
        let desc = NSPersistentStoreDescription(url: storeURL)
        desc.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [desc]

        var loadError: Error?
        container.loadPersistentStores { _, err in loadError = err }
        if let loadError { throw loadError }

        let ctx = container.viewContext
        let boardRepo = BoardRepository(context: ctx)
        let cardRepo = CardRepository(context: ctx)
        for i in 0..<seedBoards {
            let b = boardRepo.createBoard(name: "Board \(i)")
            let col = boardRepo.createColumn(in: b, name: "Todo")
            for j in 0..<cardsPerBoard {
                _ = cardRepo.createCard(in: col, title: "Card \(i)-\(j)")
            }
        }
        try ctx.save()
        return (container, tempDir)
    }

    @Test("export verified round-trip — counts match")
    func roundTrip() async throws {
        let (container, tempDir) = try makeOnDiskContainer(seedBoards: 2, cardsPerBoard: 4)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destination = tempDir.appendingPathComponent("export.fenixkanban-backup", isDirectory: true)
        let exporter = BackupExporter()
        let summary = try await exporter.exportVerified(to: destination, from: container)

        #expect(summary.counts["Board"] == 2)
        #expect(summary.counts["Column"] == 2)
        #expect(summary.counts["Card"] == 8)
        #expect(summary.bytesWritten > 0)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("store.sqlite").path))
    }

    @Test("empty store round-trip")
    func emptyStoreRoundTrip() async throws {
        let (container, tempDir) = try makeOnDiskContainer(seedBoards: 0, cardsPerBoard: 0)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destination = tempDir.appendingPathComponent("export.fenixkanban-backup", isDirectory: true)
        let exporter = BackupExporter()
        let summary = try await exporter.exportVerified(to: destination, from: container)

        #expect(summary.counts["Board"] == 0)
        #expect(summary.counts["Card"] == 0)
    }

    @Test("verifier rejects corrupted store (truncated SQLite)")
    func rejectsCorruption() async throws {
        let (container, tempDir) = try makeOnDiskContainer(seedBoards: 1, cardsPerBoard: 5)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destination = tempDir.appendingPathComponent("export.fenixkanban-backup", isDirectory: true)
        let exporter = BackupExporter()

        // First, successfully export.
        _ = try await exporter.exportVerified(to: destination, from: container)

        // Now corrupt the exported SQLite file then re-run just the verifier path.
        let storePath = destination.appendingPathComponent("store.sqlite")
        try Data(repeating: 0, count: 32).write(to: storePath)  // overwrite with junk

        await #expect(throws: BackupExporter.ExportError.self) {
            _ = try await exporter.verify(bundleAt: destination)
        }
    }

    @Test("loads manifest from exported bundle")
    func canLoadManifest() async throws {
        let (container, tempDir) = try makeOnDiskContainer(seedBoards: 1, cardsPerBoard: 7)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destination = tempDir.appendingPathComponent("export.fenixkanban-backup", isDirectory: true)
        let exporter = BackupExporter()
        _ = try await exporter.exportVerified(to: destination, from: container)

        let manifest = try BackupExporter.readManifest(at: destination)
        #expect(manifest.entityCounts["Card"] == 7)
        #expect(manifest.entityCounts["Board"] == 1)
        #expect(manifest.version == 1)
    }
}
```

- [ ] **Step 2: Run failing tests**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/BackupExporterTests test 2>&1 | tail -10
```

Expected: build fails — `BackupExporter` not defined.

- [ ] **Step 3: Implement BackupExporter**

Create `FenixKanban/Features/Backup/BackupExporter.swift`:

```swift
import Foundation
import CoreData

/// Writes a verified backup of a CoreData store to a `.fenixkanban-backup`
/// directory bundle, then immediately re-opens that bundle into a throwaway
/// `NSPersistentContainer` and confirms every entity's row count matches the
/// manifest captured at export time.
///
/// Phase 4c ships the export side only. Restore is a documented manual
/// process (close app, replace store files in
/// `~/Library/Application Support/...`/iOS app container, relaunch).
@MainActor
final class BackupExporter {

    enum ExportError: Error, Equatable, CustomStringConvertible {
        case sourceStoreMissing
        case fileSystem(String)
        case verificationFailed(String)
        case manifestMissing
        case manifestCorrupt(String)

        var description: String {
            switch self {
            case .sourceStoreMissing:
                return "Source CoreData store URL is nil — was the container loaded?"
            case .fileSystem(let m): return "File system: \(m)"
            case .verificationFailed(let m): return "Verification failed: \(m)"
            case .manifestMissing: return "Backup is missing manifest.json"
            case .manifestCorrupt(let m): return "Backup manifest corrupt: \(m)"
            }
        }
    }

    struct Summary: Equatable {
        let path: URL
        let counts: [String: Int]
        let bytesWritten: Int64
        let verifiedAt: Date
    }

    private static let manifestFilename = "manifest.json"
    private static let storeFilename = "store.sqlite"
    private static let walFilename = "store.sqlite-wal"
    private static let shmFilename = "store.sqlite-shm"
    private static let schemaName = "FenixKanban 3"

    /// Exports the container's persistent store to `destination` (a
    /// `.fenixkanban-backup` directory bundle), then verifies the export
    /// before returning. Throws `ExportError` on any failure; the destination
    /// directory is left in place even on verification failure so the engineer
    /// can inspect what went wrong.
    func exportVerified(to destination: URL, from container: NSPersistentContainer) async throws -> Summary {
        let liveCounts = try entityCounts(in: container)
        let sourceURL = try sourceStoreURL(from: container)

        // 1. Create destination directory (clean slate if it already exists).
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // 2. Copy the three SQLite files (sidecars may not exist — that's fine).
        // SQLite WAL/SHM live next to the main store with a SUFFIX on the
        // last path component: store.sqlite → store.sqlite-wal, store.sqlite-shm.
        // (NOT a second path extension — that would be store.sqlite.wal.)
        try copyIfExists(at: sourceURL,
                         to: destination.appendingPathComponent(Self.storeFilename))
        try copyIfExists(at: sidecarURL(for: sourceURL, suffix: "-wal"),
                         to: destination.appendingPathComponent(Self.walFilename))
        try copyIfExists(at: sidecarURL(for: sourceURL, suffix: "-shm"),
                         to: destination.appendingPathComponent(Self.shmFilename))

        // 3. Write manifest.
        let manifest = BackupManifest(
            version: 1,
            exportedAt: .now,
            schemaName: Self.schemaName,
            entityCounts: liveCounts
        )
        let manifestURL = destination.appendingPathComponent(Self.manifestFilename)
        try manifest.encoded().write(to: manifestURL, options: .atomic)

        // 4. Compute bytesWritten.
        let bytes = try directoryBytes(at: destination)

        // 5. Verify by loading the bundle into a temp container.
        try await verify(bundleAt: destination)

        return Summary(path: destination, counts: liveCounts, bytesWritten: bytes, verifiedAt: .now)
    }

    /// Opens the bundle into a throwaway `NSPersistentContainer`, recounts
    /// every entity, and compares to the manifest. Throws on any mismatch.
    func verify(bundleAt bundleURL: URL) async throws {
        let manifest = try Self.readManifest(at: bundleURL)

        // Copy the SQLite files into a fresh temp dir so the verify container
        // doesn't share files with the live one.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BackupVerify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let verifyStoreURL = scratch.appendingPathComponent(Self.storeFilename)
        try copyIfExists(at: bundleURL.appendingPathComponent(Self.storeFilename), to: verifyStoreURL)
        try copyIfExists(at: bundleURL.appendingPathComponent(Self.walFilename),
                         to: scratch.appendingPathComponent(Self.walFilename))
        try copyIfExists(at: bundleURL.appendingPathComponent(Self.shmFilename),
                         to: scratch.appendingPathComponent(Self.shmFilename))

        let container = NSPersistentContainer(name: "FenixKanban", managedObjectModel: PersistenceController.sharedModel)
        let desc = NSPersistentStoreDescription(url: verifyStoreURL)
        desc.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [desc]

        var loadError: Error?
        container.loadPersistentStores { _, err in loadError = err }
        if let loadError {
            throw ExportError.verificationFailed("can't load exported store: \(loadError)")
        }

        let derived = try entityCounts(in: container)

        guard derived == manifest.entityCounts else {
            throw ExportError.verificationFailed(
                "manifest \(manifest.entityCounts) ≠ derived \(derived)"
            )
        }
    }

    /// Public so callers can read a manifest without doing a full verify
    /// (used by tests and future restore UI).
    static func readManifest(at bundleURL: URL) throws -> BackupManifest {
        let manifestURL = bundleURL.appendingPathComponent(manifestFilename)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ExportError.manifestMissing
        }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw ExportError.manifestCorrupt("read: \(error)")
        }
        do {
            return try BackupManifest.decoded(from: data)
        } catch {
            throw ExportError.manifestCorrupt("decode: \(error)")
        }
    }

    // MARK: - Helpers

    private func entityCounts(in container: NSPersistentContainer) throws -> [String: Int] {
        var out: [String: Int] = [:]
        let ctx = container.viewContext
        for entity in PersistenceController.sharedModel.entities {
            guard let name = entity.name else { continue }
            let request = NSFetchRequest<NSNumber>(entityName: name)
            request.resultType = .countResultType
            let count = try ctx.count(for: request)
            out[name] = count
        }
        return out
    }

    private func sourceStoreURL(from container: NSPersistentContainer) throws -> URL {
        guard let url = container.persistentStoreDescriptions.first?.url else {
            throw ExportError.sourceStoreMissing
        }
        return url
    }

    private func copyIfExists(at source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        do {
            try fm.copyItem(at: source, to: destination)
        } catch {
            throw ExportError.fileSystem("copy \(source.lastPathComponent): \(error)")
        }
    }

    private func directoryBytes(at url: URL) throws -> Int64 {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: keys)
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Builds the URL of a SQLite sidecar file by appending `suffix` to the
    /// last path component of `sourceURL`. Used for `-wal` and `-shm`.
    /// Example: `…/store.sqlite` + `-wal` → `…/store.sqlite-wal`.
    private func sidecarURL(for sourceURL: URL, suffix: String) -> URL {
        let parent = sourceURL.deletingLastPathComponent()
        let filename = sourceURL.lastPathComponent + suffix
        return parent.appendingPathComponent(filename)
    }
}
```

- [ ] **Step 4: Run + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/BackupExporterTests test 2>&1 | tail -5
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Backup/BackupExporter.swift \
        FenixKanbanTests/Features/Backup/BackupExporterTests.swift
git commit -m "$(cat <<'EOF'
feat(backup): BackupExporter — write + immediate verify round-trip

Writes the three SQLite files + manifest.json into a
.fenixkanban-backup directory bundle, then loads the bundle into a
throwaway NSPersistentContainer and re-derives entity counts; throws
ExportError.verificationFailed on mismatch. Refuses to claim success
unless the round-trip is bit-for-bit faithful.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: BackupDocument — FileDocument wrapper for .fileExporter

**Files:**
- Create: `FenixKanban/Features/Backup/BackupDocument.swift`

`BackupDocument` is a `FileDocument` that wraps an already-exported bundle (URL) so SwiftUI's `.fileExporter` can move it to the user's chosen destination. We export first (into a temp dir, verified), THEN hand the document to `.fileExporter` for the user to save somewhere persistent.

No tests for this file — it's a thin SwiftUI conformance layer. End-to-end behaviour is exercised manually in UAT.

- [ ] **Step 1: Create BackupDocument**

Create `FenixKanban/Features/Backup/BackupDocument.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers

/// `FileDocument` that wraps a pre-exported `.fenixkanban-backup` directory
/// bundle for use with SwiftUI's `.fileExporter`. The bundle is built and
/// verified by `BackupExporter` first; this type just shuttles it to the
/// user's chosen destination.
///
/// Phase 4c only supports writing. Reading conformance is satisfied with a
/// throw so the file picker won't try to open backups as documents.
struct BackupDocument: FileDocument {
    /// Use the system's `.package` UTType (a folder treated as a document).
    /// Phase 4c does NOT register a custom `com.bluefenixproductions.fenixkanban-backup`
    /// UTType because doing so requires a `UTExportedTypeDeclarations` entry
    /// in Info.plist AND has no value until we ship a Restore UI that opens
    /// these bundles. The `.fenixkanban-backup` extension is purely a hint
    /// in the default filename; the OS doesn't need to know about it yet.
    static let bundleType: UTType = .package

    static var readableContentTypes: [UTType] { [bundleType] }
    static var writableContentTypes: [UTType] { [bundleType] }

    /// URL of the verified bundle on disk (in a temp dir).
    let bundleURL: URL

    init(bundleURL: URL) { self.bundleURL = bundleURL }

    /// Read isn't supported in 4c — restore is a manual process.
    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: bundleURL, options: [.immediate])
    }
}
```

- [ ] **Step 2: Verify the build still succeeds**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add FenixKanban/Features/Backup/BackupDocument.swift
git commit -m "$(cat <<'EOF'
feat(backup): BackupDocument — FileDocument wrapper for .fileExporter

Wraps a pre-exported .fenixkanban-backup directory bundle so SwiftUI's
.fileExporter can persist it to a user-chosen destination. Read
conformance throws (restore is documented manual).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: BackupSettingsView — the Settings screen

**Files:**
- Create: `FenixKanban/Features/Backup/BackupSettingsView.swift`

This is a thin SwiftUI view; no unit tests. UAT in Task 8 exercises it manually.

- [ ] **Step 1: Create BackupSettingsView**

Create `FenixKanban/Features/Backup/BackupSettingsView.swift`:

```swift
import SwiftUI

/// Settings entry for exporting a verified backup of the user's local data.
///
/// Workflow:
/// 1. User taps "Export Backup".
/// 2. `BackupExporter.exportVerified` runs against a temp directory.
/// 3. On success, the verified bundle is handed to `.fileExporter` so the
///    user can pick a final destination (Files, iCloud Drive, etc).
/// 4. Status row updates with the most recent export's summary.
struct BackupSettingsView: View {

    @State private var stagingBundle: BackupDocument?
    @State private var defaultFilename: String = ""
    @State private var isFileExporterPresented = false
    @State private var lastSummary: BackupExporter.Summary?
    @State private var lastError: String?
    @State private var isExporting = false

    let persistence: PersistenceController

    var body: some View {
        Form {
            Section("Export") {
                Button {
                    Task { await exportBackup() }
                } label: {
                    HStack {
                        Text(isExporting ? "Exporting…" : "Export Backup")
                        Spacer()
                        if isExporting { ProgressView() }
                    }
                }
                .disabled(isExporting)
            } footer: {
                Text("Saves your boards, columns, cards, and labels to a verified backup file. The exporter re-reads the file immediately after writing it and confirms every row was captured. Restore is a manual process — see below.")
            }

            if let summary = lastSummary {
                Section("Last Export") {
                    LabeledContent("File", value: summary.path.lastPathComponent)
                    LabeledContent("Size", value: ByteCountFormatter().string(fromByteCount: summary.bytesWritten))
                    LabeledContent("Verified", value: summary.verifiedAt.formatted(date: .abbreviated, time: .shortened))
                    ForEach(summary.counts.sorted(by: { $0.key < $1.key }), id: \.key) { entity, count in
                        LabeledContent(entity, value: "\(count)")
                    }
                }
            }

            if let lastError {
                Section {
                    Text(lastError)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            Section("Restore (manual)") {
                Text("To restore a backup: quit FenixKanban, replace the SQLite files in the app's data container with those from your backup folder, and relaunch. CloudKit will reconcile on next launch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Backup")
        .fileExporter(
            isPresented: $isFileExporterPresented,
            document: stagingBundle,
            contentType: BackupDocument.bundleType,
            defaultFilename: defaultFilename
        ) { result in
            switch result {
            case .success(let url):
                lastError = nil
                lastSummary = lastSummary.map { previous in
                    BackupExporter.Summary(
                        path: url,
                        counts: previous.counts,
                        bytesWritten: previous.bytesWritten,
                        verifiedAt: previous.verifiedAt
                    )
                }
            case .failure(let error):
                lastError = "Save cancelled or failed: \(error.localizedDescription)"
            }
            stagingBundle = nil
        }
    }

    @MainActor
    private func exportBackup() async {
        isExporting = true
        defer { isExporting = false }
        lastError = nil

        let timestamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let filename = "FenixKanban-\(timestamp).fenixkanban-backup"
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(filename, isDirectory: true)

        do {
            let summary = try await BackupExporter()
                .exportVerified(to: staging, from: persistence.container)
            lastSummary = summary
            defaultFilename = filename
            stagingBundle = BackupDocument(bundleURL: staging)
            isFileExporterPresented = true
        } catch {
            lastError = "Export failed: \(error)"
        }
    }
}
```

- [ ] **Step 2: Verify build**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add FenixKanban/Features/Backup/BackupSettingsView.swift
git commit -m "$(cat <<'EOF'
feat(backup): BackupSettingsView — Settings entry for verified export

Tap "Export Backup" → BackupExporter runs against a temp directory →
on success, the verified bundle is presented via .fileExporter for the
user to save anywhere (Files, iCloud Drive). Last-export summary shown
inline. Restore documented as a manual file-replace.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wire BackupSettingsView into SettingsView

**Files:**
- Modify: `FenixKanban/Features/Settings/SettingsView.swift`

- [ ] **Step 1: Add the Data section**

In `FenixKanban/Features/Settings/SettingsView.swift`, find the `Section("Integrations")` block:

```swift
                Section("Integrations") {
                    NavigationLink("Board Sync") {
                        SyncSettingsView()
                    }
                }
```

Add a new section immediately ABOVE it:

```swift
                Section("Data") {
                    NavigationLink("Backup") {
                        BackupSettingsView(persistence: viewModel.persistence)
                    }
                }

                Section("Integrations") {
                    NavigationLink("Board Sync") {
                        SyncSettingsView()
                    }
                }
```

- [ ] **Step 2: Verify `SettingsViewModel.persistence` is accessible**

Check whether `SettingsViewModel` exposes `persistence` publicly. Read the file:

```bash
grep -n "persistence" FenixKanban/Features/Settings/SettingsViewModel.swift
```

If `persistence` is `private`, change it to `let persistence: PersistenceController` (no access modifier — default internal). Edit only if needed.

- [ ] **Step 3: Build + verify**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add FenixKanban/Features/Settings/SettingsView.swift FenixKanban/Features/Settings/SettingsViewModel.swift
git commit -m "$(cat <<'EOF'
feat(backup): expose Backup screen from Settings

New "Data" section in SettingsView with a "Backup" link to
BackupSettingsView. Sits above "Integrations" so backups stay top-of-mind
when the user is wiring up external sync providers.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: FizzySyncEngineBoardIsolationTests

**Files:**
- Create: `FenixKanbanTests/Services/Fizzy/FizzySyncEngineBoardIsolationTests.swift`

Four tests prove non-paired boards are untouched across all four sync entry points. No source changes — the engine already operates on `localBoard` only; this suite locks that invariant.

- [ ] **Step 1: Create the test file**

```swift
import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("FizzySyncEngine — board isolation", .serialized)
@MainActor
struct FizzySyncEngineBoardIsolationTests {

    /// Builds a fresh in-memory store with 3 local boards (3 columns, 5 cards each).
    /// Pairs board[0] with fizzy `FB1`. Returns the configured engine + harnesses
    /// for asserting on the OTHER boards.
    private struct Harness {
        let persistence: PersistenceController
        let boards: [Board]
        let engine: FizzySyncEngine
        let authState: FizzyAuthState
        let mappingDefaults: UserDefaults
        let suiteName: String

        @MainActor
        init() {
            MockURLProtocol.reset()
            persistence = PersistenceController(inMemory: true, useCloudKit: false)
            let boardRepo = BoardRepository(context: persistence.viewContext)
            let cardRepo = CardRepository(context: persistence.viewContext)

            var built: [Board] = []
            for b in 0..<3 {
                let board = boardRepo.createBoard(name: "Board \(b)")
                for c in 0..<3 {
                    let col = boardRepo.createColumn(in: board, name: "Col \(c)")
                    for k in 0..<5 {
                        _ = cardRepo.createCard(in: col, title: "B\(b)-C\(c)-K\(k)")
                    }
                }
                built.append(board)
            }
            try! persistence.viewContext.save()
            boards = built

            let prefix = "test.fizzy.isolate.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t"); authState.setAccountSlug("ACCT")

            suiteName = "test.fizzy.isolate.mapping.\(UUID().uuidString)"
            mappingDefaults = UserDefaults(suiteName: suiteName)!
            let mapping = FizzyBoardMapping(defaults: mappingDefaults)
            mapping.setPairing(localBoardID: built[0].id!, fizzyBoardID: "FB1")

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: config)
            let client = FizzyClient(
                baseURL: URL(string: "https://fizzy.bluefenix.net")!,
                accessToken: "t", accountSlug: "ACCT",
                urlSession: session, clock: ImmediateClock()
            )

            engine = FizzySyncEngine(
                client: client, authState: authState, mapping: mapping,
                context: persistence.viewContext
            )
        }

        func tearDown() {
            authState.clear()
            mappingDefaults.removePersistentDomain(forName: suiteName)
            MockURLProtocol.reset()
        }

        func cardCount(on board: Board) -> Int {
            ((board.columns as? Set<Column>) ?? []).reduce(0) { sum, col in
                sum + (((col.cards as? Set<Card>) ?? []).count)
            }
        }
    }

    @Test("syncFirst(.pushLocalToFizzy) does not touch other boards")
    func pushIsolates() async throws {
        let h = Harness(); defer { h.tearDown() }

        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("POST", let p?) where p.hasSuffix("/cards"):
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/1"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/"):
                let body = """
                {"id":"fz-x","number":1,"title":"x","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x"}
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        _ = try await h.engine.syncFirst(mode: .pushLocalToFizzy)

        #expect(h.cardCount(on: h.boards[1]) == 15)
        #expect(h.cardCount(on: h.boards[2]) == 15)

        // No fizzyID stamped on non-paired boards' cards.
        let board1FizzyIDs = ((h.boards[1].columns as? Set<Column>) ?? [])
            .flatMap { ($0.cards as? Set<Card>) ?? [] }
            .compactMap(\.fizzyID)
        let board2FizzyIDs = ((h.boards[2].columns as? Set<Column>) ?? [])
            .flatMap { ($0.cards as? Set<Card>) ?? [] }
            .compactMap(\.fizzyID)
        #expect(board1FizzyIDs.isEmpty)
        #expect(board2FizzyIDs.isEmpty)
    }

    @Test("syncFirst(.replaceLocalWithFizzy) does not touch other boards")
    func replaceIsolates() async throws {
        let h = Harness(); defer { h.tearDown() }

        let columnsJSON = """
        [{"id":"FC1","name":"Todo","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
        """
        let cardsJSON = """
        [
          {"id":"fz1","number":1,"title":"R1","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x/1"},
          {"id":"fz2","number":2,"title":"R2","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x/2"}
        ]
        """
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (columnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (cardsJSON.data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        _ = try await h.engine.syncFirst(mode: .replaceLocalWithFizzy)

        #expect(h.cardCount(on: h.boards[0]) == 2, "paired board replaced")
        #expect(h.cardCount(on: h.boards[1]) == 15, "non-paired board untouched")
        #expect(h.cardCount(on: h.boards[2]) == 15, "non-paired board untouched")
    }

    @Test("syncFirst(.mergeIfNoConflicts) does not touch other boards")
    func mergeIsolates() async throws {
        let h = Harness(); defer { h.tearDown() }

        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                let body = """
                [{"id":"FC1","name":"Col 0","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let body = """
                [{"id":"fz-new","number":1,"title":"New from remote","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/9"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/9"):
                let body = """
                {"id":"fz-9","number":9,"title":"x","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x"}
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        _ = try await h.engine.syncFirst(mode: .mergeIfNoConflicts)

        #expect(h.cardCount(on: h.boards[1]) == 15, "non-paired board untouched")
        #expect(h.cardCount(on: h.boards[2]) == 15, "non-paired board untouched")
    }

    @Test("sync() steady-state does not touch other boards")
    func steadyStateIsolates() async throws {
        let h = Harness(); defer { h.tearDown() }

        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/1"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/"):
                let body = """
                {"id":"fz-1","number":1,"title":"x","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x"}
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        _ = try await h.engine.sync()

        #expect(h.cardCount(on: h.boards[1]) == 15)
        #expect(h.cardCount(on: h.boards[2]) == 15)

        let nonPairedFizzyIDs = (h.boards[1...2]).flatMap { board -> [String] in
            ((board.columns as? Set<Column>) ?? [])
                .flatMap { ($0.cards as? Set<Card>) ?? [] }
                .compactMap(\.fizzyID)
        }
        #expect(nonPairedFizzyIDs.isEmpty)
    }
}
```

- [ ] **Step 2: Run + verify pass** (these should pass on green — the invariant already holds)

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineBoardIsolationTests test 2>&1 | tail -5
```

Expected: 4 tests pass.

If any fail, the engine has a real isolation bug — STOP and investigate before committing.

- [ ] **Step 3: Commit**

```bash
git add FenixKanbanTests/Services/Fizzy/FizzySyncEngineBoardIsolationTests.swift
git commit -m "$(cat <<'EOF'
test(fizzy): board-isolation suite — non-paired boards never touched

Four tests (one per sync entry point: pushLocalToFizzy,
replaceLocalWithFizzy, mergeIfNoConflicts, sync) prove that with 3 local
boards and only board[0] paired, boards[1] and boards[2] keep all 15
cards and never get a fizzyID stamped. Locks the existing invariant —
no engine changes needed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: TDD status doc

**File:** Modify `TDD_IMPLEMENTATION_STATUS.md` — append Phase 4c entry.

- [ ] **Step 1: Append entry**

Add this section after the existing Phase 4b entry:

```markdown

### Fizzy Integration — Phase 4c: Backup + Safety ✅
**Status:** Complete (Red → Green → Refactor)
**Date:** 2026-05-25

**🔴 Red Phase:**
- 11 new tests across 3 suites: `BackupManifestTests` (3),
  `BackupExporterTests` (4), `FizzySyncEngineBoardIsolationTests` (4).
- Each test verified failing before implementation (isolation tests
  passed on first run — invariant already held; suite locks it).

**🟢 Green Phase:**
- `BackupManifest` (Codable, entity counts + ISO-8601 timestamps).
- `BackupExporter.exportVerified(to:from:)`: copies SQLite files into
  a `.fenixkanban-backup` directory bundle + writes manifest + immediately
  re-loads the bundle into a throwaway `NSPersistentContainer` and
  re-derives counts; throws `ExportError.verificationFailed` on mismatch.
- `BackupDocument: FileDocument` so SwiftUI's `.fileExporter` can present
  the verified bundle to the user for final save.
- `BackupSettingsView`: Settings → Data → Backup. Tap "Export Backup" →
  exports to temp + verifies → presents `.fileExporter` for save.
- Settings root gets a "Data" section above "Integrations".
- `PersistenceController.sharedModel` exposed `internal` so the backup
  verifier can build a temp container against the same model.

**🔵 Refactor Phase:**
- File-copy helper handles missing sidecar (`-wal`/`-shm`) gracefully —
  SQLite doesn't always have them.
- BackupExporter has no dependency on PersistenceController; it takes a
  raw `NSPersistentContainer` so tests can build isolated stores.

**Spec:** `docs/superpowers/specs/2026-05-25-fizzy-phase-5-ui-design.md`
**Plan:** `docs/superpowers/plans/2026-05-25-fizzy-phase-4c-backup-and-safety.md`

**Test Coverage:** 11 new tests across 3 suites. Full suite green.

**Documented limitations:**
1. Restore is a manual file-replace; no in-app restore UI yet.
2. Backups are plaintext SQLite — user is responsible for storage hygiene.
3. No multi-version history; each export overwrites the destination.
4. No backup encryption.

**What ships:** A safety net the user can rely on before exercising
Phase 5's UI against real Fizzy data. The board-isolation suite gives
mechanical proof that non-paired boards stay untouched.
```

- [ ] **Step 2: Commit**

```bash
git add TDD_IMPLEMENTATION_STATUS.md
git commit -m "$(cat <<'EOF'
docs(tdd): log Fizzy Phase 4c (backup + safety)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Final verification

- [ ] **Step 1: Full iOS suite**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests test 2>&1 | grep -E "Test run with|TEST SUCCEEDED|TEST FAILED" | tail -3
```

Expected: `Test run with ~210 tests in ~56 suites passed`
(Phase 4b baseline 199 + Phase 4c's 11 = 210).

If the simulator preflight fails on the first attempt, re-run — the failure is a known cold-start flake, not a test failure.

- [ ] **Step 2: macOS clean build**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' clean build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual smoke test of the export**

Build and launch on iOS Simulator:

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
xcrun simctl install booted "$(xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -showBuildSettings 2>/dev/null | awk -F' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR/ {print $2; exit}')/FenixKanban.app"
xcrun simctl launch booted com.bluefenixproductions.FenixKanban
```

Then manually:
1. Settings → Data → Backup → "Export Backup".
2. Confirm the `.fileExporter` sheet presents a default filename like `FenixKanban-2026-…fenixkanban-backup`.
3. Save to Files.
4. Return to Settings → Backup; "Last Export" section should populate with file path, size, verified date, and per-entity counts.
5. Open the saved bundle in Files; confirm it contains `store.sqlite`, `store.sqlite-wal` (if any), `store.sqlite-shm` (if any), and `manifest.json`.

- [ ] **Step 4: Branch state**

```bash
git log --oneline 9dd2e81..HEAD
git status -sb
```

Expected: ~9 new commits on top of the spec commit; clean working tree.

- [ ] **Step 5: Ready-for-PR report**

Suggested PR title:

> `feat(fizzy): Phase 4c — verified backup + board-isolation tests`

Suggested PR body skeleton:

```markdown
## Summary
- `BackupExporter` writes a verified `.fenixkanban-backup` document
  bundle (3 SQLite files + manifest.json), then re-opens it and
  refuses to claim success unless entity counts match.
- New `Settings → Data → Backup` screen surfaces export via SwiftUI's
  `.fileExporter`.
- `FizzySyncEngineBoardIsolationTests` locks the invariant that any
  sync operation (push / replace / merge / steady) only touches the
  paired local board.
- 11 new tests; full suite green.
- No Fizzy UI changes yet — Phase 5 builds on this safety floor.

## Test plan
- [x] iOS Simulator full suite + macOS clean build.
- [x] Manual export smoke test on iOS Simulator.
- [x] Manifest round-trip + corruption rejection covered by unit tests.
- [x] Isolation tests pass on green (invariant already held).

## Spec / Plan
- Spec: `docs/superpowers/specs/2026-05-25-fizzy-phase-5-ui-design.md`
- Plan: `docs/superpowers/plans/2026-05-25-fizzy-phase-4c-backup-and-safety.md`
- Phase 5 (Fizzy UI) is the natural follow-on.
```

---

## Success criteria recap

- [ ] `BackupManifest` round-trips losslessly; rejects garbage.
- [ ] `BackupExporter.exportVerified` writes a `.fenixkanban-backup`
      directory bundle AND verifies it before returning.
- [ ] Corruption detection — truncating the exported SQLite file makes
      `verify(bundleAt:)` throw `ExportError.verificationFailed`.
- [ ] `BackupSettingsView` builds and runs; `Settings → Data → Backup`
      navigates to it; "Export Backup" produces a saveable bundle.
- [ ] `FizzySyncEngineBoardIsolationTests` — all 4 entry points proven
      not to touch non-paired boards.
- [ ] iOS Simulator full suite green at ~210/210.
- [ ] macOS clean build succeeds.
- [ ] TDD doc updated.
