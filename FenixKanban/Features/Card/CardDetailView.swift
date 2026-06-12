import CoreData
import SwiftUI

struct CardDetailView: View {
    @StateObject private var viewModel: CardDetailViewModel
    @Environment(\.dismiss) private var dismiss

    init(card: Card, context: NSManagedObjectContext) {
        let provider = PluginRegistry.shared.provider(named: "Fizzy") as? FizzySyncProvider
        _viewModel = StateObject(wrappedValue: CardDetailViewModel(
            card: card,
            context: context,
            fizzyClient: provider?.makeClient()
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $viewModel.title)
                        .font(.crossPlatformHeadline)

                    TextField("Description", text: $viewModel.cardDescription, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section {
                    // Column picker (Menu avoids the Binding<Column> re-entrance
                    // crash from the earlier Picker implementation — actions run
                    // on tap, not during SwiftUI state evaluation)
                    if viewModel.availableColumns.count > 1 {
                        Menu {
                            ForEach(viewModel.availableColumns, id: \.objectID) { column in
                                Button {
                                    viewModel.moveToColumn(column)
                                } label: {
                                    if column.objectID == viewModel.card.column?.objectID {
                                        SwiftUI.Label(column.name ?? "Untitled", systemImage: "checkmark")
                                    } else {
                                        Text(column.name ?? "Untitled")
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text("Column")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(viewModel.card.column?.name ?? "None")
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.crossPlatformCaption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    // Labels (multi)
                    HStack(alignment: .firstTextBaseline) {
                        Text("Labels")
                        Spacer()
                        if viewModel.selectedLabels.isEmpty {
                            Button("Select") { viewModel.showLabelPicker = true }
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 4) {
                                ForEach(viewModel.sortedSelectedLabels, id: \.objectID) { label in
                                    if let name = label.name, let hex = label.colorHex {
                                        LabelBadge(name: name, colorHex: hex)
                                    }
                                }
                            }
                            .onTapGesture { viewModel.showLabelPicker = true }
                            Button {
                                viewModel.clearLabels()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.crossPlatformCaption)
                            }
                            .accessibilityLabel("Remove all labels")
                        }
                    }

                    // Assignees (fizzy-paired cards only — issue #19 wave 2)
                    if viewModel.canEditAssignments {
                        HStack {
                            Text("Assignees")
                            Spacer()
                            if viewModel.assignees.isEmpty {
                                Button("Assign") { viewModel.showAssigneePicker = true }
                                    .foregroundStyle(.secondary)
                            } else {
                                HStack(spacing: -6) {
                                    ForEach(viewModel.assignees) { assignee in
                                        InitialsAvatar(name: assignee.name)
                                    }
                                }
                                .onTapGesture { viewModel.showAssigneePicker = true }
                                .accessibilityLabel("Assignees: \(viewModel.assignees.map(\.name).joined(separator: ", "))")
                                .accessibilityHint("Opens the assignee picker.")
                            }
                        }
                    }

                    // Watch / Pin (fizzy-paired cards only — issue #19 wave 3).
                    // Watch is local write-only state (server never reports it);
                    // pin reconciles from GET /my/pins on sync.
                    if viewModel.isFizzyPaired {
                        Toggle(isOn: Binding(
                            get: { viewModel.isWatched },
                            set: { _ in Task { await viewModel.toggleWatched() } }
                        )) {
                            SwiftUI.Label("Watch", systemImage: "eye")
                        }
                        .accessibilityHint("Subscribes to activity on this card on Fizzy.")

                        Toggle(isOn: Binding(
                            get: { viewModel.isPinned },
                            set: { _ in Task { await viewModel.togglePinned() } }
                        )) {
                            SwiftUI.Label("Pin", systemImage: "pin")
                        }
                        .accessibilityHint("Pins this card to your Fizzy pins.")
                    }

                    // Due date
                    HStack {
                        Text("Due Date")
                        Spacer()
                        if let date = viewModel.dueDate {
                            DueDateBadge(date: date)
                                .onTapGesture { viewModel.showDatePicker = true }
                            Button {
                                viewModel.clearDueDate()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.crossPlatformCaption)
                            }
                        } else {
                            Button("Set") { viewModel.showDatePicker = true }
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Completed toggle
                    Toggle("Completed", isOn: $viewModel.isCompleted)
                }

                // MARK: Lifecycle section (issue #34)
                // Show context-appropriate controls: only the valid transitions
                // from the card's current state. Reopen only for closed cards;
                // Close and Not Now only for active/notNow cards.
                Section("Status") {
                    switch viewModel.card.lifecycleStatus {
                    case .active:
                        Button {
                            Task { await viewModel.closeCard() }
                        } label: {
                            SwiftUI.Label("Close Card", systemImage: "checkmark.circle")
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityHint("Marks this card as resolved.")

                        Button {
                            Task { await viewModel.postponeCard() }
                        } label: {
                            SwiftUI.Label("Not Now", systemImage: "clock.badge.xmark")
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityHint("Defers this card without closing it.")

                    case .closed:
                        HStack {
                            SwiftUI.Label("Closed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        Button {
                            Task { await viewModel.reopenCard() }
                        } label: {
                            SwiftUI.Label("Reopen Card", systemImage: "arrow.counterclockwise")
                        }
                        .accessibilityHint("Moves this card back to active.")

                    case .notNow:
                        HStack {
                            SwiftUI.Label("Not Now", systemImage: "clock.badge.xmark")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        Button {
                            Task { await viewModel.closeCard() }
                        } label: {
                            SwiftUI.Label("Close Card", systemImage: "checkmark.circle")
                        }
                        .foregroundStyle(.secondary)
                        Button {
                            Task { await viewModel.reopenCard() }
                        } label: {
                            SwiftUI.Label("Reopen Card", systemImage: "arrow.counterclockwise")
                        }
                        .accessibilityHint("Moves this card back to active.")
                    }
                }

                if let stepsVM = viewModel.stepsViewModel {
                    CardStepsSection(viewModel: stepsVM)
                }

                if let commentsVM = viewModel.commentsViewModel {
                    CardCommentsSection(viewModel: commentsVM)
                }
            }
            .navigationTitle("Card Detail")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await viewModel.toggleGolden() }
                    } label: {
                        Image(systemName: viewModel.card.isGolden ? "ticket.fill" : "ticket")
                    }
                    .tint(viewModel.card.isGolden ? Color.goldenTicketIcon : .primary)
                    .accessibilityLabel(viewModel.card.isGolden ? "Remove golden ticket" : "Mark as golden ticket")
                    .accessibilityHint(viewModel.card.isGolden ? "Removes golden ticket priority from this card." : "Promotes this card to the top of the column.")
                }
                #else
                ToolbarItem(placement: .navigation) {
                    Button {
                        Task { await viewModel.toggleGolden() }
                    } label: {
                        Image(systemName: viewModel.card.isGolden ? "ticket.fill" : "ticket")
                    }
                    .tint(viewModel.card.isGolden ? Color.goldenTicketIcon : .primary)
                    .accessibilityLabel(viewModel.card.isGolden ? "Remove golden ticket" : "Mark as golden ticket")
                    .accessibilityHint(viewModel.card.isGolden ? "Removes golden ticket priority from this card." : "Promotes this card to the top of the column.")
                }
                #endif
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        viewModel.save()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $viewModel.showLabelPicker) {
                LabelPickerView(
                    selectedLabels: viewModel.selectedLabels,
                    context: viewModel.card.managedObjectContext!
                ) { label in
                    Task { await viewModel.toggleLabel(label) }
                }
            }
            .sheet(isPresented: $viewModel.showAssigneePicker) {
                if let client = viewModel.fizzyClient {
                    AssigneePickerView(
                        client: client,
                        assignedIDs: Set(viewModel.assignees.map(\.id))
                    ) { user in
                        Task { await viewModel.toggleAssignment(user) }
                    }
                }
            }
            .sheet(isPresented: $viewModel.showDatePicker) {
                dueDatePicker
            }
            .onChange(of: viewModel.isCompleted) {
                viewModel.save()
            }
            .alert("Sync Error", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    private var dueDatePicker: some View {
        NavigationStack {
            DatePicker(
                "Due Date",
                selection: Binding(
                    get: { viewModel.dueDate ?? Date() },
                    set: { viewModel.dueDate = $0 }
                ),
                displayedComponents: [.date]
            )
            .datePickerStyle(.graphical)
            .padding()
            .navigationTitle("Due Date")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        viewModel.save()
                        viewModel.showDatePicker = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// Card and Column already conform to Identifiable via CoreData generated properties
