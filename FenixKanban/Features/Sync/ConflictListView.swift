import SwiftUI

/// Shows all open LWW conflicts requiring user resolution (task #70).
/// Stock SwiftUI — no custom .background on chrome surfaces.
struct ConflictListView: View {
    let provider: FizzySyncProvider
    @State private var conflicts: [ConflictRecord] = []
    @State private var selectedConflict: ConflictRecord?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if conflicts.isEmpty {
                ContentUnavailableView(
                    "No Conflicts",
                    systemImage: "checkmark.circle",
                    description: Text("All sync conflicts have been resolved.")
                )
            } else {
                ForEach(conflicts) { conflict in
                    Button {
                        selectedConflict = conflict
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(conflict.localTitle)
                                    .font(.body)
                                Text("Remote: \(conflict.remoteTitle)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                                .imageScale(.small)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
        .navigationTitle("Conflicts")
        .task {
            conflicts = provider.conflicts()
        }
        .sheet(item: $selectedConflict) { conflict in
            ConflictCardSheet(
                conflict: conflict,
                provider: provider
            ) {
                // Refresh list after resolution
                conflicts = provider.conflicts()
                selectedConflict = nil
            }
        }
    }
}

/// Per-card conflict resolution sheet: shows local vs remote title/description
/// side-by-side with Keep Mine / Take Theirs buttons.
struct ConflictCardSheet: View {
    let conflict: ConflictRecord
    let provider: FizzySyncProvider
    let onResolved: () -> Void

    @State private var isResolving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Your Version") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(conflict.localTitle)
                            .font(.headline)
                        if let desc = conflict.localDescription {
                            Text(desc)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Remote Version") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(conflict.remoteTitle)
                            .font(.headline)
                        if let desc = conflict.remoteDescription {
                            Text(desc)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }

                Section {
                    Button(action: { resolve(keepMine: true) }) {
                        HStack {
                            Image(systemName: "person.fill.checkmark")
                            Text("Keep Mine")
                        }
                    }
                    .disabled(isResolving)

                    Button(action: { resolve(keepMine: false) }) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Take Theirs")
                        }
                    }
                    .disabled(isResolving)
                }
            }
            .navigationTitle("Resolve Conflict")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if isResolving {
                    ProgressView()
                }
            }
        }
    }

    private func resolve(keepMine: Bool) {
        isResolving = true
        errorMessage = nil
        Task {
            do {
                if keepMine {
                    try await provider.resolveKeepMine(cardID: conflict.id)
                } else {
                    try await provider.resolveTakeTheirs(cardID: conflict.id)
                }
                onResolved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isResolving = false
        }
    }
}
