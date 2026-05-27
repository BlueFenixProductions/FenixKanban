import Testing
import Foundation
@testable import FenixKanban

/// Recording fake — captures every sleep duration so tests can assert
/// the timeline executed without burning real wall-clock time.
final class RecordingSplashSleeper: SplashSleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var _sleeps: [Duration] = []

    var sleeps: [Duration] {
        lock.lock(); defer { lock.unlock() }
        return _sleeps
    }

    func sleep(for duration: Duration) async throws {
        lock.lock()
        _sleeps.append(duration)
        lock.unlock()
        await Task.yield()
    }
}

@Suite("SplashState")
@MainActor
struct SplashStateTests {
    @Test("Initial phase is .pulsing")
    func initialPhase() {
        let state = SplashState()
        #expect(state.phase == .pulsing)
    }

    @Test("start() drives phase to .done")
    func endsAtDone() async {
        let state = SplashState()
        let sleeper = RecordingSplashSleeper()
        await state.start(sleeper: sleeper)
        #expect(state.phase == .done)
    }

    @Test("start() sleeps for pulseDuration then fadeDuration")
    func timelineDurations() async {
        let state = SplashState()
        let sleeper = RecordingSplashSleeper()
        await state.start(sleeper: sleeper)
        #expect(sleeper.sleeps == [SplashState.pulseDuration, SplashState.fadeDuration])
    }

    @Test("totalDuration equals pulse + fade")
    func durationsAddUp() {
        #expect(SplashState.totalDuration == SplashState.pulseDuration + SplashState.fadeDuration)
    }

    @Test("start() is idempotent — second call is a no-op")
    func idempotent() async {
        let state = SplashState()
        let sleeper = RecordingSplashSleeper()
        await state.start(sleeper: sleeper)
        await state.start(sleeper: sleeper)
        #expect(sleeper.sleeps.count == 2)  // not 4
        #expect(state.phase == .done)
    }
}
