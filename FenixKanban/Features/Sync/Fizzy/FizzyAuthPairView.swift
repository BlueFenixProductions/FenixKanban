import SwiftUI
import CoreData

/// Three pickers (local board, Fizzy board, first-sync mode) + destructive
/// UX for replaceLocalWithFizzy + dismissable backup recommendation banner.
/// Sub-view of FizzyAuthView at phase .unpaired.
struct FizzyAuthPairView: View {

    let provider: FizzySyncProvider
    let onPaired: () -> Void
    let onSignOutRequested: () -> Void

    @AppStorage("fizzy.pair.backupBannerDismissed") private var backupBannerDismissed = false

    @State private var localBoards: [Board] = []
    @State private var remoteBoards: [RemoteBoard] = []
    @State private var loadError: String?
    @State private var isLoading: Bool = true

    @State private var pickedLocalBoardID: UUID?
    @State private var pickedFizzyBoardID: String?
    @State private var pickedMode: FirstSyncMode = .pushLocalToFizzy

    @State private var isSyncing = false
    @State private var pairError: String?
    @State private var pairTask: Task<Void, Never>?
    @State private var showDestructiveConfirm = false

    @State private var showCreateBoard = false
    @State private var newBoardName = ""
    @State private var isCreatingBoard = false

    private var pickedLocalBoard: Board? {
        guard let id = pickedLocalBoardID else { return nil }
        return localBoards.first { $0.id == id }
    }

    private var pickedRemoteBoard: RemoteBoard? {
        guard let id = pickedFizzyBoardID else { return nil }
        return remoteBoards.first { $0.id == id }
    }

    private var pickedLocalBoardCardCount: Int {
        guard let board = pickedLocalBoard else { return 0 }
        return ((board.columns as? Set<Column>) ?? []).reduce(0) { sum, col in
            sum + (((col.cards as? Set<Card>) ?? []).count)
        }
    }

