import SwiftUI

struct LabelEditorSheet: View {
    let label: Label?
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var selectedColor: String

    private let presetColors = [
        "#E94560", "#0F3460", "#16C79A", "#F5A623",
        "#9B59B6", "#3498DB", "#E67E22", "#1ABC9C",
        "#E74C3C", "#2ECC71", "#F39C12", "#8E44AD"
    ]

    init(label: Label?, onSave: @escaping (String, String) -> Void) {
        self.label = label
        self.onSave = onSave
        _name = State(initialValue: label?.name ?? "")
        _selectedColor = State(initialValue: label?.colorHex ?? "#E94560")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Label Name") {
                    TextField("Enter name", text: $name)
                }

                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(presetColors, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 40, height: 40)
                                .overlay(
                                    Circle()
                                        .strokeBorder(.white, lineWidth: selectedColor == hex ? 3 : 0)
                                )
                                .onTapGesture { selectedColor = hex }
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("Preview") {
                    LabelBadge(name: name.isEmpty ? "Label" : name, colorHex: selectedColor)
                }
            }
            .navigationTitle(label == nil ? "New Label" : "Edit Label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name, selectedColor)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
