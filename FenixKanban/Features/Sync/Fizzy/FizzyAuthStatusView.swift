import SwiftUI
import CoreData

/// Paired state UI: status hero, Sync Now, Change Board Pairing, Sign Out.
/// Shows the inline yellow 401 banner above the hero when showsReauthBanner
/// is true (computed by parent from phase == .pairedNoToken). Sub-view of
/// FizzyAuthView at phase .paired and .pairedNoToken.
struct FizzyAuthStatusView: View {

    let provider: FizzySyncProvider
    let showsReauthBanner: Bool
    let onReauthRequested: () -> Void
    let onSignOutRequested: () -> Void
    let onSyncFinished: () -> Void
    let onRepairRequested: () -> Void

    @State private var isSyncing: Bool = false
    @State private var syncError: String?
    @State private var syncTask: Task<Void, Never>?
    @State private var lastSyncedRefresh: UUID = UUID()
    @State private var showSignOutConfirm = false
    @State private var showRepairConfirm = false

    private var fizzyBoardName: String {
        provider.boardPairingStoreRef.all().first?.fizzyBoardID ?? "—"
    }

    private var localBoardName: String {
        guard let id = provider.boardPairingStoreRef.all().first?.localBoardID else { return "—" }
        let request: NSFetchRequest<Board> = Board.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? provider.persistenceRef.viewContext.fetch(request).first?.name) ?? "—"
    }

    private var lastSyncDescription: String {
        guard let lastSync = provider.boardPairingStoreRef.all().first?.lastSyncAt else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastSync, relativeTo: .now)
    }

    // Cards on the paired board with a known Fizzy pairing. Store-first with
    // the CoreData hint as fallback (#22): the device-local pairing store is
    // authoritative; the `fizzyID` hint answers only during the cold-device
    // pre-seed window. Cosmetic and eventually consistent (issue #21 A′).
    private var cardsSyncedCount: Int {
        guard let id = provider.boardPairingStoreRef.all().first?.localBoardID else { return 0 }
        let request: NSFetchRequest<Card> = Card.fetchRequest()
        request.predicate = NSPredicate(format: "column.board.id == %@", id as CVarArg)
        let store = provider.pairingStoreRef
        let cards = (try? provider.persistenceRef.viewContext.fetch(request)) ?? []
        return cards.filter { $0.resolvedFizzyID(store) != nil }.count
    }

    var body: some View {
        Form {
            if showsReauthBanner {
                Section {
                    reauthBanner
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            Section("Status") {
                LabeledContent("Local Board", value: localBoardName)
                LabeledContent("Fizzy Board", value: fizzyBoardName)
                LabeledContent("Last Sync", value: lastSyncDescription)
                LabeledContent("Cards Synced", value: "\(cardsSyncedCount)")
            }

            if let syncError {
                Section {
                    Text(syncError)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            Section {
                Button(action: syncNow) {
                    HStack {
                        if isSyncing { ProgressView().controlSize(.small) }
                        Text(syncButtonLabel)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(showsReauthBanner || isSyncing)
            }

            Section {
                Button("Change Board Pairing…") {
                    showRepairConfirm = true
                }
                .frame(maxWidth: .infinity)
                .disabled(isSyncing)
            } footer: {
                Text("Keeps your Fizzy token. Pick a new local ↔ Fizzy board pair.")
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    showSignOutConfirm = true
                }
                .frame(maxWidth: .infinity)
            } footer: {
                Text("Clears your Fizzy token and pairing. Local cards are kept.")
            }
        }
        .id(lastSyncedRefresh)
        .onDisappear { syncTask?.cancel() }
        .alert("Sign out of Fizzy?", isPresented: $showSignOutConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive, action: onSignOutRequested)
        } message: {
            Text("Local cards are kept.")
        }
        .alert("Change board pairing?", isPresented: $showRepairConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Change Pairing", action: onRepairRequested)
        } message: {
            Text("Your Fizzy token and local cards are kept. You'll pick a new board pair next.")
        }
    }

    private var syncButtonLabel: String {
        if showsReauthBanner { return "Sync Paused" }
        if isSyncing { return "Syncing…" }
        return "Sync Now"
    }

    private var reauthBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Re-enter Fizzy access token")
                    .font(.callout).fontWeight(.semibold)
                Text("Your token was revoked or expired. Sync paused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Re-enter Token", action: onReauthRequested)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
        .padding(.vertical, 4)
        .padding(.horizontal)
    }

    private func syncNow() {
        guard !isSyncing else { return }
        guard let engine = provider.makeEngine(),
              let localBoardID = provider.boardPairingStoreRef.all().first?.localBoardID else {
            syncError = "Provider isn't authenticated."
            return
        }
        syncError = nil
        isSyncing = true
        syncTask = Task { @MainActor in
            defer { isSyncing = false }
            do {
                _ = try await engine.sync(localBoardID: localBoardID)
                lastSyncedRefresh = UUID()  // force LabeledContent re-eval for lastSyncedDescription
                onSyncFinished()
            } catch FizzyError.unauthorized {
                // Engine cleared authState; parent will route to .pairedNoToken
                // on next render → reauth banner appears here.
                onSyncFinished()
            } catch is CancellationError {
                // ignore
            } catch let error as FizzyError {
                syncError = "Sync failed: \(error)"
            } catch {
                syncError = "Sync failed: \(error.localizedDescription)"
            }
        }
    }
}
