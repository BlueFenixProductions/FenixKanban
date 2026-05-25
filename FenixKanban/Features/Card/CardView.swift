import SwiftUI

struct CardView: View {
    @ObservedObject var card: Card
    var columnColor: Color? = nil

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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(card.title ?? "Untitled")
                    .font(.crossPlatformSubheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .strikethrough(card.isCompleted)
                    .foregroundStyle(card.isCompleted ? .secondary : .primary)

                Spacer()

                if let label = card.label,
                   let name = label.name,
                   let hex = label.colorHex {
                    LabelBadge(name: name, colorHex: hex)
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
        // Make the entire rounded-card area the drag target. Without an
        // explicit shape, .draggable only picks up touches on rendered
        // pixels (text, badge) and ignores the empty padding/glass area.
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
