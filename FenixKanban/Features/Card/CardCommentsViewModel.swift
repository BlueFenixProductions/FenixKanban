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

    /// Reactions cache: commentID → [FizzyReaction]. Populated lazily per
    /// comment row via `loadReactions(for:)`. Internal (not private) so tests
    /// can pre-seed entries via `@testable import`.
    var reactions: [String: [FizzyReaction]] = [:]

    // MARK: - Private

    private let cardFizzyNumber: Int64
    private let client: FizzyClient
    private let repository: CommentRepository
    private let creatorName: String

    /// The Fizzy user ID for the current session, used to identify which
    /// reactions belong to the current user. Optional — reactions still render
    /// read-only when nil (e.g. unauthenticated or identity not yet resolved).
    let currentFizzyUserID: String?

    // MARK: - Init

    /// - Parameters:
    ///   - cardFizzyNumber: The remote card number (Card.fizzyNumber).
    ///   - client: Live `FizzyClient` for network calls.
    ///   - context: The managed object context (typically `viewContext`).
    ///   - creatorName: Display name stamped on optimistic entries.
    ///     Defaults to "Me" for MVP (no identity endpoint consumption).
    ///   - currentFizzyUserID: Fizzy user ID for the authenticated session.
    ///     Used to highlight and toggle the current user's reactions.
    init(
        cardFizzyNumber: Int64,
        client: FizzyClient,
        context: NSManagedObjectContext,
        creatorName: String = "Me",
        currentFizzyUserID: String? = nil
    ) {
        self.cardFizzyNumber = cardFizzyNumber
        self.client = client
        self.repository = CommentRepository(context: context)
        self.creatorName = creatorName
        self.currentFizzyUserID = currentFizzyUserID
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

    // MARK: - Reactions

    /// Fetches reactions for a single comment and updates the cache.
    /// Called on each comment row's `.task` modifier — safe to call repeatedly
    /// (idempotent: just replaces the cached array for that comment).
    /// No-ops silently on network errors so the row still renders.
    func loadReactions(for commentID: String) async {
        guard !commentID.isEmpty else { return }
        do {
            let fetched = try await client.commentReactions(
                cardNumber: Int(cardFizzyNumber),
                commentID: commentID
            )
            reactions[commentID] = fetched
        } catch {
            // Non-fatal: reactions are an enhancement. Leave existing cache.
        }
    }

    /// Toggles the current user's reaction. If the user has already reacted
    /// with `emoji` on `commentID`, the reaction is deleted; otherwise it is
    /// added. Refreshes the reaction cache for that comment afterward.
    ///
    /// No-ops silently when `currentFizzyUserID` is nil — the UI should hide
    /// the add-reaction picker in that case.
    func toggleReaction(emoji: String, for commentID: String) async {
        guard !commentID.isEmpty else { return }
        let existing = reactions[commentID] ?? []
        if let mine = existing.first(where: {
            $0.content == emoji && $0.reacter.id == currentFizzyUserID
        }) {
            do {
                try await client.deleteCommentReaction(
                    cardNumber: Int(cardFizzyNumber),
                    commentID: commentID,
                    reactionID: mine.id
                )
            } catch {
                // Non-fatal: leave UI as-is; server may be transiently down.
            }
        } else {
            do {
                try await client.addCommentReaction(
                    cardNumber: Int(cardFizzyNumber),
                    commentID: commentID,
                    content: emoji
                )
            } catch {
                // Non-fatal.
            }
        }
        // Refresh so the cache reflects the updated state from the server.
        await loadReactions(for: commentID)
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
                    body: body
                )
                repository.markSent(comment, serverID: created.id)
            } catch {
                // Leave pending; will be retried next tick.
            }
        }
        comments = repository.fetchComments(for: cardFizzyNumber)
    }
}
