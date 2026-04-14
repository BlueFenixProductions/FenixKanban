import SwiftUI

struct ColumnView: View {
    let column: Column
    let cards: [Card]
    let onAddCard: () -> Void
    let onDeleteCard: (Card) -> Void
    let onSelectCard: (Card) -> Void
    let onDropCard: (UUID, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column header
            HStack {
                Text(column.name ?? "Untitled")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Text("\(cards.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.quaternarySystemFill))
                    .clipShape(Capsule())

                Spacer()

                Button(action: onAddCard) {
                    Image(systemName: "plus")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Cards list
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(cards, id: \.objectID) { card in
                        CardView(card: card)
                            .draggable(card.id?.uuidString ?? "") {
                                CardView(card: card)
                                    .frame(width: 250)
                                    .opacity(0.8)
                            }
                            .onTapGesture {
                                onSelectCard(card)
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    onDeleteCard(card)
                                } label: {
                                    SwiftUI.Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .dropDestination(for: String.self) { items, location in
                guard let uuidString = items.first,
                      let uuid = UUID(uuidString: uuidString) else { return false }
                let dropIndex = calculateDropIndex(at: location, in: cards)
                onDropCard(uuid, dropIndex)
                return true
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func calculateDropIndex(at location: CGPoint, in cards: [Card]) -> Int {
        // Approximate: drop at end by default
        return cards.count
    }
}
