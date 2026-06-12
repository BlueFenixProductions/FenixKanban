import Foundation
import Testing
@testable import FenixKanban

// MARK: - Spy

/// Spy for SyncTriggering used across tests.
@MainActor
final class SyncSpy: SyncTriggering {
    var isPaired: Bool
    var callCount = 0
    var callDates: [Date] = []

    /// When set, each `triggerSync` call suspends on a continuation.
    /// Tests call `releaseAll()` to unblock pending calls.
    private var slowMode = false
    private var slowContinuations: [CheckedContinuation<Void, Never>] = []

    init(isPaired: Bool = true) {
        self.isPaired = isPaired
    }

    func triggerSync() async {
        callCount += 1
        callDates.append(Date())
        if slowMode {
            // Suspend until the test releases us.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                slowContinuations.append(cont)
            }
        }
    }

    /// Make all future triggerSync calls block until explicitly released.
    func makeSlow() {
        slowMode = true
    }

    /// Release all pending blocked triggerSync calls.
    func releaseAll() {
        let conts = slowContinuations
        slowContinuations.removeAll()
        for cont in conts { cont.resume() }
    }
}

// MARK: - Tests

@Suite("SyncScheduler")
@MainActor
struct SyncSchedulerTests {

    // MARK: (a) fires after interval while active

<<<<<<< HEAD
    /// Previously flaky: used real wall-clock Task.sleep on both sides of the
    /// scheduler/test boundary; under parallel load the loop task's continuation
    /// was not scheduled before the test checked callCount.
    ///
    /// Fix: inject ManualClock.  `waitForSleeper()` guarantees the loop has
    /// actually suspended in `clock.sleep(until:)` before we advance time,
    /// making the wakeup deterministic.
    @Test("fires sync after interval elapses while scene is active")
=======
    @Test("fires sync after interval elapses while scene is active",
          .disabled("Flaky under CI load (wall-clock race) — deterministic rewrite lands in #65"))
>>>>>>> origin/develop
    func firesAfterIntervalWhileActive() async throws {
        let clock = ManualClock()
        let spy = SyncSpy(isPaired: true)
        let scheduler = SyncScheduler(
            provider: spy,
            interval: .seconds(1),
            clock: clock
        )

        scheduler.setSceneActive(true)

        // Wait until the loop task has suspended in clock.sleep; only then
        // advance time so we know we're waking a real sleeper.
        await clock.waitForSleeper()
        await clock.advance(by: .seconds(1))

        #expect(spy.callCount >= 1)

        scheduler.setSceneActive(false)
    }

    // MARK: (b) suspends when scenePhase inactive/background

    @Test("does not fire when scene is inactive/background")
    func doesNotFireWhenInactive() async throws {
        let clock = ManualClock()
        let spy = SyncSpy(isPaired: true)
        let scheduler = SyncScheduler(
            provider: spy,
            interval: .seconds(1),
            clock: clock
        )

        // Scene never goes active — no loop task started, no sleeper registered.
        scheduler.setSceneActive(false)
        await clock.advance(by: .seconds(10))

        #expect(spy.callCount == 0)
    }

    @Test("stops firing after transitioning to inactive")
    func stopsFiringOnInactiveTransition() async throws {
        let clock = ManualClock()
        let spy = SyncSpy(isPaired: true)
        let scheduler = SyncScheduler(
            provider: spy,
            interval: .seconds(1),
            clock: clock
        )

        scheduler.setSceneActive(true)

        // Wait for the loop to enter sleep, then fire once.
        await clock.waitForSleeper()
        await clock.advance(by: .seconds(1))
        let countAtStop = spy.callCount
        #expect(countAtStop >= 1)

        // Go inactive — loop task gets cancelled.
        scheduler.setSceneActive(false)

        // Advancing more should produce no further calls.
        await clock.advance(by: .seconds(5))
        #expect(spy.callCount == countAtStop)
    }

