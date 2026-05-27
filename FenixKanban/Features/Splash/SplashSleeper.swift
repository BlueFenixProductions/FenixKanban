protocol SplashSleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

struct TaskSleeper: SplashSleeper {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
