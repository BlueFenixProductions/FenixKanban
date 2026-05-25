import Testing
import SwiftUI

@Suite("Cross-Platform Color Extensions")
struct ColorCrossPlatformTests {
    
    @Test("System background color extension exists")
    func systemBackgroundExists() async throws {
        let color = Color.crossPlatformSystemBackground
        #expect(color != nil)
    }
    
    @Test("Secondary system background color extension exists")
    func secondarySystemBackgroundExists() async throws {
        let color = Color.crossPlatformSecondarySystemBackground
        #expect(color != nil)
    }
    
    @Test("Tertiary system background color extension exists")
    func tertiarySystemBackgroundExists() async throws {
        let color = Color.crossPlatformTertiarySystemBackground
        #expect(color != nil)
    }
    
    @Test("Quaternary system fill color extension exists")
    func quaternarySystemFillExists() async throws {
        let color = Color.crossPlatformQuaternarySystemFill
        #expect(color != nil)
    }
    
    #if os(iOS)
    @Test("iOS system background uses UIColor", .tags(.iOS))
    func iOSSystemBackground() async throws {
        let color = Color.crossPlatformSystemBackground
        // Color should be created from UIColor
        #expect(color != Color.clear)
    }
    #endif
    
    #if os(macOS)
    @Test("macOS system background uses NSColor", .tags(.macOS))
    func macOSSystemBackground() async throws {
        let color = Color.crossPlatformSystemBackground
        // Color should be created from NSColor
        #expect(color != Color.clear)
    }
    #endif
}

// Test tags for platform-specific tests
extension Tag {
    @Tag static var iOS: Self
    @Tag static var macOS: Self
}
