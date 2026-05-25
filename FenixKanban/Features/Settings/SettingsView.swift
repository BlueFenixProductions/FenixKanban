import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context

    init(authService: AuthenticationService, persistence: PersistenceController) {
        _viewModel = StateObject(wrappedValue: SettingsViewModel(
            authService: authService,
            persistence: persistence
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if viewModel.authService.isAuthenticated {
                        HStack {
                            Text("Apple ID")
                            Spacer()
                            Text("Signed In")
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("iCloud Sync")
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }

                        Button("Sign Out") {
                            viewModel.signOut()
                        }
                        .foregroundStyle(.red)
                    } else {
                        HStack {
                            Text("iCloud Sync")
                            Spacer()
                            Text("Sign in to enable")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Notifications") {
                    NavigationLink("Notification Settings") {
                        NotificationSettingsView()
                    }
                }

                Section("Labels") {
                    NavigationLink("Manage Labels") {
                        LabelManagementView(context: context)
                    }
                }

                Section("Integrations") {
                    NavigationLink("Board Sync") {
                        SyncSettingsView()
                    }
                }

                Section("Support") {
                    NavigationLink("Tip Jar") {
                        TipJarView()
                    }
                }

                Section("Data") {
                    Button("Delete All Data", role: .destructive) {
                        viewModel.showDeleteConfirmation = true
                    }
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Delete All Data",
                isPresented: $viewModel.showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Everything", role: .destructive) {
                    viewModel.deleteAllData()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all boards, columns, cards, and labels. This cannot be undone.")
            }
        }
    }
}
