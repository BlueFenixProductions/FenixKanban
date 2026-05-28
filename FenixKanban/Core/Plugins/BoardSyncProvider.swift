import Foundation

/// Protocol for external board sync providers (e.g., GitHub Projects, Jira, Linear).
///
/// Providers are main-actor-isolated because their requirements typically touch
/// UI-bound state (CoreData viewContext, SwiftUI `@Observable` registries, the
/// auth keychain). Conforming types may freely access main-actor state; callers
/// must invoke methods from a `@MainActor` context.
@MainActor
public protocol BoardSyncProvider {
    /// Display name for the provider (e.g., "GitHub Projects")
    var providerName: String { get }

    /// SF Symbol name for the provider icon
    var iconName: String { get }

    /// Whether the provider is currently authenticated
    var isAuthenticated: Bool { get }

    /// Authenticate with the provider (OAuth flow, token entry, etc.)
    func authenticate() async throws

    /// Sign out from the provider
    func signOut() async throws

    /// Fetch remote boards/projects available for syncing
    func fetchRemoteBoards() async throws -> [RemoteBoard]

    /// Sync a local board with a remote project
    func sync(boardId: UUID, remoteProjectId: String) async throws -> SyncResult

    /// Get the last sync date for a board
    func lastSyncDate(for boardId: UUID) -> Date?
}

/// Represents a remote board/project from an external provider
public struct RemoteBoard: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let url: URL?
    public let provider: String

    public init(id: String, name: String, description: String? = nil, url: URL? = nil, provider: String) {
        self.id = id
        self.name = name
        self.description = description
        self.url = url
        self.provider = provider
    }
}

/// Result of a sync operation
public struct SyncResult: Sendable {
    public let itemsCreated: Int
    public let itemsUpdated: Int
    public let itemsDeleted: Int
    public let errors: [String]
    public let syncDate: Date

    public init(itemsCreated: Int, itemsUpdated: Int, itemsDeleted: Int, errors: [String] = [], syncDate: Date = .now) {
        self.itemsCreated = itemsCreated
        self.itemsUpdated = itemsUpdated
        self.itemsDeleted = itemsDeleted
        self.errors = errors
        self.syncDate = syncDate
    }
}
