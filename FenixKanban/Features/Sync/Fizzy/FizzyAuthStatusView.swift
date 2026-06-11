import SwiftUI
import CoreData

/// Paired state UI: status hero, Sync Now, Sign Out. Shows the inline
/// yellow 401 banner above the hero when showsReauthBanner is true
/// (computed by parent from phase == .pairedNoToken). Sub-view of
/// FizzyAuthView at phase .paired and .pairedNoToken.
struct FizzyAuthStatusView: View {

    let provider: FizzySyncProvider
    let showsReauthBanner: Bool
    let onReauthRequested: () -> Void
    let onSignOutRequested: () -> Void
    let onSyncFinished: () -> Void

    @State private var isSyncing: Bool = false
    @State private var syncError: String?
    @State private var syncTask: Task<Void, Never>?
    @State private var lastSyncedRefresh: UUID = UUID()
    @State private var showSignOutConfirm = false

    private var fizzyBoardName: String {
        provider.mappingRef.fizzyBoardID ?? "—"
    }

    private var localBoardName: String {
        guard let id = provider.mappingRef.localBoardID else { return "—" }
        let request: NSFetchRequest<Board> = Board.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? provider.persistenceRef.viewContext.fetch(request).first?.name) ?? "—"
    }

    private var lastSyncDescription: String {
        guard let lastSync = provider.mappingRef.lastSyncAt else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastSync, relativeTo: .now)
    }

    // fizzyID hint attributes are healed every sync by FizzySyncEngine;
    // this count is cosmetic and eventually consistent (issue #21 A′).
    private var cardsSyncedCount: Int {
        guard let id = provider.mappingRef.localBoardID else { return 0 }
        let request: NSFetchRequest<Card> = Card.fetchRequest()
        request.predicate = NSPredicate(format: "fizzyID != nil AND column.board.id == %@", id as CVarArg)
        return (try? provider.persistenceRef.viewContext.count(for: request)) ?? 0
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
        guard let engine = provider.makeEngine() else {
            syncError = "Provider isn't authenticated."
            return
        }
        syncError = nil
        isSyncing = true
        syncTask = Task { @MainActor in
            defer { isSyncing = false }
            do {
                _ = try await engine.sync()
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
