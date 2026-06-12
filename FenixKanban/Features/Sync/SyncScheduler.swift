import Foundation
import SwiftUI

/// Foreground auto-refresh scheduler for Fizzy sync.
///
/// Owns a `Task` loop that calls the injected `SyncTriggering` provider
/// every `interval` seconds **while**:
///   - the scene is active (`setSceneActive(true)`)
///   - the provider reports `isPaired == true`
///
/// Reentrancy is guarded by `isSyncing`: if the previous call hasn't
/// returned yet, the tick is skipped (the engine's own guard also prevents
/// duplicate HTTP work, but the scheduler adds a second layer so the
/// `activityState` never flips twice).
///
/// Injectable `interval` (default 300 s) so tests can run at millisecond
/// resolution without a test clock abstraction.
@Observable
@MainActor
final class SyncScheduler {

    // MARK: - Public state

    let activityState = SyncActivityState()

    // MARK: - Private

    private let provider: any SyncTriggering
    private let interval: Duration
    private var loopTask: Task<Void, Never>?
    private var isSyncing = false
    private var isSceneActive = false

    // MARK: - Init

    init(
        provider: any SyncTriggering,
        interval: Duration = .seconds(300)
    ) {
        self.provider = provider
        self.interval = interval
    }

    // Note: loopTask cancellation is intentionally triggered by setSceneActive(false)
    // rather than deinit, because @MainActor properties cannot be accessed
    // from a nonisolated deinit context. The scheduler is app-lifetime
    // anyway — it outlives every scene phase.

    // MARK: - Scene lifecycle

    /// Called by `ContentView` / `FenixKanbanApp` when
    /// `@Environment(\.scenePhase)` changes.
    func setSceneActive(_ active: Bool) {
        isSceneActive = active
        if active {
            startLoop()
        } else {
            stopLoop()
        }
    }

    // MARK: - Private loop

    private func startLoop() {
        guard loopTask == nil || loopTask?.isCancelled == true else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // Sleep first so we don't fire immediately on launch —
                // the user may have just foregrounded and the last sync
                // may still be fresh.
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    // CancellationError — break cleanly
                    return
                }
                await self.fireTick()
            }
        }
    }

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
        // If we were mid-sync when stopped, reset state cleanly.
        if case .syncing = activityState.phase {
            activityState.markIdle(syncedAt: activityState.lastSyncAt)
        }
    }

    private func fireTick() async {
        guard isSceneActive,
              provider.isPaired,
              !isSyncing else { return }
        isSyncing = true
        activityState.markSyncing()
        // Delegate to the provider variant that routes outcomes to activityState.
        // The provider marks .error on thrown errors or non-empty result.errors;
        // it advances lastSyncAt on partial-failure cycles (the cycle ran).
        if let fizzyProvider = provider as? FizzySyncProvider {
            await fizzyProvider.triggerSync(activityState: activityState)
            // If the provider left the phase as .syncing (no error, no update),
            // transition to idle.
            if case .syncing = activityState.phase {
                activityState.markIdle(syncedAt: activityState.lastSyncAt)
            }
        } else {
            // Non-Fizzy providers (test spy, future providers) use the plain path.
            await provider.triggerSync()
            activityState.markIdle(syncedAt: Date())
        }
        isSyncing = false
    }
}
