import SwiftUI

// MARK: - Cross-Platform Color Extensions

extension Color {
    /// System background color that works across iOS and macOS
    static var crossPlatformSystemBackground: Color {
        #if os(iOS)
        return Color(uiColor: .systemBackground)
        #elseif os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1)
        #endif
    }
    
    /// Secondary system background color that works across iOS and macOS
    static var crossPlatformSecondarySystemBackground: Color {
        #if os(iOS)
        return Color(uiColor: .secondarySystemBackground)
        #elseif os(macOS)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color(.sRGB, red: 0.1, green: 0.1, blue: 0.1, opacity: 1)
        #endif
    }
    
    /// Tertiary system background color that works across iOS and macOS
    static var crossPlatformTertiarySystemBackground: Color {
        #if os(iOS)
        return Color(uiColor: .tertiarySystemBackground)
        #elseif os(macOS)
        return Color(nsColor: .textBackgroundColor)
        #else
        return Color(.sRGB, red: 0.2, green: 0.2, blue: 0.2, opacity: 1)
        #endif
    }
    
    /// Quaternary system fill color that works across iOS and macOS
    static var crossPlatformQuaternarySystemFill: Color {
        #if os(iOS)
        return Color(uiColor: .quaternarySystemFill)
        #elseif os(macOS)
        return Color(nsColor: .quaternaryLabelColor).opacity(0.2)
        #else
        return Color(.sRGB, red: 0.3, green: 0.3, blue: 0.3, opacity: 0.2)
        #endif
    }
}
