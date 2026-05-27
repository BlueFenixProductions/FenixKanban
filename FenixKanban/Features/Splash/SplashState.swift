import Observation

@Observable
@MainActor
final class SplashState {
    enum Phase: Equatable { case pulsing, fading, done }

    static let pulseDuration: Duration = .milliseconds(450)
    static let fadeDuration: Duration = .milliseconds(650)
    static let totalDuration: Duration = .milliseconds(1100)

    private(set) var phase: Phase = .pulsing
    private var hasStarted = false

    func start(sleeper: SplashSleeper = TaskSleeper()) async {
        guard !hasStarted else { return }
        hasStarted = true

        // try? intentional: cancellation should still drive phase to .done
        // so the splash overlay always clears, even when the task is cancelled.
        try? await sleeper.sleep(for: Self.pulseDuration)
        phase = .fading
        try? await sleeper.sleep(for: Self.fadeDuration)
        phase = .done
    }
}
