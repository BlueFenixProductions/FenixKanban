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
                        .font(.headline)

                    TextField("Description", text: $viewModel.cardDescription, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section {
                    // Column picker
                    if viewModel.availableColumns.count > 1 {
                        Picker("Column", selection: columnBinding) {
                            ForEach(viewModel.availableColumns, id: \.objectID) { column in
                                Text(column.name ?? "Untitled").tag(column)
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
                                    .font(.caption)
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
                                    .font(.caption)
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
            .navigationBarTitleDisplayMode(.inline)
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

    private var columnBinding: Binding<Column> {
        Binding(
            get: { viewModel.card.column ?? viewModel.availableColumns[0] },
            set: { viewModel.moveToColumn($0) }
        )
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
            .navigationBarTitleDisplayMode(.inline)
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
