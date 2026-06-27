import SwiftUI

/// Merge-warning picker for "Link existing ↔ existing" (issue #18, Phase 7c).
/// Lists unpaired remote boards; choosing one runs a **merge** first-sync.
/// Shared by the Fizzy board browser and the per-board sync menu.
struct LinkBoardSheet: View {
    let localBoardName: String
    let candidates: [RemoteBoard]
    let onLink: (RemoteBoard) -> Void
    let onCancel: () -> Void

    @State private var picked: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Fizzy board", selection: $picked) {
                        Text("Choose…").tag(String?.none)
                        ForEach(candidates) { board in
                            Text(board.name).tag(board.id as String?)
                        }
                    }
                } header: {
                    Text("Link \u{201C}\(localBoardName)\u{201D} to")
                } footer: {
                    Text("Merges both boards: local-only and Fizzy-only cards are combined. Same-title cards are reported and skipped, not overwritten. Try the Sandbox board first.")
                        .foregroundStyle(.orange)
                }
                Section {
                    Button("Link & Merge") {
                        if let id = picked, let board = candidates.first(where: { $0.id == id }) {
                            onLink(board)
                        }
                    }
                    .disabled(picked == nil)
                }
            }
            .navigationTitle("Link Board")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}
