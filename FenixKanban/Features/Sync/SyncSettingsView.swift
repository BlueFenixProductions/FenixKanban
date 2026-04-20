import SwiftUI

struct SyncSettingsView: View {
    let registry = PluginRegistry.shared

    var body: some View {
        List {
            if registry.hasSyncProviders {
                ForEach(registry.providers, id: \.providerName) { provider in
                    HStack {
                        Image(systemName: provider.iconName)
                        Text(provider.providerName)
                        Spacer()
                        if provider.isAuthenticated {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Sync Providers",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Install a sync plugin to connect your boards with GitHub Projects, Jira, or other services.")
                )
            }
        }
        .navigationTitle("Board Sync")
    }
}
