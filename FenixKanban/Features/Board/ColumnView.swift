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
    let onToggleGolden: (Card) -> Void
    let onToggleGoldenByID: (UUID) -> Void

    @State private var isDropTargeted = false

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
                    .font(.crossPlatformSubheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(columnColor ?? .secondary)

                Text("\(cards.count)")
                    .font(.crossPlatformCaption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.crossPlatformQuaternarySystemFill)
                    .clipShape(Capsule())

                Spacer()

                GoldZoneChip(onDropCardID: { uuidString in
                    guard let uuid = UUID(uuidString: uuidString) else { return }
                    onToggleGoldenByID(uuid)
                })

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
                        .font(.crossPlatformSubheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Cards list. The GlassEffectContainer batches adjacent glass
            // shapes (each CardView + the "Add Card" pill) so they render
            // efficiently and shape-morph between each other per Apple's
            // Liquid Glass guidance.
            ScrollView {
                GlassEffectContainer(spacing: 6) {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(cards.enumerated()), id: \.element.objectID) { index, card in
                            CardView(card: card, columnColor: columnColor)
                                .draggable(card.id?.uuidString ?? "") {
                                    CardView(card: card, columnColor: columnColor)
                                        .frame(width: 250)
                                        .opacity(0.85)
                                }
                                // simultaneousGesture (not .onTapGesture)
                                // so a quick tap selects the card without
                                // exclusively claiming the touch sequence
                                // — .draggable needs that sequence to lift
                                // the card on click-drag (macOS) or
                                // long-press-drag (iOS) without waiting
                                // for tap to time out.
                                .simultaneousGesture(
                                    TapGesture().onEnded { onSelectCard(card) }
                                )
                                .contextMenu {
                                    Button {
                                        onToggleGolden(card)
                                    } label: {
                                        // "ticket.slash" is NOT an SF Symbol (rendered blank +
                                        // console warning on device). Mirror the card-detail
                                        // toolbar's current-state depiction: golden → filled,
                                        // not golden → outline; the label text carries the
                                        // action semantics.
                                        SwiftUI.Label(
                                            card.isGolden ? "Remove Golden Ticket" : "Mark as Golden",
                                            systemImage: card.isGolden ? "ticket.fill" : "ticket"
                                        )
                                    }
                                    // Visible menu text uses title case (UI convention);
                                    // explicit a11y label matches the toolbar + swipe surfaces
                                    // so VoiceOver hears the same phrasing everywhere.
                                    .accessibilityLabel(
                                        card.isGolden
                                            ? "Remove golden ticket"
                                            : "Mark as golden ticket"
                                    )

                                    Divider()

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
                                    .font(.crossPlatformSubheadline)
                                Text("Add Card")
                                    .font(.crossPlatformSubheadline)
                                    .fontWeight(.medium)
                                Spacer()
                            }
                            .foregroundStyle(columnColor ?? .secondary)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity)
                            .glassEffect(.regular, in: .rect(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
            .dropDestination(for: String.self) { items, location in
                guard let uuidString = items.first,
                      let uuid = UUID(uuidString: uuidString) else { return false }
                let dropIndex = calculateDropIndex(at: location, in: cards)
                onDropCard(uuid, dropIndex)
                return true
            } isTargeted: { isDropTargeted = $0 }
        }
        .background(Color.crossPlatformSecondarySystemBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    (columnColor ?? .accentColor).opacity(isDropTargeted ? 0.9 : 0),
                    lineWidth: 2
                )
                .animation(.easeOut(duration: 0.15), value: isDropTargeted)
                .allowsHitTesting(false)
        }
        // .contain so ColumnView is a single queryable a11y container —
        // children (cards, header buttons, gold chip) still expose
        // themselves individually but XCUITest can locate the column
        // wrapper by identifier for `.press(forDuration:thenDragTo:)`.
        .accessibilityElement(children: .contain)
        // Stable identifier for XCUITest drag/drop element lookup.
        // Uses the column name (test seeds known names) so the test
        // doesn't depend on Core Data object IDs.
        .accessibilityIdentifier("column-\(column.name ?? "untitled")")
    }

    private func calculateDropIndex(at location: CGPoint, in cards: [Card]) -> Int {
        // Approximate: drop at end by default
        return cards.count
    }
}
