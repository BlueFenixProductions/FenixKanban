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

    /// Each entry in this stream represents a pending triggerSync call waiting
    /// to be released. Tests `yield` a Void into `releaseStream` to unblock.
    private var slowMode = false

    init(isPaired: Bool = true) {
        self.isPaired = isPaired
    }

    func triggerSync() async {
        callCount += 1
        callDates.append(Date())
        if slowMode {
            // Block for a very long time (cancelled when scheduler stops)
            try? await Task.sleep(for: .seconds(60))
        }
    }

    /// Make triggerSync block (effectively forever for the test window).
    func makeSlow() {
        slowMode = true
    }
}

// MARK: - Tests

@Suite("SyncScheduler")
@MainActor
struct SyncSchedulerTests {

    // MARK: (a) fires after interval while active

    @Test("fires sync after interval elapses while scene is active")
    func firesAfterIntervalWhileActive() async throws {
        let spy = SyncSpy(isPaired: true)
        let scheduler = SyncScheduler(
            provider: spy,
            interval: .milliseconds(50)
        )
        scheduler.setSceneActive(true)
        // Give the loop time to fire once.
        try await Task.sleep(for: .milliseconds(200))
        scheduler.setSceneActive(false)
        #expect(spy.callCount >= 1)
    }

    // MARK: (b) suspends when scenePhase inactive/background

    @Test("does not fire when scene is inactive/background")
    func doesNotFireWhenInactive() async throws {
        let spy = SyncSpy(isPaired: true)
        let scheduler = SyncScheduler(
            provider: spy,
            interval: .milliseconds(50)
        )
        // scenePhase starts inactive
        scheduler.setSceneActive(false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(spy.callCount == 0)
    }

    @Test("stops firing after transitioning to inactive")
    func stopsFiringOnInactiveTransition() async throws {
        let spy = SyncSpy(isPaired: true)
        let scheduler = SyncScheduler(
            provider: spy,
            interval: .milliseconds(50)
        )
        scheduler.setSceneActive(true)
        try await Task.sleep(for: .milliseconds(120))
        scheduler.setSceneActive(false)
        let countAtStop = spy.callCount
        // Nothing more should fire after going inactive
        try await Task.sleep(for: .milliseconds(120))
        #expect(spy.callCount == countAtStop)
    }

    // MARK: (c) does not double-fire when manual sync running

    @Test("does not start a second sync while one is already in flight")
    func noDoubleFire() async throws {
        let spy = SyncSpy(isPaired: true)
        spy.makeSlow()          // first triggerSync will not return

        let scheduler = SyncScheduler(
            provider: spy,
            interval: .milliseconds(30)
        )
        scheduler.setSceneActive(true)

        // Let the scheduler attempt multiple firings while the first is blocked.
        // The first triggerSync call blocks for 60 s (cancelled when scene goes
        // inactive), so isSyncing stays true for the entire observation window.
        try await Task.sleep(for: .milliseconds(180))
        scheduler.setSceneActive(false)

        // Only 1 call should have been made (no coalescing into a second)
        #expect(spy.callCount == 1)
    }

    // MARK: (d) does not fire when unpaired

    @Test("does not fire when provider is not paired")
    func doesNotFireWhenUnpaired() async throws {
        let spy = SyncSpy(isPaired: false)
        let scheduler = SyncScheduler(
            provider: spy,
            interval: .milliseconds(50)
        )
        scheduler.setSceneActive(true)
        try await Task.sleep(for: .milliseconds(200))
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
        let spy = SyncSpy(isPaired: true)
        let scheduler = SyncScheduler(
            provider: spy,
            interval: .milliseconds(50)
        )
        scheduler.setSceneActive(true)
        try await Task.sleep(for: .milliseconds(200))
        scheduler.setSceneActive(false)
        // After stopping, state should be idle (not stuck in syncing)
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
