import SwiftUI

/// Checklist section for a fizzy-paired card's detail Form (issue #19).
/// Online-only: rendered only when the parent view model exposes a
/// `CardStepsViewModel`.
struct CardStepsSection: View {
    @ObservedObject var viewModel: CardStepsViewModel
    @State private var newStepText = ""

    var body: some View {
        Section {
            ForEach(viewModel.steps, id: \.id) { step in
                Button {
                    Task { await viewModel.toggleStep(step) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: step.completed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(step.completed ? Color.accentColor : Color.secondary)
                        Text(step.content)
                            .strikethrough(step.completed)
                            .foregroundStyle(step.completed ? .secondary : .primary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(step.content)
                .accessibilityValue(step.completed ? "Completed" : "Not completed")
                .accessibilityHint("Toggles completion on Fizzy.")
                .contextMenu {
                    Button("Delete Step", role: .destructive) {
                        Task { await viewModel.deleteStep(step) }
                    }
                }
            }
            .onDelete { offsets in
                Task { await viewModel.deleteSteps(at: offsets) }
            }

            TextField("Add a step", text: $newStepText)
                .onSubmit {
                    let content = newStepText
                    newStepText = ""
                    Task { await viewModel.addStep(content: content) }
                }
                .accessibilityIdentifier("steps-add-field")
        } header: {
            HStack {
                Text(viewModel.progressText)
                if viewModel.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .task { await viewModel.load() }
            .alert("Steps Error", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }
}
