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
                    .font(.crossPlatformHeadline)
                    .lineLimit(1)

                Text("\(board.columnCount) columns \u{00B7} \(board.totalCardCount) cards")
                    .font(.crossPlatformCaption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.crossPlatformCaption)
                .foregroundStyle(.tertiary)
        }
        #if os(macOS)
        .padding(.vertical, 12)
        #else
        .padding(.vertical, 8)
        #endif
        .contentShape(Rectangle())
    }
}
