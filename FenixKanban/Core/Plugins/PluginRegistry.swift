import Foundation
import SwiftUI

/// Central registry for discovered sync providers.
/// Main-actor-isolated to match `BoardSyncProvider`'s isolation.
@Observable
@MainActor
final class PluginRegistry {
    static let shared = PluginRegistry()

    private(set) var providers: [any BoardSyncProvider] = []

    /// Register a sync provider (called by plugin packages at app launch)
    func register(_ provider: any BoardSyncProvider) {
        providers.append(provider)
    }

    var hasSyncProviders: Bool {
        !providers.isEmpty
    }

    func provider(named: String) -> (any BoardSyncProvider)? {
        providers.first { $0.providerName == named }
    }
}
