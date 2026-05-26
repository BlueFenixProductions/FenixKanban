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
            Section {
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
            } header: {
                Text("Export")
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
