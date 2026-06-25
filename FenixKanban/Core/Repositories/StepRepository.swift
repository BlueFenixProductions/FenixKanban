import CoreData

/// Cache layer for `CardStep` rows — wraps CoreData fetch/upsert/create/
/// toggle/delete operations for a card's checklist. All writes are
/// synchronous on the calling context (viewContext or a test in-memory store).
///
/// Delete semantics: write-through. A delete call sends the request to the
/// server immediately. The row is removed from CoreData only on 2xx/404
/// confirmation; on any other error the row is kept (with pendingWrite
/// unchanged) so the caller can surface the failure and restore the UI.
///
/// Retry seam: `pendingWrite == true` marks rows that need re-posting
/// (created/toggled while offline or after a failed write). Callers
/// invoke `retryPending(cardNumber:client:)` on a scheduler tick — the seam
/// mirrors CommentRepository's `retryPending` hook for easy orchestration
/// by FizzySyncProvider or a background scheduler (#63/#64 reconciliation
/// note: both repositories expose `retryPending()` on the same principle;
/// the orchestrator calls each independently on its sync tick).
final class StepRepository {
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    // MARK: - Fetch

    /// Returns all `CardStep` rows for `card`, sorted by `sortOrder` ascending.
    func fetchSteps(for card: Card) -> [CardStep] {
        let request = CardStep.fetchRequest()
        request.predicate = NSPredicate(format: "card == %@", card)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CardStep.sortOrder, ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    // MARK: - Upsert (server-authoritative reconcile)

    /// Reconciles server-supplied `[FizzyStep]` into CoreData for `card`.
    ///
    /// Rules:
    /// - Existing rows that match by `fizzyStepID` are updated (content,
    ///   completed, sortOrder) **unless** `pendingWrite == true` — pending
    ///   rows keep their local state (the local write is in-flight or failed;
    ///   it will reconcile after the write resolves).
    /// - Server rows without a matching local row are inserted.
    /// - Local rows with a `fizzyStepID` that are **absent** from the server
    ///   response are deleted (server-authoritative).
    /// - Local rows with `fizzyStepID == nil` (pending creates) are always
    ///   preserved — they haven't been assigned a server ID yet.
    func upsert(serverSteps: [FizzyStep], for card: Card) {
        let existing = fetchSteps(for: card)
        let existingByID = Dictionary(
            existing.compactMap { s in s.fizzyStepID.map { ($0, s) } },
            uniquingKeysWith: { first, _ in first }
        )
        let serverIDs = Set(serverSteps.map(\.id))

        // Update or insert each server step.
        for (index, serverStep) in serverSteps.enumerated() {
            if let row = existingByID[serverStep.id] {
                // Existing row: only update if not pending (pending = local write in flight)
                if !row.pendingWrite {
                    row.content = serverStep.content
                    row.completed = serverStep.completed
                    row.sortOrder = Int32(index * 1000)
                }
            } else {
                // New row from server
                let row = CardStep(context: context)
                row.fizzyStepID = serverStep.id
                row.content = serverStep.content
                row.completed = serverStep.completed
                row.sortOrder = Int32(index * 1000)
                row.pendingWrite = false
                row.card = card
            }
        }

        // Delete local rows whose fizzyStepID is no longer in the server response.
        // Never delete rows without a fizzyStepID (those are pending creates).
        for row in existing {
            guard let stepID = row.fizzyStepID else { continue }
            if !serverIDs.contains(stepID) {
                context.delete(row)
            }
        }

        save()
    }

    // MARK: - Create (optimistic local)

    /// Inserts a new `CardStep` with `pendingWrite = true`. The caller is
    /// responsible for POSTing to the server and calling `confirmCreate(_:serverStep:)`
    /// on success, or handling failure.
    @discardableResult
    func createLocalStep(for card: Card, content: String) -> CardStep {
        let row = CardStep(context: context)
        row.fizzyStepID = nil
        row.content = content
        row.completed = false
        row.sortOrder = nextSortOrder(for: card)
        row.pendingWrite = true
        row.card = card
        save()
        return row
    }

    /// Called after a successful POST to assign the server's ID and clear
    /// `pendingWrite`. `step` must be the row returned by `createLocalStep`.
    func confirmCreate(_ step: CardStep, serverStep: FizzyStep) {
        step.fizzyStepID = serverStep.id
        step.content = serverStep.content
        step.completed = serverStep.completed
        step.pendingWrite = false
        save()
    }

    // MARK: - Toggle (optimistic)

    /// Flips `completed` and sets `pendingWrite = true`. After a successful
    /// PUT call `confirmToggle(_:serverStep:)` to apply the server response
    /// and clear `pendingWrite`. On failure, call `revertToggle(_:originalValue:)`
    /// and leave `pendingWrite = true` for retry.
    func toggleCompleted(_ step: CardStep) {
        step.completed = !step.completed
        step.pendingWrite = true
        save()
    }

    /// Applies the server response after a successful PUT and clears `pendingWrite`.
    func confirmToggle(_ step: CardStep, serverStep: FizzyStep) {
        step.completed = serverStep.completed
        step.content = serverStep.content
        step.pendingWrite = false
        save()
    }

    /// Reverts the optimistic toggle on failure. `pendingWrite` stays `true`
    /// so the retry seam can re-POST the intended state.
    func revertToggle(_ step: CardStep, originalCompleted: Bool) {
        step.completed = originalCompleted
        // pendingWrite remains true for retry
        save()
    }

    // MARK: - Delete (write-through)

    /// Removes a `CardStep` row from CoreData. Call only after a successful
    /// DELETE (2xx/404). For error handling, do NOT call this — keep the row
    /// and surface the error to the caller.
    func deleteStep(_ step: CardStep) {
        context.delete(step)
        save()
    }

    // MARK: - Pending

    /// Returns all steps for `card` that have `pendingWrite == true` and a
    /// `fizzyStepID` (i.e., they've been confirmed to exist on the server but
    /// their latest local mutation hasn't been flushed).
    func fetchPendingSteps(for card: Card) -> [CardStep] {
        fetchSteps(for: card).filter { $0.pendingWrite && $0.fizzyStepID != nil }
    }

    // MARK: - Private helpers

    private func nextSortOrder(for card: Card) -> Int32 {
        let existing = fetchSteps(for: card)
        let max = existing.map(\.sortOrder).max() ?? -1000
        return max + 1000
    }

    private func save() {
        guard context.hasChanges else { return }
        try? context.save()
    }
}
