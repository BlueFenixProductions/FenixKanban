import Foundation
import CoreData

/// Cache-first steps (checklist) view model for a fizzy-paired card.
///
/// Architecture: `CardStep` CoreData rows are the source of truth for the UI.
/// `load()` first publishes cached rows (fast, offline-capable), then fetches
/// the single-card endpoint to reconcile with the server.
///
/// Mutations are optimistic: the CoreData row is written immediately, the
/// network call follows. On success, `pendingWrite` is cleared. On failure,
/// the row is reverted (toggle) or kept (delete failure, so UI can restore) and
/// `pendingWrite` stays `true` to signal the retry seam.
///
/// Retry seam: `retryPending()` re-sends all `pendingWrite == true` rows.
/// Callers (FizzySyncProvider scheduler tick) invoke this on each sync cycle
/// to drain failed writes. This mirrors CommentRepository's retry hook (#63)
/// so the orchestrator can call both repositories symmetrically.
@MainActor
final class CardStepsViewModel: ObservableObject {
    @Published private(set) var steps: [FizzyStep] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let card: Card
    private let cardNumber: Int
    private let client: FizzyClient
    private let repository: StepRepository

    /// `true` when any row in the cache has `pendingWrite == true`.
    var hasPendingWrites: Bool {
        repository.fetchSteps(for: card).contains(where: \.pendingWrite)
    }

    init(card: Card, client: FizzyClient, repository: StepRepository) {
        self.card = card
        self.cardNumber = Int(card.fizzyNumber)
        self.client = client
        self.repository = repository
    }

    // MARK: - Backward compat (online-only init — kept so CardDetailViewModel compiles)

    /// Legacy init for online-only usage. Constructs an in-memory-only
    /// repository backed by the card's managed object context, or uses a
    /// no-op if the card has no context (safety guard).
    convenience init(cardNumber: Int, client: FizzyClient) {
        // This path is only used by legacy call sites that don't have a Card
        // CoreData object. Create a temporary in-memory container so the
        // repository operations are safe.
        let tempController = PersistenceController(inMemory: true, useCloudKit: false)
        let context = tempController.viewContext
        // Create a stub card so the repository queries work
        let stubCard = Card(context: context)
        stubCard.id = UUID()
        stubCard.title = "stub"
        stubCard.fizzyNumber = Int64(cardNumber)
        stubCard.createdAt = Date()
        stubCard.modifiedAt = Date()
        stubCard.sortOrder = 0
        try? context.save()
        self.init(card: stubCard, client: client, repository: StepRepository(context: context))
    }

    var progressText: String {
        "Steps (\(steps.filter(\.completed).count)/\(steps.count))"
    }

    // MARK: - Load

