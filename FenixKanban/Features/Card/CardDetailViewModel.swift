import CoreData
import SwiftUI

final class CardDetailViewModel: ObservableObject {
    @Published var card: Card
    @Published var title: String
    @Published var cardDescription: String
    @Published var dueDate: Date?
    @Published var isCompleted: Bool
    @Published var selectedLabel: Label?
    @Published var showLabelPicker = false
    @Published var showDatePicker = false

    private let cardRepository: CardRepository
    private let labelRepository: LabelRepository

    var availableColumns: [Column] {
        card.column?.board?.sortedColumns ?? []
    }

    init(card: Card, context: NSManagedObjectContext) {
        self.card = card
        self.title = card.title ?? ""
        self.cardDescription = card.cardDescription ?? ""
        self.dueDate = card.dueDate
        self.isCompleted = card.isCompleted
        self.selectedLabel = card.label
        self.cardRepository = CardRepository(context: context)
        self.labelRepository = LabelRepository(context: context)
    }

    func save() {
        cardRepository.updateCard(
            card,
            title: title.isEmpty ? nil : title,
            description: cardDescription.isEmpty ? nil : cardDescription,
            dueDate: dueDate,
            isCompleted: isCompleted,
            label: selectedLabel
        )
    }

    func moveToColumn(_ column: Column) {
        let currentIndex = column.sortedCards.count
        cardRepository.moveCard(card, to: column, at: currentIndex)
    }

    func clearDueDate() {
        dueDate = nil
        cardRepository.clearDueDate(for: card)
    }

    func clearLabel() {
        selectedLabel = nil
        cardRepository.clearLabel(for: card)
    }

    func selectLabel(_ label: Label) {
        selectedLabel = label
        save()
    }
}
