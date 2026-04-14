import SwiftUI

struct AdaptiveLayoutInfo {
    let isCompact: Bool
    let isLandscape: Bool

    var showMultiColumn: Bool {
        !isCompact || isLandscape
    }
}

struct AdaptiveLayoutKey: EnvironmentKey {
    static let defaultValue = AdaptiveLayoutInfo(isCompact: true, isLandscape: false)
}

extension EnvironmentValues {
    var adaptiveLayout: AdaptiveLayoutInfo {
        get { self[AdaptiveLayoutKey.self] }
        set { self[AdaptiveLayoutKey.self] = newValue }
    }
}

struct AdaptiveLayoutModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let isCompact = horizontalSizeClass == .compact
            let isLandscape = geometry.size.width > geometry.size.height
            content
                .environment(\.adaptiveLayout, AdaptiveLayoutInfo(
                    isCompact: isCompact,
                    isLandscape: isLandscape
                ))
        }
    }
}

extension View {
    func adaptiveLayout() -> some View {
        modifier(AdaptiveLayoutModifier())
    }
}
