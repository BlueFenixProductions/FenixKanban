import SwiftUI

struct CardView: View {
    @ObservedObject var card: Card
    var columnColor: Color? = nil

    private var backgroundFill: Color {
        if let columnColor {
            // Blend the column color with the dark card background for a subtle tint
            return columnColor.opacity(0.18)
        }
        return Color(.tertiarySystemBackground)
    }

    private var borderColor: Color {
        columnColor?.opacity(0.55) ?? Color.clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(card.title ?? "Untitled")
                    .font(.subheadline)
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
        .background(
            ZStack {
                Color(.tertiarySystemBackground)
                backgroundFill
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, lineWidth: columnColor == nil ? 0 : 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
