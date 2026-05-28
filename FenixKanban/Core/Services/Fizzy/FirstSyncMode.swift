import Foundation

/// One-shot direction the user picks when establishing a Fizzy pairing.
///
/// Default is `.pushLocalToFizzy` — fizzy.bluefenix.net was empty when this
/// integration was built, and the common case is "I've been working in
/// FenixKanban and want my cards mirrored to Fizzy."
///
/// None of the three modes ever DELETEs remote cards — the closest is
/// `.replaceLocalWithFizzy`, which only deletes *local* state.
enum FirstSyncMode: String, CaseIterable, Identifiable {
    case pushLocalToFizzy
    case replaceLocalWithFizzy
    case mergeIfNoConflicts

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pushLocalToFizzy:      "Push local to Fizzy"
        case .replaceLocalWithFizzy: "Replace local with Fizzy"
        case .mergeIfNoConflicts:    "Merge if no conflicts"
        }
    }
}
