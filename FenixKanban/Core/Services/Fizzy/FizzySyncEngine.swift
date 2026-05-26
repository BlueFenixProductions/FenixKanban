import Foundation
import CoreData

/// Orchestrates one-shot first-sync runs between a paired local FenixKanban
/// board and the corresponding Fizzy board.
///
/// Composition is deliberate: the engine owns no Keychain or UserDefaults
/// access of its own — it consumes the Phase 2 `FizzyAuthState` and
/// `FizzyBoardMapping` instances injected at construction. Likewise, all
/// HTTP goes through `FizzyClient`. This keeps the engine fully testable
/// with `MockURLProtocol` and synthetic auth/mapping fixtures.
///
/// Phase 4a covers the three `FirstSyncMode` variants only. Steady-state
/// diff + LWW conflict resolution + soft-delete + 401 handling land in
/// Phase 4b.
@MainActor
final class FizzySyncEngine {

    private let client: FizzyClient
    private let authState: FizzyAuthState
    private let mapping: FizzyBoardMapping
    private let context: NSManagedObjectContext

    init(
        client: FizzyClient,
        authState: FizzyAuthState,
        mapping: FizzyBoardMapping,
        context: NSManagedObjectContext
    ) {
        self.client = client
        self.authState = authState
        self.mapping = mapping
        self.context = context
    }

    /// One-shot first-sync. Caller must have set `authState.accessToken`,
    /// `authState.accountSlug`, `mapping.setPairing(...)` *before* invoking.
    /// Returns an empty `FizzySyncResult` if any of those are missing.
    func syncFirst(mode: FirstSyncMode) async throws -> FizzySyncResult {
        guard authState.isConfigured,
              let localBoardID = mapping.localBoardID,
              let fizzyBoardID = mapping.fizzyBoardID,
              let localBoard = fetchBoard(by: localBoardID)
        else {
            return FizzySyncResult()
        }

        switch mode {
        case .pushLocalToFizzy:
            return try await syncFirstPushLocal(localBoard: localBoard, fizzyBoardID: fizzyBoardID)
        case .replaceLocalWithFizzy:
            return try await syncFirstReplaceLocal(localBoard: localBoard, fizzyBoardID: fizzyBoardID)
        case .mergeIfNoConflicts:
            return try await syncFirstMerge(localBoard: localBoard, fizzyBoardID: fizzyBoardID)
        }
    }

    // MARK: - Mode implementations (skeleton — return empty in this task; filled by Tasks 4-6)

    private func syncFirstPushLocal(localBoard: Board, fizzyBoardID: String) async throws -> FizzySyncResult {
        FizzySyncResult()  // Implemented in Task 4
    }

    private func syncFirstReplaceLocal(localBoard: Board, fizzyBoardID: String) async throws -> FizzySyncResult {
        FizzySyncResult()  // Implemented in Task 5
    }

    private func syncFirstMerge(localBoard: Board, fizzyBoardID: String) async throws -> FizzySyncResult {
        FizzySyncResult()  // Implemented in Task 6
    }

    // MARK: - Lookups

    /// Fetches a local `Board` by its UUID (the form stored in
    /// `FizzyBoardMapping`). Returns `nil` if the board was deleted.
    private func fetchBoard(by id: UUID) -> Board? {
        let request: NSFetchRequest<Board> = Board.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }
}
