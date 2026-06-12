import SwiftUI

struct SyncSettingsView: View {
    let registry = PluginRegistry.shared
    var syncScheduler: SyncScheduler

    var body: some View {
        List {
            Section {
                ForEach(registry.providers, id: \.providerName) { provider in
                    if let fizzy = provider as? FizzySyncProvider {
                        NavigationLink {
                            FizzyAuthView(provider: fizzy)
                        } label: {
                            providerRow(fizzy)
                        }
                    } else {
                        providerRow(provider)
                    }
                }
            } header: {
                Text("Sync Providers")
            } footer: {
                Text("Sync your boards with cards on remote services.")
            }

            // Phase 6: Sync activity status section
            syncStatusSection
        }
        .navigationTitle("Board Sync")
    }

    // MARK: - Sync status section

    @ViewBuilder
    private var syncStatusSection: some View {
        let state = syncScheduler.activityState
        Section {
            // Current phase row
            HStack {
                Text("Status")
                Spacer()
                syncPhaseLabel(state.phase)
            }

            // Last sync timestamp
            HStack {
                Text("Last Synced")
                Spacer()
                if let last = state.lastSyncAt {
                    Text(last, style: .relative)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Last synced \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: .now))")
                } else {
                    Text("Never")
                        .foregroundStyle(.secondary)
                }
            }

            // Last error (only shown when an error exists)
            if let error = state.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .imageScale(.small)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Auto-Sync")
        } footer: {
            Text("FenixKanban syncs automatically every 5 minutes while in the foreground.")
        }
    }

    @ViewBuilder
    private func syncPhaseLabel(_ phase: SyncActivityState.Phase) -> some View {
        switch phase {
        case .idle:
            Text("Idle")
                .foregroundStyle(.secondary)
        case .syncing:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Syncing…")
                    .foregroundStyle(.secondary)
            }
        case .error(let msg):
            Text(msg)
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
    }

    // MARK: - Provider rows

    @ViewBuilder
    private func providerRow(_ provider: any BoardSyncProvider) -> some View {
        HStack(spacing: 12) {
            Image(systemName: provider.iconName)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.providerName)
                Text(rowSubtitle(provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge(for: provider)
        }
    }

    private func rowSubtitle(_ provider: any BoardSyncProvider) -> String {
        guard let fizzy = provider as? FizzySyncProvider else {
            return provider.isAuthenticated ? "Connected" : "Not set up"
        }
        if fizzy.mappingRef.isPaired && !fizzy.authStateRef.isConfigured {
            return "Tap to re-enter token"
        }
        if fizzy.isAuthenticated && fizzy.mappingRef.isPaired {
            if let last = fizzy.mappingRef.lastSyncAt {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                return "Synced \(formatter.localizedString(for: last, relativeTo: .now))"
            }
            return "Paired"
        }
        if fizzy.isAuthenticated {
            return "Pair a board"
        }
        return "Not set up"
    }

    @ViewBuilder
    private func statusBadge(for provider: any BoardSyncProvider) -> some View {
        if let fizzy = provider as? FizzySyncProvider {
            if fizzy.mappingRef.isPaired && !fizzy.authStateRef.isConfigured {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            } else if fizzy.isAuthenticated && fizzy.mappingRef.isPaired {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } else if provider.isAuthenticated {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}
