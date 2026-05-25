import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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

    // MARK: - Golden Ticket Priority

    /// Warm gold used as the .glassEffect tint for cards marked golden.
    static var goldenTicket: Color {
        if Self.shouldUseIncreasedContrast {
            // Brighter tint widens the luminance gap to the (darker)
            // goldenTicketIcon foreground when Increase Contrast is on.
            return Color(red: 0.99, green: 0.82, blue: 0.20)
        }
        return Color(red: 0.95, green: 0.78, blue: 0.20)
    }

    /// Foreground used for the ticket icon overlay and inline gold accents.
    /// Darker than `.goldenTicket` so it reads on top of the tinted glass.
    static var goldenTicketIcon: Color {
        if Self.shouldUseIncreasedContrast {
            return Color(red: 0.35, green: 0.22, blue: 0.0)
        }
        return Color(red: 0.55, green: 0.40, blue: 0.05)
    }

    private static var shouldUseIncreasedContrast: Bool {
        #if os(iOS)
        return UIAccessibility.isDarkerSystemColorsEnabled
        #elseif os(macOS)
        return NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        #else
        return false
        #endif
    }
}
