import SwiftUI

struct CardView: View {
    @ObservedObject var card: Card
    var columnColor: Color? = nil

    private var glassTint: Color {
        if card.isGolden {
            return .goldenTicket
        }
        // Subtle column-color tint on the Liquid Glass material. Falls back
        // to clear so non-tinted cards get the plain system glass appearance.
        return columnColor?.opacity(0.18) ?? .clear
    }

    private var borderColor: Color {
        columnColor?.opacity(0.55) ?? Color.clear
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
                .strokeBorder(borderColor, lineWidth: columnColor == nil ? 0 : 1.5)
        )
        .overlay(alignment: .topLeading) {
            if card.isGolden {
                Image(systemName: "ticket.fill")
                    .imageScale(.medium)
                    .foregroundStyle(Color.goldenTicketIcon)
                    .padding(8)
                    .accessibilityLabel("Golden ticket priority")
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }
}
