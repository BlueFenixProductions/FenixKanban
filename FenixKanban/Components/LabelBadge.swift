import SwiftUI

struct LabelBadge: View {
    let name: String
    let colorHex: String

    var body: some View {
        Text(name)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(hex: colorHex).opacity(0.25))
            .foregroundStyle(Color(hex: colorHex))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

#Preview {
    HStack {
        LabelBadge(name: "Urgent", colorHex: "#E94560")
        LabelBadge(name: "Dev", colorHex: "#0F3460")
        LabelBadge(name: "Design", colorHex: "#16C79A")
    }
    .padding()
    .preferredColorScheme(.dark)
}
