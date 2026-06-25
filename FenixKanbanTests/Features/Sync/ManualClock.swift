import Foundation

// MARK: - ManualClock

/// A deterministic test clock whose time only advances when the test calls
/// `advance(by:)`.  Sleepers are suspended on continuations and resumed once
/// their deadline is crossed.
///
/// Typical usage in a `@MainActor` Swift Testing test:
///
/// ```swift
/// let clock = ManualClock()
/// let scheduler = SyncScheduler(provider: spy, interval: .seconds(1), clock: clock)
/// scheduler.setSceneActive(true)
///
/// // Wait for the loop to actually suspend in clock.sleep before advancing.
/// await clock.waitForSleeper()
/// await clock.advance(by: .seconds(1))
/// #expect(spy.callCount >= 1)
/// ```
///
/// `waitForSleeper()` is the key — without it, `advance()` would run before
/// the loop task has had a chance to call `sleep(until:)`, so there would be
/// no sleepers to wake.
final class ManualClock: Clock, @unchecked Sendable {

    // MARK: - Instant

    struct Instant: InstantProtocol {
        var offset: Duration

        static var zero: Instant { Instant(offset: .zero) }

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    // MARK: - Clock conformance

    var now: Instant {
        lock.withLock { _now }
    }

    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        try Task.checkCancellation()

        // Fast path: already past deadline.
        if lock.withLock({ _now }) >= deadline {
            await Task.yield()
            return
        }

        // Register a continuation keyed to a stable UUID owned by this call.
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                // Take the lock once; handle both the double-check and the
                // sleeper-waiter notification inside it.
                var waitersToResume: [CheckedContinuation<Void, Never>] = []
                lock.withLock {
                    if _now >= deadline {
                        cont.resume()
                    } else {
                        sleepers[id] = Sleeper(deadline: deadline, continuation: cont)
                        // Collect waiters to resume outside the lock.
                        waitersToResume = sleeperWaiters
                        sleeperWaiters.removeAll()
                    }
                }
                // Resume sleeperWaiters outside the lock (safe: NSLock is not reentrant).
                for waiter in waitersToResume {
                    waiter.resume()
                }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    // MARK: - Time advancement

    /// Advance `now` by `duration`, waking all sleepers whose deadline is
    /// ≤ the new `now`.  Yields several times after resuming so woken tasks
    /// have time to run before the caller continues asserting.
    func advance(by duration: Duration) async {
        let woken: [Sleeper] = lock.withLock {
            _now = _now.advanced(by: duration)
            let threshold = _now
            var woken: [Sleeper] = []
            for (key, sleeper) in sleepers where sleeper.deadline <= threshold {
                woken.append(sleeper)
                sleepers.removeValue(forKey: key)
            }
            return woken
        }

        for sleeper in woken {
            sleeper.continuation.resume()
        }

        // Multiple yields give resumed tasks (and their downstream MainActor
        // work) time to complete before the caller's assertion.
        for _ in 0..<8 {
            await Task.yield()
        }
    }

    // MARK: - Test synchronisation

    /// Suspend until at least one task has registered a sleep with this clock.
    ///
    /// Call this after starting the scheduler and before calling `advance(by:)`
    /// to guarantee the loop has actually suspended in `sleep(until:)`.
    func waitForSleeper() async {
        // Fast path: already have a sleeper.
        if lock.withLock({ !sleepers.isEmpty }) { return }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.withLock {
                // Double-check under the lock.
                if sleepers.isEmpty {
                    sleeperWaiters.append(cont)
                } else {
                    cont.resume()
                }
            }
        }
    }

    // MARK: - Private

    private var _now: Instant = .zero
    private let lock = NSLock()
    private var sleepers: [UUID: Sleeper] = [:]
    private var sleeperWaiters: [CheckedContinuation<Void, Never>] = []

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }
}

// MARK: - NSLock helper

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
