import SwiftUI

/// A small gold-tinted Liquid Glass capsule shown in every column
/// header. Accepts a drag of a card UUID string and forwards it to the
/// closure, which toggles `isGolden` on the matching card.
///
/// Always visible (not show-only-during-drag) for discoverability and
/// to avoid the SwiftUI "is-a-drag-in-flight" plumbing.
struct GoldZoneChip: View {
    let onDropCardID: (String) -> Void
    @State private var isTargeted = false

    var body: some View {
        Image(systemName: "ticket.fill")
            .imageScale(.small)
            .foregroundStyle(Color.goldenTicketIcon)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(
                .regular.tint(isTargeted ? Color.goldenTicket : Color.goldenTicket.opacity(0.5)),
                in: .capsule
            )
            .dropDestination(for: String.self) { items, _ in
                guard let uuidString = items.first else { return false }
                onDropCardID(uuidString)
                return true
            } isTargeted: { isTargeted = $0 }
            .accessibilityLabel("Drop a card here to mark it golden")
            .accessibilityAddTraits(.isButton)
    }
}
