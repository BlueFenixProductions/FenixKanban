import Foundation
import CoreData

@objc(CardTombstone)
public class CardTombstone: NSManagedObject {

    /// Records a pending remote deletion for a fizzy-paired card so the next
    /// sync can issue `DELETE /cards/:number`. No-op (returns nil) for cards
    /// that were never paired — Fizzy addresses card routes by `number`, so a
    /// card without one has nothing to delete remotely.
    @discardableResult
    static func record(number: Int64, in context: NSManagedObjectContext) -> CardTombstone? {
        guard number != 0 else { return nil }
        let tombstone = CardTombstone(context: context)
        tombstone.fizzyNumber = number
        tombstone.deletedAt = Date()
        return tombstone
    }
}
