import Foundation

/// Orchestrates a single BGAppRefreshTask sync cycle.
///
/// BGTaskScheduler itself is wired in `FenixKanbanApp` (iOS-only, using the
/// `.backgroundTask(.appRefresh(…))` scene modifier). This coordinator is the
/// testable seam: it accepts any `SyncTriggering` provider and enforces the
/// time budget without touching `BGTaskScheduler` directly.
///
/// - Returns `true`  — sync completed within budget
/// - Returns `false` — not paired, or budget exceeded (timed out)
///
/// Never throws; background task handlers must swallow errors and call
/// `setTaskCompleted(success:)` regardless.
@MainActor
final class BackgroundRefreshCoordinator {

    // MARK: - Private

    private let provider: any SyncTriggering
    private let budgetSeconds: Double
    private let clock: any Clock<Duration>

    // MARK: - Init

    /// - Parameters:
    ///   - provider: The sync-triggering seam (production: `FizzySyncProvider`).
    ///   - budgetSeconds: Seconds allowed for the sync. The
    ///     `BGAppRefreshTask` system budget is ~30 s; production passes 25 s
    ///     to leave a 5 s margin for overhead.
    ///   - clock: Clock used for the deadline sleep. Defaults to
    ///     `ContinuousClock()` (wall time) so production behaviour is
    ///     unchanged. Tests inject `ManualClock` for determinism.
    init(
        provider: any SyncTriggering,
        budgetSeconds: Double = 25,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.provider = provider
        self.budgetSeconds = budgetSeconds
        self.clock = clock
    }

    // MARK: - Public entry point

    /// Run one sync cycle within the time budget.
    ///
    /// Called by the `FenixKanbanApp` `.backgroundTask(.appRefresh(…))`
    /// handler on iOS. The return value is forwarded to
    /// `BGTask.setTaskCompleted(success:)`.
    func performBackgroundRefresh() async -> Bool {
        guard provider.isPaired else { return false }

        // Race the sync against the budget deadline.
        return await withTaskGroup(of: Bool.self) { group in
            // The sync task
            group.addTask { [provider] in
                await provider.triggerSync()
                return true
            }

            // The budget / deadline task — uses the injected clock so tests
            // can advance time deterministically instead of waiting real seconds.
            group.addTask { [budgetSeconds, clock] in
                do {
                    try await clock.sleep(for: .seconds(budgetSeconds))
                } catch {
                    // Cancelled — sync finished first, propagate success
                    return true
                }
                // Timeout elapsed before sync finished
                return false
            }

            // Take whichever completes first
            let result = await group.next() ?? false
            // Cancel the remaining task (either the still-running sync
            // or the still-pending deadline timer).
            group.cancelAll()
            return result
        }
    }
}
