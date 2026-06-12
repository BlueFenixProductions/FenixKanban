import SwiftUI

struct CardView: View {
    @ObservedObject var card: Card
    var columnColor: Color? = nil
    /// Set to `true` by the parent `ColumnView` / `BoardView` when the board
    /// has a Fizzy pairing. Drives the cloud badge without requiring CardView
    /// to read UserDefaults directly.
    var boardIsPaired: Bool = false

    private var glassTint: Color {
        // Golden priority takes precedence over the column-color tint.
        // Brighter than the column-color tint so golden cards visibly
        // pop on the board, but still translucent enough that .primary
        // text stays readable through the Liquid Glass material in dark
        // mode (solid gold suppressed it).
        if card.isGolden {
            return Color.goldenTicket.opacity(0.32)
        }
        // Subtle column-color tint on the Liquid Glass material. Falls back
        // to clear so non-tinted cards get the plain system glass appearance.
        return columnColor?.opacity(0.18) ?? .clear
    }

    private var borderColor: Color {
        // Golden cards get a gold rim regardless of column. Otherwise the
        // border tracks the column color.
        if card.isGolden {
            return Color.goldenTicket.opacity(0.55)
        }
        return columnColor?.opacity(0.55) ?? Color.clear
    }

    private var borderLineWidth: CGFloat {
        // Show the highlighted stroke whenever there's something to outline
        // (column color OR golden state).
        (card.isGolden || columnColor != nil) ? 1.5 : 0
    }

    /// Resolved Fizzy sync badge state — uses device-local pairing store.
    private var syncBadgeState: CardSyncBadgeState {
        guard boardIsPaired, let cardID = card.id else { return .none }
        let hasPairing = FizzyCardPairingStore.shared.pairing(for: cardID) != nil
        return CardSyncBadgeState.resolve(hasPairing: hasPairing, boardIsPaired: boardIsPaired)
    }

    /// True when the card is not actively in-progress (closed or deferred).
    private var isInactive: Bool {
        card.lifecycleStatus != .active
    }

    var body: some View {
        // Computed once per body evaluation — sortedLabels sorts the Core
        // Data set on every access, and the chips row reads it up to 4x.
        let sortedLabels = card.sortedLabels
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(card.title ?? "Untitled")
                    .font(.crossPlatformSubheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .strikethrough(card.isCompleted)
                    .foregroundStyle(card.isCompleted ? .secondary : .primary)

                Spacer()

                // Watch/pin indicators ride inline with the title (NOT a
                // top-trailing overlay — that corner collides with two-line
                // titles, and the golden ticket already owns top-leading).
                if card.isPinned {
                    Image(systemName: "pin.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }
                if card.isWatched {
                    Image(systemName: "eye.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Watching")
                }
            }

            if !sortedLabels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(sortedLabels.prefix(3)), id: \.objectID) { label in
                        if let name = label.name, let hex = label.colorHex {
                            LabelBadge(name: name, colorHex: hex)
                        }
                    }
                    if sortedLabels.count > 3 {
                        Text("+\(sortedLabels.count - 3)")
                            .font(.crossPlatformCaption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let dueDate = card.dueDate {
                DueDateBadge(date: dueDate)
            }
        }
        .padding(12)
        .glassEffect(.regular.tint(glassTint), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, lineWidth: borderLineWidth)
        )
        .overlay(alignment: .topLeading) {
            if card.isGolden {
                Image(systemName: "ticket.fill")
                    .imageScale(.medium)
                    .foregroundStyle(Color.goldenTicketIcon)
                    .padding(8)
                    .accessibilityLabel("Golden ticket priority")
            }
        }
        .overlay(alignment: .topTrailing) {
            // Lifecycle status badge — top-trailing; only visible for
            // closed/notNow cards (active cards show nothing).
            switch card.lifecycleStatus {
            case .closed:
                Image(systemName: "checkmark.circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .accessibilityLabel("Closed")
                    .accessibilityHint("This card has been resolved.")
            case .notNow:
                Image(systemName: "clock.badge.xmark")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .accessibilityLabel("Not Now")
                    .accessibilityHint("This card is deferred.")
            case .active:
                EmptyView()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Cloud sync badge — bottom-trailing so it doesn't collide with
            // the golden ticket overlay (top-leading). Only shown when the
            // board is Fizzy-paired.
            switch syncBadgeState {
            case .synced:
                Image(systemName: "checkmark.icloud.fill")
                    .imageScale(.small)
                    .foregroundStyle(.tint.opacity(0.7))
                    .padding(6)
                    .accessibilityLabel("Synced with Fizzy")
                    .accessibilityHint("This card has been synced to Fizzy.")
            case .pending:
                Image(systemName: "icloud.slash")
                    .imageScale(.small)
                    .foregroundStyle(.secondary.opacity(0.7))
                    .padding(6)
                    .accessibilityLabel("Not yet synced")
                    .accessibilityHint("This card has not been synced to Fizzy yet.")
            case .none:
                EmptyView()
            }
        }
        // Make the entire rounded-card area the drag target. Without an
        // explicit shape, .draggable only picks up touches on rendered
        // pixels (text, badge) and ignores the empty padding/glass area.
        // Dim closed/notNow cards so they're visually recessive when shown
        // via the "Show Closed" toggle. Active cards are full opacity.
        .opacity(isInactive ? 0.5 : 1.0)
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        // .contain makes CardView a single queryable container in the
        // a11y tree (children still expose themselves) so the
        // identifier below survives — without it SwiftUI decomposes
        // the row into title/badge/etc. and XCUITest can't find the
        // wrapper to .press(forDuration:thenDragTo:).
        .accessibilityElement(children: .contain)
        // Title-first identifier for XCUITest drag/drop lookup —
        // tests seed cards with known titles, so `card-Card A` is
        // the queryable handle. UUID is the fallback for the rare
        // titleless edge (and remains stable per-card if needed).
        .accessibilityIdentifier("card-\(card.title ?? card.id?.uuidString ?? "untitled")")
    }
}
