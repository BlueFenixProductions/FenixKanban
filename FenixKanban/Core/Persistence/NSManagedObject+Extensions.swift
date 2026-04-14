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
    var sortedCards: [Card] {
        let set = cards as? Set<Card> ?? []
        return set.sorted { $0.sortOrder < $1.sortOrder }
    }

    var cardCount: Int {
        (cards as? Set<Card>)?.count ?? 0
    }
}

extension Label {
    var cardCount: Int {
        (cards as? Set<Card>)?.count ?? 0
    }
}
