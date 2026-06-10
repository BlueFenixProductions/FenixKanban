import CoreData
import SwiftUI

@MainActor
final class CardDetailViewModel: ObservableObject {
    @Published var card: Card
    @Published var title: String
    @Published var cardDescription: String
    @Published var dueDate: Date?
    @Published var isCompleted: Bool
    @Published var selectedLabels: Set<Label>
    @Published var showLabelPicker = false
    @Published var showDatePicker = false
    @Published var errorMessage: String?

    private let cardRepository: CardRepository
    private let labelRepository: LabelRepository
    private let fizzyClient: FizzyClient?

    /// Present only for fizzy-paired cards with a live client — drives the
    /// steps checklist section (issue #19, online-only).
    let stepsViewModel: CardStepsViewModel?

    var availableColumns: [Column] {
        card.column?.board?.sortedColumns ?? []
    }

    var sortedSelectedLabels: [Label] {
        selectedLabels.sorted { ($0.name ?? "") < ($1.name ?? "") }
    }

    init(card: Card, context: NSManagedObjectContext, fizzyClient: FizzyClient? = nil) {
        self.card = card
        self.title = card.title ?? ""
        self.cardDescription = card.cardDescription ?? ""
        self.dueDate = card.dueDate
        self.isCompleted = card.isCompleted
        self.selectedLabels = card.labels as? Set<Label> ?? []
        self.cardRepository = CardRepository(context: context)
        self.labelRepository = LabelRepository(context: context)
        self.fizzyClient = fizzyClient
        if card.fizzyNumber > 0, let client = fizzyClient {
            self.stepsViewModel = CardStepsViewModel(cardNumber: Int(card.fizzyNumber), client: client)
        } else {
            self.stepsViewModel = nil
        }
    }

    func save() {
        cardRepository.updateCard(
            card,
            title: title.isEmpty ? nil : title,
            description: cardDescription.isEmpty ? nil : cardDescription,
            dueDate: dueDate,
            isCompleted: isCompleted,
            labels: selectedLabels
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

    func clearLabels() {
        selectedLabels = []
        cardRepository.clearLabels(for: card)
    }

    /// Toggles a label locally, then mirrors the change to Fizzy when the
    /// card is paired (`fizzyNumber > 0`) and a client is available.
    /// Online-only by Captain's ruling on #19: a failed push reverts the
    /// local toggle and surfaces an error — the next sync pull is the
    /// reconciler of last resort. Concurrent toggles of the same label are
    /// last-writer-wins locally; the next pull reconciles the server.
    func toggleLabel(_ label: Label) async {
        let wasSelected = selectedLabels.contains(label)
        if wasSelected { selectedLabels.remove(label) } else { selectedLabels.insert(label) }
        save()

        guard card.fizzyNumber > 0, let client = fizzyClient, let tagTitle = label.name else { return }
        do {
            try await client.toggleCardTag(number: Int(card.fizzyNumber), tagTitle: tagTitle)
        } catch {
            // Revert only if no later toggle changed this label's state while
            // the push was in flight — otherwise leave the newer state alone
            // (last writer wins locally; the next pull reconciles the server).
            if selectedLabels.contains(label) != wasSelected {
                if wasSelected { selectedLabels.insert(label) } else { selectedLabels.remove(label) }
                save()
            }
            errorMessage = "Couldn't update tag “\(tagTitle)” on Fizzy."
        }
    }

    func toggleGolden() {
        card.isGolden.toggle()
        card.modifiedAt = Date()
        card.column?.modifiedAt = Date()
        card.column?.board?.modifiedAt = Date()
        try? card.managedObjectContext?.save()
        objectWillChange.send()
    }
}
