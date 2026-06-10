import Foundation

/// Online-only steps (checklist) state for a fizzy-paired card.
///
/// Captain's ruling on #19: steps are NOT persisted locally — they're fetched
/// from the single-card endpoint when the detail view opens, and every
/// mutation goes straight to the API with optimistic UI + revert-on-failure.
/// The next pull is never involved (board pulls don't carry steps).
@MainActor
final class CardStepsViewModel: ObservableObject {
    @Published private(set) var steps: [FizzyStep] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let cardNumber: Int
    private let client: FizzyClient

    init(cardNumber: Int, client: FizzyClient) {
        self.cardNumber = cardNumber
        self.client = client
    }

    var progressText: String {
        "Steps (\(steps.filter(\.completed).count)/\(steps.count))"
    }

    func load() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            steps = try await client.card(number: cardNumber).steps ?? []
        } catch {
            errorMessage = "Couldn't load steps."
        }
    }

    /// Returns `false` when the create call failed, so callers can restore
    /// the typed text (`CardStepsSection` clears its field optimistically).
    /// Whitespace-only input is ignored and returns `true` — nothing was
    /// lost, so there's nothing to restore.
    @discardableResult
    func addStep(content: String) async -> Bool {
        errorMessage = nil
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        do {
            let created = try await client.createStep(cardNumber: cardNumber, content: trimmed)
            steps.append(created)
            return true
        } catch {
            errorMessage = "Couldn't add the step."
            return false
        }
    }

    /// Flips a step optimistically, then PUTs the new completed state.
    /// Concurrent toggles of the same step are last-writer-wins locally
    /// (mirrors `CardDetailViewModel.toggleLabel`): before applying the
    /// server response — and before reverting on failure — we re-check that
    /// the step's local `completed` still matches our optimistic flip; if a
    /// newer toggle already moved it on, we leave that state alone.
    func toggleStep(_ step: FizzyStep) async {
        errorMessage = nil
        guard let index = steps.firstIndex(where: { $0.id == step.id }) else { return }
        let flipped = FizzyStep(id: step.id, content: step.content, completed: !step.completed)
        steps[index] = flipped  // optimistic
        do {
            let updated = try await client.updateStep(cardNumber: cardNumber, id: step.id, completed: flipped.completed)
            if let i = steps.firstIndex(where: { $0.id == step.id }),
               steps[i].completed == flipped.completed {
                steps[i] = updated
            }
        } catch {
            if let i = steps.firstIndex(where: { $0.id == step.id }),
               steps[i].completed == flipped.completed {
                steps[i] = step  // revert
            }
            errorMessage = "Couldn't update the step."
        }
    }

    func deleteStep(_ step: FizzyStep) async {
        errorMessage = nil
        guard let index = steps.firstIndex(where: { $0.id == step.id }) else { return }
        steps.remove(at: index)  // optimistic
        do {
            try await client.deleteStep(cardNumber: cardNumber, id: step.id)
        } catch {
            steps.insert(step, at: min(index, steps.count))  // revert
            errorMessage = "Couldn't delete the step."
        }
    }

    func deleteSteps(at offsets: IndexSet) async {
        for step in offsets.compactMap({ steps.indices.contains($0) ? steps[$0] : nil }) {
            await deleteStep(step)
        }
    }
}
