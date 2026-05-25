import Testing
import SwiftUI
@testable import FenixKanban

@Suite("Cross-Platform Font Extensions")
struct FontCrossPlatformTests {
    // The cross-platform Font extensions resolve to the SwiftUI semantic
    // style on iOS and to an explicit `.system(size:)` font on macOS (to
    // counter macOS's smaller defaults and the .subheadline/.caption/.caption2
    // size collapse). The contract is just that each accessor resolves to
    // *some* Font without crashing on the active platform; the visual
    // sizing is verified by hand on each platform.
    //
    // Mirrors ColorCrossPlatformTests.swift.

    @Test func largeTitleResolves() {
        #expect(Font.crossPlatformLargeTitle != Font.body)
    }

    @Test func titleResolves() {
        #expect(Font.crossPlatformTitle != Font.body)
    }

    @Test func title2Resolves() {
        #expect(Font.crossPlatformTitle2 != Font.body)
    }

    @Test func title3Resolves() {
        #expect(Font.crossPlatformTitle3 != Font.body)
    }

    @Test func headlineResolves() {
        #expect(Font.crossPlatformHeadline != Font.body)
    }

    @Test func bodyResolves() {
        // crossPlatformBody is .body on iOS and .system(size: 15) on macOS;
        // either way it should differ from .caption.
        #expect(Font.crossPlatformBody != Font.caption)
    }

    @Test func calloutResolves() {
        #expect(Font.crossPlatformCallout != Font.body)
    }

    @Test func subheadlineResolves() {
        #expect(Font.crossPlatformSubheadline != Font.body)
    }

    @Test func footnoteResolves() {
        #expect(Font.crossPlatformFootnote != Font.body)
    }

    @Test func captionResolves() {
        #expect(Font.crossPlatformCaption != Font.body)
    }

    @Test func caption2Resolves() {
        #expect(Font.crossPlatformCaption2 != Font.body)
    }
}
