import CoreData
import Foundation

protocol CommentRepositoryProtocol {
    func fetchComments(for cardFizzyNumber: Int64) -> [CachedComment]
    func upsert(from remoteComments: [FizzyComment], cardFizzyNumber: Int64)
    func insertOptimistic(body: String, cardFizzyNumber: Int64, creatorName: String) -> CachedComment
    func markSent(_ comment: CachedComment, serverID: String)
    func pendingComments(for cardFizzyNumber: Int64) -> [CachedComment]
}

/// Local cache for card comments. Follows the same CoreData pattern as
/// `CardRepository`: plain init, synchronous mutations, `save()` at end.
///
/// Upsert semantics:
/// - Server-authoritative: remote entries are inserted/updated by fizzyCommentID.
/// - Pending entries (pendingWrite == true) are preserved through a refresh —
///   they are never clobbered by a server response that doesn't know about them
///   yet (they haven't been sent yet).
final class CommentRepository: CommentRepositoryProtocol {
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    /// All cached comments for `cardFizzyNumber`, sorted by createdAt ascending.
    func fetchComments(for cardFizzyNumber: Int64) -> [CachedComment] {
        let request: NSFetchRequest<CachedComment> = CachedComment.fetchRequest()
        request.predicate = NSPredicate(format: "cardFizzyNumber == %lld", cardFizzyNumber)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CachedComment.createdAt, ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    /// Reconciles the cache with a fresh server response.
    ///
    /// - Non-pending entries whose `fizzyCommentID` matches a remote comment
    ///   are updated (body, creatorName, createdAt).
    /// - New remote comments that don't exist locally are inserted with
    ///   `pendingWrite = false`.
    /// - Pending entries are left untouched.
    /// - Non-pending local entries whose ID is absent from the server response
    ///   are deleted (server is authoritative for committed entries).
    func upsert(from remoteComments: [FizzyComment], cardFizzyNumber: Int64) {
        let existing = fetchComments(for: cardFizzyNumber)
        let pending = existing.filter { $0.pendingWrite }
        let committed = existing.filter { !$0.pendingWrite }

        let remoteByID = Dictionary(grouping: remoteComments, by: \.id)
            .compactMapValues(\.first)

        // Update or delete existing committed entries.
        for cached in committed {
            guard let remoteID = cached.fizzyCommentID,
                  let remote = remoteByID[remoteID] else {
                // Server no longer has this comment — delete locally.
                context.delete(cached)
                continue
            }
            cached.body = remote.body.plainText
            cached.creatorName = remote.creator.name
            cached.createdAt = remote.createdAt
            cached.pendingWrite = false
        }

        // Insert new remote comments not already cached.
        let cachedIDs = Set(committed.compactMap(\.fizzyCommentID))
        for remote in remoteComments where !cachedIDs.contains(remote.id) {
            let newCached = CachedComment(context: context)
            newCached.fizzyCommentID = remote.id
            newCached.cardFizzyNumber = cardFizzyNumber
            newCached.body = remote.body.plainText
            newCached.creatorName = remote.creator.name
            newCached.createdAt = remote.createdAt
            newCached.pendingWrite = false
        }

        // Pending entries survive untouched — don't touch them.
        _ = pending

        save()
    }

    /// Inserts an optimistic local comment (pendingWrite = true).
    /// createdAt is set to now so it sorts at the bottom.
    @discardableResult
    func insertOptimistic(body: String, cardFizzyNumber: Int64, creatorName: String) -> CachedComment {
        let cached = CachedComment(context: context)
        cached.body = body
        cached.cardFizzyNumber = cardFizzyNumber
        cached.creatorName = creatorName
        cached.createdAt = Date()
        cached.pendingWrite = true
        cached.fizzyCommentID = nil
        save()
        return cached
    }

    /// Marks a previously-optimistic comment as sent: clears pendingWrite and
    /// records the server-assigned ID.
    func markSent(_ comment: CachedComment, serverID: String) {
        comment.fizzyCommentID = serverID
        comment.pendingWrite = false
        save()
    }

    /// All pending (unsent) comments for a card, in createdAt order.
    func pendingComments(for cardFizzyNumber: Int64) -> [CachedComment] {
        let request: NSFetchRequest<CachedComment> = CachedComment.fetchRequest()
        request.predicate = NSPredicate(
            format: "cardFizzyNumber == %lld AND pendingWrite == YES",
            cardFizzyNumber
        )
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CachedComment.createdAt, ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    private func save() {
        guard context.hasChanges else { return }
        try? context.save()
    }
}
