import CoreData

extension Card {
    /// Fizzy card number from the device-local pairing store (the sole authority
    /// after #22 removed the CloudKit hint attributes). Returns 0 when the card
    /// is unpaired — preserving the `> 0` paired gate at call sites.
    func resolvedFizzyNumber(_ store: FizzyCardPairingStore) -> Int64 {
        id.flatMap { store.pairing(for: $0)?.fizzyNumber } ?? 0
    }

    /// Fizzy card id from the device-local pairing store (#22). Nil when unpaired.
    func resolvedFizzyID(_ store: FizzyCardPairingStore) -> String? {
        id.flatMap { store.pairing(for: $0)?.fizzyID }
    }
}
