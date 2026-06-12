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
            Task { @MainActor in
                self.didObserveCancellation = true
                self.blocked?.resume()
                self.blocked = nil
            }
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
    //
    // Rewritten in #71 to use ManualClock: instead of waiting real wall-clock
    // milliseconds for the 100 ms budget to expire, we:
    //   1. Start performBackgroundRefresh() in a detached task so the test can
    //      drive the clock concurrently.
    //   2. Wait for the budget-deadline sleeper to register with the clock.
    //   3. Advance past the budget — wakes the deadline task immediately.
    //   4. Await the coordinator result — deterministic, zero wall-clock wait.

    @Test("returns false when provider does not complete before budget expires")
    func reportsFailureOnTimeout() async throws {
        let clock = ManualClock()
        let spy = NeverReturnSpy()
        let coordinator = BackgroundRefreshCoordinator(
            provider: spy,
            budgetSeconds: 30,
            clock: clock
        )

        // Launch coordinator in a separate task so we can drive the clock.
        let refreshTask = Task { @MainActor in
            await coordinator.performBackgroundRefresh()
        }

        // Wait until the budget-deadline sleep has registered with the clock,
        // then advance past it — just like SyncSchedulerTests does.
        await clock.waitForSleeper()
        await clock.advance(by: .seconds(31))

        let result = await refreshTask.value

        #expect(spy.callCount == 1)
        #expect(result == false)
    }

    // MARK: (c) budget-deadline sleep is registered before coordinator returns
    //
    // Replaces the old wall-clock elapsed assertion (`elapsed < .seconds(20)`),
    // which was inherently racy under CI load (observed 5.96 s for a 5 s bound).
    // The new test proves the *structure*: the coordinator registers exactly one
    // sleep with the injected clock (the budget deadline), and advancing past it
    // causes performBackgroundRefresh to return false — i.e., the coordinator
    // is clock-driven, not spinning.

    @Test("coordinator registers budget deadline sleep and returns false on clock advance")
    func budgetDeadlineSleepIsDrivenByClock() async throws {
        let clock = ManualClock()
        let spy = NeverReturnSpy()
        let coordinator = BackgroundRefreshCoordinator(
            provider: spy,
            budgetSeconds: 30,
            clock: clock
        )

        let refreshTask = Task { @MainActor in
            await coordinator.performBackgroundRefresh()
        }

        // The coordinator must register a sleep on the clock (the budget timer).
        await clock.waitForSleeper()

        // Advancing past the budget wakes the deadline task → coordinator
        // returns false without any real time passing.
        await clock.advance(by: .seconds(31))

        let result = await refreshTask.value
        #expect(result == false)
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
