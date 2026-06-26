import Foundation
import CoreData

@objc(ColumnTombstone)
public class ColumnTombstone: NSManagedObject {

    /// Records a pending remote deletion for a fizzy-paired column so the
    /// next sync can issue `DELETE /boards/:id/columns/:column_id`. No-op
    /// (returns nil) for columns that were never paired. `boardID` stores the
    /// *local* board UUID — the engine maps it to the fizzy board ID through
    /// `FizzyBoardPairingStore` at sync time.
    @discardableResult
    static func record(for column: Column, in context: NSManagedObjectContext) -> ColumnTombstone? {
        guard let fizzyColumnID = column.fizzyColumnID else { return nil }
        let tombstone = ColumnTombstone(context: context)
        tombstone.fizzyColumnID = fizzyColumnID
        tombstone.boardID = column.board?.id?.uuidString
        tombstone.deletedAt = Date()
        return tombstone
    }
}
