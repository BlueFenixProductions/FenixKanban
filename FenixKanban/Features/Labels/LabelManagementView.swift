import CoreData
import SwiftUI

struct LabelManagementView: View {
    @StateObject private var viewModel: LabelManagementViewModel
    @Environment(\.managedObjectContext) private var context

    init(context: NSManagedObjectContext) {
        _viewModel = StateObject(wrappedValue: LabelManagementViewModel(context: context))
    }

    var body: some View {
        Group {
            if viewModel.labels.isEmpty {
                EmptyStateView(
                    icon: "tag.slash",
                    title: "No Labels",
                    message: "Create labels to categorize your cards",
                    actionTitle: "New Label"
                ) {
                    viewModel.editingLabel = nil
                    viewModel.showEditor = true
                }
            } else {
                List {
                    ForEach(viewModel.labels, id: \.objectID) { label in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color(hex: label.colorHex ?? "#808080"))
                                .frame(width: 20, height: 20)

                            Text(label.name ?? "Untitled")

                            Spacer()

                            Text("\(label.cardCount) cards")
                                .font(.crossPlatformCaption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.editingLabel = label
                            viewModel.showEditor = true
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            viewModel.deleteLabel(viewModel.labels[i])
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Labels")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.editingLabel = nil
                    viewModel.showEditor = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $viewModel.showEditor) {
            LabelEditorSheet(
                label: viewModel.editingLabel,
                onSave: { name, colorHex in
                    if let existing = viewModel.editingLabel {
                        viewModel.updateLabel(existing, name: name, colorHex: colorHex)
                    } else {
                        viewModel.createLabel(name: name, colorHex: colorHex)
                    }
                }
            )
        }
    }
}

#Preview {
    NavigationStack {
        LabelManagementView(context: PersistenceController.preview.viewContext)
    }
    .preferredColorScheme(.dark)
}
