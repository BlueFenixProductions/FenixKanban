import CoreData

extension Card {
    /// Fizzy card number, resolved store-first with CoreData-hint fallback (#22).
    /// The store wins when a pairing exists; the `fizzyNumber` attribute answers
    /// only during the pre-seed window on a cold device. Returns 0 when the card
    /// is unpaired in both — preserving the `> 0` paired gate at call sites.
    func resolvedFizzyNumber(_ store: FizzyCardPairingStore) -> Int64 {
        id.flatMap { store.pairing(for: $0)?.fizzyNumber } ?? fizzyNumber
    }

    /// Fizzy card id, resolved store-first with CoreData-hint fallback (#22).
    func resolvedFizzyID(_ store: FizzyCardPairingStore) -> String? {
        id.flatMap { store.pairing(for: $0)?.fizzyID } ?? fizzyID
    }
}