    var body: some View {
        Form {
            if !backupBannerDismissed {
                Section {
                    backupBanner
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            formContent
        }
        .task { await initialLoad() }
        .onDisappear { pairTask?.cancel() }
        .alert("Delete and Replace?", isPresented: $showDestructiveConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete & Replace", role: .destructive) { runPair() }
        } message: {
            Text("This will delete all \(pickedLocalBoardCardCount) cards on \"\(pickedLocalBoard?.name ?? "")\" and replace them with cards from Fizzy. This cannot be undone.")
        }
    }

    @ViewBuilder
    private var formContent: some View {
        if isLoading {
            Section { ProgressView("Loading Fizzy boards…") }
        } else if let loadError {
            Section {
                ContentUnavailableView(
                    "Couldn't load Fizzy boards",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
                Button("Try Again") { Task { await loadRemoteBoards() } }
            }
        } else {
            Section("Local Board") {
                Picker("Board", selection: $pickedLocalBoardID) {
                    ForEach(localBoards, id: \.id) { board in
                        let count = ((board.columns as? Set<Column>) ?? []).reduce(0) { sum, col in
                            sum + (((col.cards as? Set<Card>) ?? []).count)
                        }
                        // `board.id` is already `UUID?` (CoreData optional); pass it
                        // directly so the tag type matches the selection binding's
                        // `UUID?`. Wrapping in `Optional(...)` would produce `UUID??`.
                        Text("\(board.name ?? "(untitled)") (\(count) cards)")
                            .tag(board.id)
                    }
                }
            }

            Section("Fizzy Board") {
                Picker("Board", selection: $pickedFizzyBoardID) {
                    ForEach(remoteBoards) { remote in
                        // `remote.id` is non-optional `String`; cast to `String?`
                        // so the tag matches the selection binding.
                        Text(remote.name).tag(remote.id as String?)
                    }
                }
                Button {
                    newBoardName = ""
                    showCreateBoard = true
                } label: {
                    HStack {
                        if isCreatingBoard { ProgressView().controlSize(.small) }
                        SwiftUI.Label("New Fizzy Board…", systemImage: "plus.circle")
                    }
                }
                .disabled(isCreatingBoard || isSyncing)
            }
            .alert("New Fizzy Board", isPresented: $showCreateBoard) {
                TextField("Board name", text: $newBoardName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { Task { await createRemoteBoard() } }
                    .disabled(newBoardName.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: {
                Text("Creates an empty board on Fizzy and selects it for pairing.")
            }

            Section {
                Picker("First Sync", selection: $pickedMode) {
                    Text("Push").tag(FirstSyncMode.pushLocalToFizzy)
                    Text("Replace").tag(FirstSyncMode.replaceLocalWithFizzy)
                    Text("Merge").tag(FirstSyncMode.mergeIfNoConflicts)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("First Sync Mode")
            } footer: {
                Text(modeHelpText)
                    .foregroundStyle(pickedMode == .replaceLocalWithFizzy ? .red : .secondary)
            }

            if pickedMode == .replaceLocalWithFizzy, pickedLocalBoardCardCount > 0 {
                Section {
                    destructiveWarningRow
                }
            }

            if let pairError {
                Section {
                    Text(pairError)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            Section {
                Button(action: pairTapped) {
                    HStack {
                        if isSyncing { ProgressView().controlSize(.small) }
                        Text(primaryButtonLabel)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(pickedMode == .replaceLocalWithFizzy ? .red : .accentColor)
                .disabled(pickedLocalBoardID == nil || pickedFizzyBoardID == nil || isSyncing)
            }

            Section {
                Button("Sign Out", role: .destructive, action: onSignOutRequested)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var primaryButtonLabel: String {
        if isSyncing { return "Syncing…" }
        return pickedMode == .replaceLocalWithFizzy ? "Delete & Replace" : "Pair & Sync"
    }

    private var modeHelpText: String {
        switch pickedMode {
        case .pushLocalToFizzy:
            return "Push — uploads every local card on this board to Fizzy. Pre-existing Fizzy cards stay (non-destructive)."
        case .replaceLocalWithFizzy:
            return "Replace — DELETES local cards on this board and pulls Fizzy's state. Destructive."
        case .mergeIfNoConflicts:
            return "Merge — pushes local-only and pulls Fizzy-only cards. Same-title collisions are logged and skipped."
        }
    }

    private var destructiveWarningRow: some View {
        SwiftUI.Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("This will delete all \(pickedLocalBoardCardCount) cards on \"\(pickedLocalBoard?.name ?? "")\".")
                    .font(.callout).fontWeight(.semibold)
                Text("Cannot be undone without restoring a backup. You'll confirm again on Pair & Sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var backupBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 6) {
                Text("Export a backup first")
                    .font(.callout).fontWeight(.semibold)
                Text("Recommended before your first sync — recoverable in case anything looks wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NavigationLink("Open Backup") {
                    BackupSettingsView(persistence: provider.persistenceRef)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer(minLength: 0)
            Button {
                backupBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.vertical, 4)
        .padding(.horizontal)
    }

    @MainActor
    private func initialLoad() async {
        await loadLocalBoards()
        await loadRemoteBoards()
        if pickedLocalBoardID == nil { pickedLocalBoardID = localBoards.first?.id }
        if pickedFizzyBoardID == nil { pickedFizzyBoardID = remoteBoards.first?.id }
    }

    @MainActor
    private func loadLocalBoards() async {
        let request: NSFetchRequest<Board> = Board.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        do {
            localBoards = try provider.persistenceRef.viewContext.fetch(request)
        } catch {
            loadError = "Local boards: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func loadRemoteBoards() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            remoteBoards = try await provider.fetchRemoteBoards()
        } catch {
            loadError = "\(error)"
        }
    }

    /// Creates an empty board on Fizzy and selects it in the picker —
    /// pairing a local board with a fresh remote twin (issue #18) no longer
    /// requires the Fizzy web UI.
    @MainActor
    private func createRemoteBoard() async {
        let name = newBoardName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard let client = provider.makeClient() else {
            pairError = "Provider isn't authenticated — sign in first."
            return
        }
        isCreatingBoard = true
        defer { isCreatingBoard = false }
        do {
            let created = try await client.createBoard(FizzyBoardWrite(name: name))
            await loadRemoteBoards()
            pickedFizzyBoardID = created.id
            pairError = nil
        } catch let error as FizzyError {
            pairError = "Create board failed: \(error)"
        } catch {
            pairError = "Create board failed: \(error.localizedDescription)"
        }
    }

    private func pairTapped() {
        if pickedMode == .replaceLocalWithFizzy, pickedLocalBoardCardCount > 0 {
            showDestructiveConfirm = true
        } else {
            runPair()
        }
    }

    private func runPair() {
        guard let localID = pickedLocalBoardID, let fizzyID = pickedFizzyBoardID else { return }
        guard let engine = provider.makeEngine() else {
            pairError = "Provider isn't authenticated — sign in first."
            return
        }
        provider.mappingRef.setPairing(localBoardID: localID, fizzyBoardID: fizzyID)
        let mode = pickedMode
        pairError = nil
        isSyncing = true
        pairTask = Task { @MainActor in
            defer { isSyncing = false }
            do {
                _ = try await engine.syncFirst(mode: mode)
                onPaired()
            } catch FizzyError.unauthorized {
                // Engine cleared authState. Parent will recompute phase to
                // .pairedNoToken on next render — no extra action needed here.
                onPaired()
            } catch is CancellationError {
                // ignore
            } catch let error as FizzyError {
                pairError = "Sync failed: \(error)"
            } catch {
                pairError = "Sync failed: \(error.localizedDescription)"
            }
        }
    }
}
