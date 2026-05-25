import Testing
import SwiftUI
@testable import FenixKanban

@Suite("Cross-Platform Color Extensions")
struct ColorCrossPlatformTests {
    // The cross-platform Color extensions resolve to a platform-native color
    // on iOS (UIColor) and macOS (NSColor). The contract is just that each
    // accessor returns *some* Color without crashing on the active platform.
    // Verifying inequality vs .clear gives a cheap sanity check that the
    // platform branch was actually hit and produced a real system color.

    @Test func systemBackgroundResolves() {
        #expect(Color.crossPlatformSystemBackground != Color.clear)
    }

    @Test func secondarySystemBackgroundResolves() {
        #expect(Color.crossPlatformSecondarySystemBackground != Color.clear)
    }

    @Test func tertiarySystemBackgroundResolves() {
        #expect(Color.crossPlatformTertiarySystemBackground != Color.clear)
    }

    @Test func quaternarySystemFillResolves() {
        #expect(Color.crossPlatformQuaternarySystemFill != Color.clear)
    }

    @Test func goldenTicketResolves() {
        #expect(Color.goldenTicket != Color.clear)
    }

    @Test func goldenTicketIconResolves() {
        #expect(Color.goldenTicketIcon != Color.clear)
    }
}
