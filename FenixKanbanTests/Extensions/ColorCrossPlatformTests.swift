import XCTest
import SwiftUI
@testable import FenixKanban

final class ColorCrossPlatformTests: XCTestCase {

    // The cross-platform Color extensions resolve to a platform-native color
    // on iOS (UIColor) and macOS (NSColor). The contract is just that each
    // accessor returns *some* Color without crashing on the active platform.
    // Verifying inequality vs .clear gives us a cheap sanity check that the
    // platform branch was actually hit and produced a real system color.

    func testSystemBackgroundResolves() {
        XCTAssertNotEqual(Color.crossPlatformSystemBackground, Color.clear)
    }

    func testSecondarySystemBackgroundResolves() {
        XCTAssertNotEqual(Color.crossPlatformSecondarySystemBackground, Color.clear)
    }

    func testTertiarySystemBackgroundResolves() {
        XCTAssertNotEqual(Color.crossPlatformTertiarySystemBackground, Color.clear)
    }

    func testQuaternarySystemFillResolves() {
        XCTAssertNotEqual(Color.crossPlatformQuaternarySystemFill, Color.clear)
    }
}
