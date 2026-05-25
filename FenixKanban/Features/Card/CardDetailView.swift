import CoreData
import SwiftUI

struct CardDetailView: View {
    @StateObject private var viewModel: CardDetailViewModel
    @Environment(\.dismiss) private var dismiss

    init(card: Card, context: NSManagedObjectContext) {
        _viewModel = StateObject(wrappedValue: CardDetailViewModel(card: card, context: context))
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

                    // Label
                    HStack {
                        Text("Label")
                        Spacer()
                        if let label = viewModel.selectedLabel,
                           let name = label.name,
                           let hex = label.colorHex {
                            LabelBadge(name: name, colorHex: hex)
                                .onTapGesture { viewModel.showLabelPicker = true }
                            Button {
                                viewModel.clearLabel()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.crossPlatformCaption)
                            }
                        } else {
                            Button("Select") { viewModel.showLabelPicker = true }
                                .foregroundStyle(.secondary)
                        }
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
            }
            .navigationTitle("Card Detail")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        viewModel.save()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $viewModel.showLabelPicker) {
                LabelPickerView(
                    selectedLabel: $viewModel.selectedLabel,
                    context: viewModel.card.managedObjectContext!
                )
            }
            .sheet(isPresented: $viewModel.showDatePicker) {
                dueDatePicker
            }
            .onChange(of: viewModel.isCompleted) {
                viewModel.save()
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
