import Foundation
import CoreData

/// Minimal persisted shape for a card assignee. Assignees arrive embedded in
/// the column-cards pull payload and are remote-authoritative (like tags) —
/// stored as a JSON blob on Card (Captain's ruling on #19 wave 2: no
/// dedicated entity; id + name is all the initials-avatar row needs).
struct CardAssignee: Codable, Equatable, Identifiable {
    let id: String
    let name: String
}

extension Card {
    /// JSON-blob accessor over `assigneesData`. Empty array when unset or
    /// undecodable (never throws into the UI).
    var assignees: [CardAssignee] {
        get {
            guard let data = assigneesData else { return [] }
            return (try? JSONDecoder().decode([CardAssignee].self, from: data)) ?? []
        }
        set {
            assigneesData = try? JSONEncoder().encode(newValue)
        }
    }
}
