import SwiftUI

/// Unified board browser (issue #18, Phase 7b). Reconciles local + remote
/// boards into one grouped list: Synced, Local only, On Fizzy only. Rows are a
/// pure projection of `FizzyBoardBrowserViewModel.rows` plus the per-board
/// activity registry (`provider.boardActivityRef`).
///
/// Phase 7b: paired rows are actionable (pause/resume, Sync Now, unpair).
/// Phase 7c: local-only rows offer Create-on-Fizzy + Link; on-Fizzy-only rows
/// offer Add-to-FK. The single-pair `FizzyAuthView` flow is unchanged.
struct FizzyBoardBrowserView: View {

    let provider: FizzySyncProvider
    @State private var model: FizzyBoardBrowserViewModel
    @State private var rowPendingUnpair: BoardBrowserRow?
    @State private var linkSourceRow: BoardBrowserRow?

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
        .sheet(item: $linkSourceRow) { localRow in
            LinkBoardSheet(
                localBoardName: localRow.title,
                candidates: model.unpairedRemoteBoards,
                onLink: { remote in
                    linkSourceRow = nil
                    Task { await model.linkExisting(localRow, toFizzyBoardID: remote.id, fizzyBoardName: remote.name) }
                },
                onCancel: { linkSourceRow = nil }
            )
        }
        .alert("Sync problem", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.dismissActionError() } }
        )) {
            Button("OK", role: .cancel) { model.dismissActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
        .alert("Merged with collisions", isPresented: Binding(
            get: { model.lastLinkCollisions != nil },
            set: { if !$0 { model.dismissLinkCollisions() } }
        )) {
            Button("OK", role: .cancel) { model.dismissLinkCollisions() }
        } message: {
            Text((model.lastLinkCollisions ?? []).prefix(8).joined(separator: "\n"))
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
            Section("Local only") { ForEach(localOnly) { localOnlyRow($0) } }
        }
        if !remoteOnly.isEmpty {
            Section("On Fizzy only") { ForEach(remoteOnly) { remoteOnlyRow($0) } }
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
    private func localOnlyRow(_ row: BoardBrowserRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                Text("Not on Fizzy").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button { Task { await model.createOnFizzy(row) } } label: {
                    SwiftUI.Label("Create on Fizzy", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered).controlSize(.small)
                if !model.unpairedRemoteBoards.isEmpty {
                    Button { linkSourceRow = row } label: {
                        SwiftUI.Label("Link…", systemImage: "link")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private func remoteOnlyRow(_ row: BoardBrowserRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                Text("Not in FenixKanban").font(.caption).foregroundStyle(.secondary)
            }
            Button { Task { await model.addToFK(row) } } label: {
                SwiftUI.Label("Add to FenixKanban", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }
}

/// Merge-warning picker for "Link existing ↔ existing" (issue #18, Phase 7c).
/// Lists unpaired remote boards; choosing one runs a **merge** first-sync.
private struct LinkBoardSheet: View {
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
