import SwiftUI

/// User-selectable appearance mode persisted via `@AppStorage("appearanceMode")`.
///
/// `.system` maps to `nil`, which lets SwiftUI defer to the OS-level
/// `ColorScheme`. `.light` / `.dark` force the corresponding scheme on
/// the entire view hierarchy below the root `WindowGroup`.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }
}
