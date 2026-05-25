import SwiftUI
import CoreData

struct LabelPickerView: View {
    @Binding var selectedLabel: Label?
    @StateObject private var viewModel: LabelManagementViewModel
    @Environment(\.dismiss) private var dismiss

    init(selectedLabel: Binding<Label?>, context: NSManagedObjectContext) {
        _selectedLabel = selectedLabel
        _viewModel = StateObject(wrappedValue: LabelManagementViewModel(context: context))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.labels, id: \.objectID) { label in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color(hex: label.colorHex ?? "#808080"))
                            .frame(width: 20, height: 20)

                        Text(label.name ?? "Untitled")

                        Spacer()

                        if selectedLabel?.objectID == label.objectID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedLabel = label
                        dismiss()
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Select Label")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
