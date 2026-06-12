import Foundation
import Testing
@testable import FenixKanban

// MARK: - NeverReturnSpy

/// SyncTriggering spy whose `triggerSync` blocks until cancelled.
/// Used to verify the time-budget enforcement path.
@MainActor
final class NeverReturnSpy: SyncTriggering {
    var isPaired: Bool = true
    var callCount = 0
    var didObserveCancellation = false

    func triggerSync() async {
        callCount += 1
        // Block on a continuation that releases the moment the coordinator
        // cancels this child — no real sleep anywhere. A 300s Task.sleep
        // here outlived suite teardown on starved CI runners and tripped
        // the test-runner watchdog (crash-restart, zero failing tests).
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    cont.resume()
                } else {
                    self.blocked = cont
                }
            }
        } onCancel: {
            self.didObserveCancellation = true
            self.blocked?.resume()
            self.blocked = nil
        }
    }

    private var blocked: CheckedContinuation<Void, Never>?
}

// MARK: - Tests

@Suite("BackgroundRefreshCoordinator")
@MainActor
struct BackgroundRefreshTests {

    // MARK: (a) triggers exactly one sync and reports success

    @Test("triggers one sync and returns true when provider completes within budget")
    func triggersOneSyncAndReportsSuccess() async throws {
        let spy = SyncSpy(isPaired: true)
        let coordinator = BackgroundRefreshCoordinator(
            provider: spy,
            budgetSeconds: 25
        )

        let result = await coordinator.performBackgroundRefresh()

        #expect(spy.callCount == 1)
        #expect(result == true)
    }

    // MARK: (b) reports failure when provider never returns (times out)

    @Test("returns false when provider does not complete before budget expires")
    func reportsFailureOnTimeout() async throws {
        let spy = NeverReturnSpy()
        let coordinator = BackgroundRefreshCoordinator(
            provider: spy,
            budgetSeconds: 0.1   // 100 ms budget for testing
        )

        let result = await coordinator.performBackgroundRefresh()

        #expect(spy.callCount == 1)
        #expect(result == false)
    }

    // MARK: (c) respects the time budget — completes within budget + small slack

    @Test("completes within budget even when provider would block forever")
    func respectsTimeBudget() async throws {
        let spy = NeverReturnSpy()
        let coordinator = BackgroundRefreshCoordinator(
            provider: spy,
            budgetSeconds: 0.1   // 100 ms budget
        )

        let start = ContinuousClock.now
        _ = await coordinator.performBackgroundRefresh()
        let elapsed = ContinuousClock.now - start

        // Should return well within a 5-second observation window
        // Generous bound: CI runners stall scheduling under load (observed
        // 5.96s for a ~2s budget). The behavioral claim is "completes near
        // the budget, not at the provider's 300s block" — a deterministic
        // ManualClock rewrite follows once #46 merges (mission task #32).
        #expect(elapsed < .seconds(20))
    }

    // MARK: (d) does not run when unpaired

    @Test("does not trigger sync and returns false when provider is not paired")
    func doesNotRunWhenUnpaired() async throws {
        let spy = SyncSpy(isPaired: false)
        let coordinator = BackgroundRefreshCoordinator(
            provider: spy,
            budgetSeconds: 25
        )

        let result = await coordinator.performBackgroundRefresh()

        #expect(spy.callCount == 0)
        #expect(result == false)
    }
}
