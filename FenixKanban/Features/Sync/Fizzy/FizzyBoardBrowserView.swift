import SwiftUI

/// Unified board browser (issue #18, Phase 7b). Reconciles local + remote
/// boards into one grouped list: Synced, Local only, On Fizzy only. Rows are a
/// pure projection of `FizzyBoardBrowserViewModel.rows` plus the per-board
/// activity registry (`provider.boardActivityRef`).
///
/// Phase 7b scope: paired rows are actionable (pause/resume, Sync Now, unpair).
/// Local-only / on-Fizzy-only rows are display-only; their Create-on-Fizzy /
/// Add-to-FK / Link actions land in Phase 7c.
struct FizzyBoardBrowserView: View {

    let provider: FizzySyncProvider
    @State private var model: FizzyBoardBrowserViewModel
    @State private var rowPendingUnpair: BoardBrowserRow?

    init(provider: FizzySyncProvider) {
        self.provider = provider
        _model = State(initialValue: FizzyBoardBrowserViewModel(provider: provider))
    }

    var body: some View {
        List {
            switch model.state {
            case .loading:
                Section { ProgressView("Loading boards…") }
            case .error(let message):
                Section {
                    SwiftUI.Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                rowSections
            case .loaded:
                rowSections
            }
        }
        .navigationTitle("Fizzy Boards")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.load() }
        .refreshable { await model.load() }
        .confirmationDialog(
            "Unpair this board?",
            isPresented: Binding(
                get: { rowPendingUnpair != nil },
                set: { if !$0 { rowPendingUnpair = nil } }
            ),
            presenting: rowPendingUnpair
        ) { row in
            Button("Unpair", role: .destructive) {
                model.unpair(row)
                rowPendingUnpair = nil
            }
            Button("Cancel", role: .cancel) { rowPendingUnpair = nil }
        } message: { _ in
            Text("Stops syncing this board. Your local cards are kept.")
        }
    }

    @ViewBuilder
    private var rowSections: some View {
        let paired = model.rows.filter { $0.kind == .paired }
        let localOnly = model.rows.filter { $0.kind == .localOnly }
        let remoteOnly = model.rows.filter { $0.kind == .remoteOnly }

        if !paired.isEmpty {
            Section("Synced") { ForEach(paired) { pairedRow($0) } }
        }
        if !localOnly.isEmpty {
            Section("Local only") { ForEach(localOnly) { simpleRow($0, caption: "Not on Fizzy") } }
        }
        if !remoteOnly.isEmpty {
            Section("On Fizzy only") { ForEach(remoteOnly) { simpleRow($0, caption: "Not in FenixKanban") } }
        }
    }

    @ViewBuilder
    private func pairedRow(_ row: BoardBrowserRow) -> some View {
        let phase = row.localBoardID.map { provider.boardActivityRef.phase(for: $0) } ?? .idle
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.title)
                    .foregroundStyle(row.syncEnabled ? .primary : .secondary)
                Spacer()
                trailing(for: phase, row: row)
            }
            if case .error(let msg) = phase {
                Text(msg).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { rowPendingUnpair = row } label: {
                SwiftUI.Label("Unpair", systemImage: "link.badge.minus")
            }
            Button { Task { await model.syncNow(row) } } label: {
                SwiftUI.Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button { Task { await model.syncNow(row) } } label: {
                SwiftUI.Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            Button { model.toggleSync(row) } label: {
                SwiftUI.Label(row.syncEnabled ? "Pause Sync" : "Resume Sync",
                              systemImage: row.syncEnabled ? "pause.circle" : "play.circle")
            }
            Button(role: .destructive) { rowPendingUnpair = row } label: {
                SwiftUI.Label("Unpair", systemImage: "link.badge.minus")
            }
        }
    }

    @ViewBuilder
    private func trailing(for phase: SyncActivityState.Phase, row: BoardBrowserRow) -> some View {
        switch phase {
        case .syncing:
            ProgressView().controlSize(.small)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle:
            if !row.syncEnabled {
                Text("Paused").font(.caption).foregroundStyle(.secondary)
            } else if let last = row.lastSyncAt {
                Text(last, style: .relative).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Not synced").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func simpleRow(_ row: BoardBrowserRow, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}
