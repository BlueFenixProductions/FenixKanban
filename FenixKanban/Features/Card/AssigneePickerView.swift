import SwiftUI

/// Multi-select assignee picker for a fizzy-paired card (issue #19 wave 2).
/// The user list is fetched live from `GET /users`; assignment state is the
/// card's persisted blob, toggled through the parent view model. `assignedIDs`
/// is a plain `let` re-derived from the view model on every body evaluation
/// (same pattern as LabelPickerView): the optimistic flip in
/// `toggleAssignment` updates checkmarks within a frame, and a failed-toggle
/// revert visibly flips them back instead of leaving stale local state.
struct AssigneePickerView: View {
    let client: FizzyClient
    let assignedIDs: Set<String>
    let onToggle: (FizzyUser) -> Void
    @State private var users: [FizzyUser] = []
    @State private var loadFailed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if loadFailed {
                    ContentUnavailableView("Couldn't load users", systemImage: "person.2.slash")
                } else if users.isEmpty {
                    ProgressView()
                } else {
                    List(users, id: \.id) { user in
                        Button {
                            onToggle(user)
                        } label: {
                            HStack(spacing: 10) {
                                InitialsAvatar(name: user.name)
                                Text(user.name)
                                Spacer()
                                if assignedIDs.contains(user.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(user.name)
                        .accessibilityValue(assignedIDs.contains(user.id) ? "Assigned" : "Not assigned")
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Assignees")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                do { users = try await client.users().filter(\.active) }
                catch { loadFailed = true }
            }
        }
        .presentationDetents([.medium])
    }
}
