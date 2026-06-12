import Foundation
import CoreData

/// The lifecycle state of a card — distinct from Fizzy's publish-state field.
///
/// Fizzy's wire `status` field ("published" / "drafted") describes **publish state**:
/// whether the card is visible on the public board. That is a different concept
/// from lifecycle state, which reflects whether the card is actively in progress
/// (`.active`), has been resolved (`.closed`), or has been deferred (`.notNow`).
/// These map to the Fizzy closure and not_now endpoints, not to the publish-state
/// field. The CoreData attribute is therefore named `lifecycleStatusRaw` (not
/// `statusRaw`) to make this distinction explicit and to avoid confusion with
/// any future mapping of the Fizzy publish-state field.
public enum CardLifecycleStatus: String {
    case active
    case closed
    case notNow
}

extension Card {

    /// The lifecycle state of this card.
    ///
    /// Getting: parsed from `lifecycleStatusRaw`; unrecognised raw values map
    /// to `.active` (forward-compatible default).
    ///
    /// Setting: updates `lifecycleStatusRaw` and manages `closedAt`:
    /// - Transitioning **to** `.closed` stamps `closedAt` with the current time.
    /// - Transitioning **away from** `.closed` (to `.active` or `.notNow`) nils `closedAt`.
    public var lifecycleStatus: CardLifecycleStatus {
        get {
            guard let raw = lifecycleStatusRaw else { return .active }
            return CardLifecycleStatus(rawValue: raw) ?? .active
        }
        set {
            lifecycleStatusRaw = newValue.rawValue
            switch newValue {
            case .closed:
                closedAt = Date()
            case .active, .notNow:
                closedAt = nil
            }
        }
    }
}
