import Foundation

/// Minimal dependency seam the scheduler uses to trigger a sync cycle.
///
/// `FizzySyncProvider` conforms via an extension in the same file.
/// Tests inject a `SyncSpy` that records calls without touching the network.
@MainActor
protocol SyncTriggering: AnyObject {
    /// `true` when the provider has both token and board pairing configured.
    var isPaired: Bool { get }
    /// Fire one sync cycle. May be a no-op if the engine's own reentrancy
    /// guard is already holding a lock (the engine returns an empty result
    /// immediately in that case — no double-execution).
    func triggerSync() async
}
