import SwiftUI

/// Colored initials circle for a person. Initials-only by Captain's ruling
/// (#19 wave 2): Fizzy avatar URLs require the bearer token, which
/// AsyncImage can't send. Color is FNV-derived from the name (same
/// determinism as auto-created label colors).
struct InitialsAvatar: View {
    let name: String
    var size: CGFloat = 28

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    /// FNV-derived colors span the full 24-bit RGB space, so light fills are
    /// inevitable (and deterministic per name). Pick black/white initials by
    /// relative luminance so the text stays legible on any background.
    private static func textColor(forHex hex: String) -> Color {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        let r = Double((rgb & 0xFF0000) >> 16)
        let g = Double((rgb & 0x00FF00) >> 8)
        let b = Double(rgb & 0x0000FF)
        let luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        return luminance > 0.6 ? .black : .white
    }

    var body: some View {
        let hex = FizzySyncMapping.labelColorHex(forName: name)
        Circle()
            .fill(Color(hex: hex))
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(Self.textColor(forHex: hex))
            }
            .accessibilityLabel(name)
    }
}
