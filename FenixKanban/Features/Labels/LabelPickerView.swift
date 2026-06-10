import SwiftUI
import CoreData

struct LabelPickerView: View {
    let selectedLabels: Set<Label>
    let onToggle: (Label) -> Void
    @StateObject private var viewModel: LabelManagementViewModel
    @Environment(\.dismiss) private var dismiss

    init(selectedLabels: Set<Label>, context: NSManagedObjectContext, onToggle: @escaping (Label) -> Void) {
        self.selectedLabels = selectedLabels
        self.onToggle = onToggle
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

                        if selectedLabels.contains(label) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onToggle(label) }
                    .accessibilityAddTraits(selectedLabels.contains(label) ? .isSelected : [])
                }
            }
            .listStyle(.plain)
            .navigationTitle("Labels")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
