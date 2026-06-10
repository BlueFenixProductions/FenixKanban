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

    var body: some View {
        Circle()
            .fill(Color(hex: FizzySyncMapping.labelColorHex(forName: name)))
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(name)
    }
}
