import SwiftUI

struct NewColumnSheet: View {
    @Binding var name: String
    @Binding var colorHex: String?
    let isEditing: Bool
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let presetColors: [String] = [
        "#E94560", "#F5A623", "#16C79A", "#0F3460",
        "#9B59B6", "#3498DB", "#E67E22", "#1ABC9C",
        "#E74C3C", "#2ECC71", "#F39C12", "#8E44AD"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Column Name") {
                    TextField("Enter name", text: $name)
                }

                Section("Column Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        // "No color" swatch
                        ZStack {
                            Circle()
                                .fill(Color(.tertiarySystemBackground))
                            Image(systemName: "slash.circle")
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 40, height: 40)
                        .overlay(
                            Circle()
                                .strokeBorder(.white, lineWidth: colorHex == nil ? 3 : 0)
                        )
                        .onTapGesture { colorHex = nil }

                        ForEach(presetColors, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 40, height: 40)
                                .overlay(
                                    Circle()
                                        .strokeBorder(.white, lineWidth: colorHex == hex ? 3 : 0)
                                )
                                .onTapGesture { colorHex = hex }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle(isEditing ? "Edit Column" : "New Column")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Create") {
                        onSave()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