    /// Cache-first load: immediately publishes cached rows, then refreshes
    /// from the server to reconcile. Pending rows survive reconciliation.
    func load() async {
        // Phase 1: serve from cache
        publishFromCache()

        // Phase 2: network refresh
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await client.card(number: cardNumber)
            let serverSteps = fetched.steps ?? []
            repository.upsert(serverSteps: serverSteps, for: card)
            publishFromCache()
        } catch {
            // Network failure is non-fatal: cached rows are already visible.
            // Only set an error if we have zero cached steps (nothing useful to show).
            if steps.isEmpty {
                errorMessage = "Couldn't load steps."
            }
        }
    }

    /// Serves cached rows immediately without a network call. Used by tests
    /// and callers that only want the offline view.
    func loadFromCache() async {
        publishFromCache()
    }

    // MARK: - Create

    /// Creates an optimistic local row, POSTs to the server, then clears
    /// `pendingWrite` on success. Returns `false` when the network call
    /// failed so the caller can restore any cleared input field.
    @discardableResult
    func addStep(content: String) async -> Bool {
        errorMessage = nil
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        // Optimistic insert
        let localRow = repository.createLocalStep(for: card, content: trimmed)
        publishFromCache()

        do {
            let created = try await client.createStep(cardNumber: cardNumber, content: trimmed)
            repository.confirmCreate(localRow, serverStep: created)
            publishFromCache()
            return true
        } catch {
            // Remove the optimistic row on failure
            repository.deleteStep(localRow)
            publishFromCache()
            errorMessage = "Couldn't add the step."
            return false
        }
    }

    // MARK: - Toggle

    /// Flips a step optimistically, then PUTs the new completed state.
    /// Concurrent toggles of the same step are last-writer-wins locally:
    /// before applying the server response — and before reverting on failure —
    /// we re-check that the step's local `completed` matches our optimistic
    /// flip; if a newer toggle moved it, we leave that state alone.
    func toggleStep(_ step: FizzyStep) async {
        errorMessage = nil
        guard let row = repository.fetchSteps(for: card).first(where: { $0.fizzyStepID == step.id }) else {
            return
        }
        let originalCompleted = step.completed
        let flippedCompleted = !originalCompleted
        repository.toggleCompleted(row)          // sets pendingWrite = true
        publishFromCache()

        do {
            let updated = try await client.updateStep(
                cardNumber: cardNumber,
                id: step.id,
                completed: flippedCompleted
            )
            // Re-fetch in case a newer toggle already changed it
            if let r = repository.fetchSteps(for: card).first(where: { $0.fizzyStepID == step.id }),
               r.completed == flippedCompleted {
                repository.confirmToggle(r, serverStep: updated)
                publishFromCache()
            }
        } catch {
            if let r = repository.fetchSteps(for: card).first(where: { $0.fizzyStepID == step.id }),
               r.completed == flippedCompleted {
                repository.revertToggle(r, originalCompleted: originalCompleted)
                publishFromCache()
            }
            errorMessage = "Couldn't update the step."
        }
    }

    // MARK: - Delete

    /// Write-through delete: removes the row from the UI optimistically, sends
    /// DELETE to the server, then removes from CoreData on 2xx/404. On any
    /// other error the row is restored in the UI and kept in CoreData.
    func deleteStep(_ step: FizzyStep) async {
        errorMessage = nil
        guard let index = steps.firstIndex(where: { $0.id == step.id }) else { return }
        steps.remove(at: index)    // optimistic UI removal

        do {
            try await client.deleteStep(cardNumber: cardNumber, id: step.id)
            // Server confirmed: delete the CoreData row
            if let row = repository.fetchSteps(for: card).first(where: { $0.fizzyStepID == step.id }) {
                repository.deleteStep(row)
            }
        } catch {
            // Revert: restore step in UI at its original position
            steps.insert(step, at: min(index, steps.count))
            errorMessage = "Couldn't delete the step."
        }
    }

    func deleteSteps(at offsets: IndexSet) async {
        // Snapshot values before any await (index shifts after each deletion)
        let toDelete = offsets.compactMap { steps.indices.contains($0) ? steps[$0] : nil }
        for step in toDelete {
            await deleteStep(step)
        }
    }

    // MARK: - Retry seam

    /// Re-sends all `pendingWrite == true` rows for this card. Each pending
    /// step is PUTted with its current local state. On success, `pendingWrite`
    /// is cleared. On failure, `pendingWrite` stays `true` for the next cycle.
    ///
    /// Called by the FizzySyncProvider scheduler tick (same pattern as
    /// CommentRepository.retryPending — the orchestrator calls both
    /// repositories on each sync cycle; #63/#64 reconciliation note).
    func retryPending() async {
        let pending = repository.fetchPendingSteps(for: card)
        for row in pending {
            guard let stepID = row.fizzyStepID else { continue }
            do {
                let updated = try await client.updateStep(
                    cardNumber: cardNumber,
                    id: stepID,
                    completed: row.completed
                )
                repository.confirmToggle(row, serverStep: updated)
            } catch {
                // Leave pendingWrite = true; will retry on next cycle
            }
        }
        publishFromCache()
    }

    // MARK: - Private

    private func publishFromCache() {
        let rows = repository.fetchSteps(for: card)
        steps = rows.map { row in
            FizzyStep(
                id: row.fizzyStepID ?? "pending-\(row.objectID.uriRepresentation().lastPathComponent)",
                content: row.content ?? "",
                completed: row.completed
            )
        }
    }
}
