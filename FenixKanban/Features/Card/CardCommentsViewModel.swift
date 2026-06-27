import CoreData
import Foundation
import Observation

/// Cache-first comments view model for a fizzy-paired card.
///
/// On init it immediately exposes whatever is in the local cache (instant
/// display with no network). Calling `refresh()` fetches from the server,
/// reconciles the cache (server-authoritative for committed entries; pending
/// entries survive), and updates `comments`.
///
/// `post(body:)` inserts an optimistic local entry (pendingWrite = true),
/// then calls `createComment` on the API. On success the entry is promoted
/// (pendingWrite cleared, server ID recorded). On failure the entry stays
/// as-is with pendingWrite = true for retry.
///
/// `retryPending()` re-posts every pendingWrite comment — wired from the
/// sync scheduler's FizzySyncProvider.triggerSync() hook.
@Observable
@MainActor
final class CardCommentsViewModel {

    // MARK: - Public state

    /// Comments sorted by createdAt. Pending entries are mixed in by
    /// insertion time — they naturally sort after the last server comment.
    private(set) var comments: [CachedComment] = []
    private(set) var isLoading = false
    var errorMessage: String?

    // MARK: - Private

    private let cardFizzyNumber: Int64
    private let client: FizzyClient
    private let repository: CommentRepository
    private let creatorName: String

    // MARK: - Init

    /// - Parameters:
    ///   - cardFizzyNumber: The remote card number (Card.fizzyNumber).
    ///   - client: Live `FizzyClient` for network calls.
    ///   - context: The managed object context (typically `viewContext`).
    ///   - creatorName: Display name stamped on optimistic entries.
    ///     Defaults to "Me" for MVP (no identity endpoint consumption).
    init(
        cardFizzyNumber: Int64,
        client: FizzyClient,
        context: NSManagedObjectContext,
        creatorName: String = "Me"
    ) {
        self.cardFizzyNumber = cardFizzyNumber
        self.client = client
        self.repository = CommentRepository(context: context)
        self.creatorName = creatorName
        // Cache-first: load instantly from Core Data.
        self.comments = repository.fetchComments(for: cardFizzyNumber)
    }

    // MARK: - Load

    /// Fetches comments from the server, reconciles the cache, and updates
    /// `comments`. Non-fatal errors surface via `errorMessage`.
    func refresh() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let remote = try await client.comments(cardNumber: Int(cardFizzyNumber))
            repository.upsert(from: remote, cardFizzyNumber: cardFizzyNumber)
            comments = repository.fetchComments(for: cardFizzyNumber)
        } catch {
            errorMessage = "Couldn't load comments."
        }
    }

    // MARK: - Post

    /// Optimistically inserts a comment, then writes it through to the API.
    ///
    /// On success: entry is promoted (pendingWrite cleared, server ID set).
    /// On failure: entry stays pending for `retryPending()`.
    func post(body: String) async {
        errorMessage = nil
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let optimistic = repository.insertOptimistic(
            body: trimmed,
            cardFizzyNumber: cardFizzyNumber,
            creatorName: creatorName
        )
        comments = repository.fetchComments(for: cardFizzyNumber)

        do {
            let created = try await client.createComment(
                cardNumber: Int(cardFizzyNumber),
                body: trimmed
            )
            repository.markSent(optimistic, serverID: created.id)
            comments = repository.fetchComments(for: cardFizzyNumber)
        } catch {
            // Leave pendingWrite = true for retry; don't surface an error
            // (the dimmed indicator in the UI is the signal).
        }
    }

    // MARK: - Retry

    /// Re-posts every pendingWrite comment. Called from the sync scheduler
    /// hook in FizzySyncProvider (see comment below). Thread-safe: runs on
    /// @MainActor together with the rest of this VM.
    func retryPending() async {
        let pending = repository.pendingComments(for: cardFizzyNumber)
        for comment in pending {
            guard comment.managedObjectContext != nil, !comment.isDeleted else { continue }
            let body = comment.body ?? ""
            guard !body.isEmpty else { continue }
            do {
                let created = try await client.createComment(
                    cardNumber: Int(cardFizzyNumber),
                    body: body,
                    createdAt: comment.createdAt
                )
                repository.markSent(comment, serverID: created.id)
            } catch {
                // Leave pending; will be retried next tick.
            }
        }
        comments = repository.fetchComments(for: cardFizzyNumber)
    }
}
