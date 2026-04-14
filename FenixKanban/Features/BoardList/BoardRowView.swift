import SwiftUI

struct BoardRowView: View {
    @ObservedObject var board: Board

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: board.colorHex ?? "#808080"))
                .frame(width: 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(board.name ?? "Untitled")
                    .font(.headline)
                    .lineLimit(1)

                Text("\(board.columnCount) columns \u{00B7} \(board.totalCardCount) cards")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
