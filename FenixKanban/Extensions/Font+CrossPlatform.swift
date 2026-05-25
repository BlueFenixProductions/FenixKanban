import SwiftUI

// MARK: - Cross-Platform Font Sizes
//
// macOS's built-in semantic font sizes are smaller than iOS's, and several
// styles collapse to nearly the same point size (.subheadline 11pt, .caption
// 10pt, .caption2 10pt). On a kanban-style layout that uses caption-sized
// metadata heavily, the hierarchy disappears and text becomes hard to read.
//
// These helpers preserve SwiftUI's semantic font styles on iOS (so Dynamic
// Type and accessibility scaling continue to work) and substitute explicit
// iOS-equivalent point sizes on macOS so the type hierarchy stays legible.
//
// Mirrors the pattern of `Color.crossPlatform*` in Color+CrossPlatform.swift.

extension Font {
    static var crossPlatformLargeTitle: Font {
        #if os(macOS)
        return .system(size: 32, weight: .bold)
        #else
        return .largeTitle
        #endif
    }

    static var crossPlatformTitle: Font {
        #if os(macOS)
        return .system(size: 26, weight: .regular)
        #else
        return .title
        #endif
    }

    static var crossPlatformTitle2: Font {
        #if os(macOS)
        return .system(size: 20, weight: .regular)
        #else
        return .title2
        #endif
    }

    static var crossPlatformTitle3: Font {
        #if os(macOS)
        return .system(size: 18, weight: .regular)
        #else
        return .title3
        #endif
    }

    static var crossPlatformHeadline: Font {
        #if os(macOS)
        return .system(size: 16, weight: .semibold)
        #else
        return .headline
        #endif
    }

    static var crossPlatformBody: Font {
        #if os(macOS)
        return .system(size: 15, weight: .regular)
        #else
        return .body
        #endif
    }

    static var crossPlatformCallout: Font {
        #if os(macOS)
        return .system(size: 14, weight: .regular)
        #else
        return .callout
        #endif
    }

    static var crossPlatformSubheadline: Font {
        #if os(macOS)
        return .system(size: 14, weight: .regular)
        #else
        return .subheadline
        #endif
    }

    static var crossPlatformFootnote: Font {
        #if os(macOS)
        return .system(size: 12, weight: .regular)
        #else
        return .footnote
        #endif
    }

    static var crossPlatformCaption: Font {
        #if os(macOS)
        return .system(size: 12, weight: .regular)
        #else
        return .caption
        #endif
    }

    static var crossPlatformCaption2: Font {
        #if os(macOS)
        return .system(size: 11, weight: .regular)
        #else
        return .caption2
        #endif
    }
}
