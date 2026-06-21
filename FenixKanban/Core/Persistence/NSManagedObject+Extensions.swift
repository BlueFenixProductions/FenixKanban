import CoreData

extension Board {
    var sortedColumns: [Column] {
        let set = columns as? Set<Column> ?? []
        return set.sorted { $0.sortOrder < $1.sortOrder }
    }

    var columnCount: Int {
        (columns as? Set<Column>)?.count ?? 0
    }

    var totalCardCount: Int {
        sortedColumns.reduce(0) { $0 + $1.cardCount }
    }
}

extension Column {
    /// Cards sorted with golden first, then by sortOrder. Golden cards
    /// always visually outrank non-golden ones regardless of sortOrder.
    var sortedCards: [Card] {
        let set = cards as? Set<Card> ?? []
        return set.sorted { lhs, rhs in
            if lhs.isGolden != rhs.isGolden { return lhs.isGolden && !rhs.isGolden }
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    var cardCount: Int {
        (cards as? Set<Card>)?.count ?? 0
    }
}

extension Card {
    /// Labels sorted by name for stable chip ordering in UI.
    var sortedLabels: [Label] {
        let set = labels as? Set<Label> ?? []
        return set.sortedByDisplayName()
    }

    /// Steps sorted by sortOrder, for direct CoreData set access.
    var sortedSteps: [CardStep] {
        let set = steps as? Set<CardStep> ?? []
        return set.sorted { $0.sortOrder < $1.sortOrder }
    }
}

extension Sequence where Element == Label {
    /// Shared display ordering for label chips: locale-aware, numeric-smart
    /// (`localizedStandardCompare`, Finder-style). Used by `Card.sortedLabels`
    /// and `CardDetailViewModel.sortedSelectedLabels` so board cards and the
    /// detail sheet always agree on chip order.
    func sortedByDisplayName() -> [Label] {
        sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending }
    }
}

extension Label {
    var cardCount: Int {
        (cards as? Set<Card>)?.count ?? 0
    }
}