    // MARK: (c) does not double-fire when manual sync running

<<<<<<< HEAD
    /// Previously flaky: same real-sleep race as (a).
    ///
    /// Fix: ManualClock advances time so the loop fires twice in quick
    /// succession; because the first triggerSync blocks (spy.makeSlow()),
    /// isSyncing stays true for the second tick and callCount stays 1.
    @Test("does not start a second sync while one is already in flight")
=======
    @Test("does not start a second sync while one is already in flight",
          .disabled("Flaky under CI load (wall-clock race) — deterministic rewrite lands in #65"))
>>>>>>> origin/develop
    func noDoubleFire() async throws {
        let clock = ManualClock()
        let spy = SyncSpy(isPaired: true)
        spy.makeSlow()  // first triggerSync will block

        let scheduler = SyncScheduler(
            provider: spy,
            interval: .seconds(1),
            clock: clock
        )
        scheduler.setSceneActive(true)

        // Advance past the first interval — fires tick 1 (blocks in triggerSync).
        await clock.waitForSleeper()
        await clock.advance(by: .seconds(1))
        #expect(spy.callCount == 1)

        // The loop is now blocked in triggerSync (isSyncing == true).
        // Advance past a second interval — tick 2 must be skipped.
        // Note: the loop won't have re-registered a sleeper because it's
        // blocked in fireTick(); so we just advance and yield.
        await clock.advance(by: .seconds(1))
        #expect(spy.callCount == 1)

        // Clean up.
        scheduler.setSceneActive(false)
        spy.releaseAll()
    }

    // MARK: (d) does not fire when unpaired

    @Test("does not fire when provider is not paired")
    func doesNotFireWhenUnpaired() async throws {
        let clock = ManualClock()
        let spy = SyncSpy(isPaired: false)
        let scheduler = SyncScheduler(
            provider: spy,
            interval: .seconds(1),
            clock: clock
        )

        scheduler.setSceneActive(true)
        await clock.waitForSleeper()
        await clock.advance(by: .seconds(3))
        scheduler.setSceneActive(false)

        #expect(spy.callCount == 0)
    }

    // MARK: SyncActivityState transitions

    @Test("activityState reflects idle before any sync")
    func activityStateIdleInitially() {
        let spy = SyncSpy(isPaired: true)
        let scheduler = SyncScheduler(
            provider: spy,
            interval: .seconds(300)
        )
        if case .idle = scheduler.activityState.phase {
            // pass
        } else {
            Issue.record("Expected idle, got \(scheduler.activityState.phase)")
        }
    }

    @Test("lastSyncAt is nil until a sync completes")
    func lastSyncAtNilInitially() {
        let spy = SyncSpy(isPaired: true)
        let scheduler = SyncScheduler(
            provider: spy,
            interval: .seconds(300)
        )
        #expect(scheduler.activityState.lastSyncAt == nil)
    }

    @Test("activityState transitions to syncing then back to idle")
    func activityStateTransitions() async throws {
        let clock = ManualClock()
        let spy = SyncSpy(isPaired: true)
        let scheduler = SyncScheduler(
            provider: spy,
            interval: .seconds(1),
            clock: clock
        )

        scheduler.setSceneActive(true)
        await clock.waitForSleeper()
        await clock.advance(by: .seconds(1))
        scheduler.setSceneActive(false)

        // After stopping, state should be idle (not stuck in syncing).
        if case .idle = scheduler.activityState.phase {
            // pass
        } else {
            Issue.record("Expected idle after stop, got \(scheduler.activityState.phase)")
        }
    }
}

// MARK: - CardSyncBadgeState tests

@Suite("CardSyncBadgeState")
struct CardSyncBadgeStateTests {

    @Test("paired card shows synced badge")
    func pairedShowsSynced() {
        // A card paired in the store → synced
        let state = CardSyncBadgeState.resolve(hasPairing: true, boardIsPaired: true)
        #expect(state == .synced)
    }

    @Test("unpaired card on paired board shows pending badge")
    func unpairedOnPairedBoardShowsPending() {
        // Board is paired but this specific card isn't yet
        let state = CardSyncBadgeState.resolve(hasPairing: false, boardIsPaired: true)
        #expect(state == .pending)
    }

    @Test("card on unpaired board shows none")
    func unpairedBoardShowsNone() {
        let state = CardSyncBadgeState.resolve(hasPairing: false, boardIsPaired: false)
        #expect(state == .none)
    }

    @Test("pairedCard on unpaired board shows none (defensive)")
    func pairedCardUnpairedBoard() {
        // Shouldn't happen but guard defensively
        let state = CardSyncBadgeState.resolve(hasPairing: true, boardIsPaired: false)
        #expect(state == .none)
    }
}
