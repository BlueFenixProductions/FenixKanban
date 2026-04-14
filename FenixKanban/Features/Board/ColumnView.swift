import SwiftUI

struct ColumnView: View {
    let column: Column
    let cards: [Card]
    let onAddCard: () -> Void
    let onDeleteCard: (Card) -> Void
    let onSelectCard: (Card) -> Void
    let onDropCard: (UUID, Int) -> Void
    let onEditColumn: () -> Void
    let onDeleteColumn: () -> Void
    let onMoveCardUp: (Card) -> Void
    let onMoveCardDown: (Card) -> Void

    private var columnColor: Color? {
        guard let hex = column.colorHex else { return nil }
        return Color(hex: hex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column header
            HStack(spacing: 8) {
                if let color = columnColor {
                    Circle()
                        .fill(color)
                        .frame(width: 10, height: 10)
                }

                Text(column.name ?? "Untitled")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(columnColor ?? .secondary)

                Text("\(cards.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.quaternarySystemFill))
                    .clipShape(Capsule())

                Spacer()

                Menu {
                    Button {
                        onEditColumn()
                    } label: {
                        SwiftUI.Label("Edit Column", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        onDeleteColumn()
                    } label: {
                        SwiftUI.Label("Delete Column", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Cards list
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(cards.enumerated()), id: \.element.objectID) { index, card in
                        CardView(card: card, columnColor: columnColor)
                            .draggable(card.id?.uuidString ?? "") {
                                CardView(card: card, columnColor: columnColor)
                                    .frame(width: 250)
                                    .opacity(0.8)
                            }
                            .onTapGesture {
                                onSelectCard(card)
                            }
                            .contextMenu {
                                Button {
                                    onMoveCardUp(card)
                                } label: {
                                    SwiftUI.Label("Move Up", systemImage: "arrow.up")
                                }
                                .disabled(index == 0)

                                Button {
                                    onMoveCardDown(card)
                                } label: {
                                    SwiftUI.Label("Move Down", systemImage: "arrow.down")
                                }
                                .disabled(index == cards.count - 1)

                                Divider()

                                Button(role: .destructive) {
                                    onDeleteCard(card)
                                } label: {
                                    SwiftUI.Label("Delete", systemImage: "trash")
                                }
                            }
                    }

                    // Placeholder card acting as the "Add Card" button
                    Button(action: onAddCard) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                                .font(.subheadline)
                            Text("Add Card")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                        }
                        .foregroundStyle(columnColor ?? .secondary)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color(.quaternarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
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
