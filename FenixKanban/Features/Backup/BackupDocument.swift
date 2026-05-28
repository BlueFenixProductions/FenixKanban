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

    // Write-only document — readableContentTypes intentionally empty so the
    // system never routes "Open with" actions to this type. `init(configuration:)`
    // throws anyway, but advertising zero capability prevents user-facing
    // confusion if a UTType registration ever appears in Info.plist.
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [bundleType] }

    /// URL of the verified bundle on disk (in a temp dir).
    let bundleURL: URL

    init(bundleURL: URL) { self.bundleURL = bundleURL }

    /// Read isn't supported in 4c — restore is a manual process.
    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Use `[]` (lazy) rather than `.immediate` so SwiftUI's .fileExporter
        // streams the bundle to its destination instead of reading the entire
        // directory tree into memory on the main thread. Backups can reach
        // hundreds of MB with a heavily-used CoreData store + WAL.
        try FileWrapper(url: bundleURL, options: [])
    }
}
