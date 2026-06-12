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
    @Published var assignees: [CardAssignee]
    @Published var isWatched: Bool
    @Published var isPinned: Bool
    @Published var showLabelPicker = false
    @Published var showAssigneePicker = false
    @Published var showDatePicker = false
    @Published var errorMessage: String?

    private let cardRepository: CardRepository
    private let labelRepository: LabelRepository
    private var observerToken: (any NSObjectProtocol)?
    let fizzyClient: FizzyClient?

    /// Present only for fizzy-paired cards with a live client — drives the
    /// steps checklist section (issue #19, online-only).
    let stepsViewModel: CardStepsViewModel?

    /// Present only for fizzy-paired cards with a live client — drives the
    /// comments section with cache-first read/write (issue #16).
    let commentsViewModel: CardCommentsViewModel?

    var availableColumns: [Column] {
        card.column?.board?.sortedColumns ?? []
    }

    var sortedSelectedLabels: [Label] {
        selectedLabels.sortedByDisplayName()
    }

    init(card: Card, context: NSManagedObjectContext, fizzyClient: FizzyClient? = nil) {
        self.card = card
        self.title = card.title ?? ""
        self.cardDescription = card.cardDescription ?? ""
        self.dueDate = card.dueDate
        self.isCompleted = card.isCompleted
        self.selectedLabels = card.labels as? Set<Label> ?? []
        self.assignees = card.assignees
        self.isWatched = card.isWatched
        self.isPinned = card.isPinned
        self.cardRepository = CardRepository(context: context)
        self.labelRepository = LabelRepository(context: context)
        self.fizzyClient = fizzyClient
        if card.fizzyNumber > 0, let client = fizzyClient {
<<<<<<< HEAD
            let stepRepo = StepRepository(context: context)
            self.stepsViewModel = CardStepsViewModel(card: card, client: client, repository: stepRepo)
=======
            self.stepsViewModel = CardStepsViewModel(cardNumber: Int(card.fizzyNumber), client: client)
            self.commentsViewModel = CardCommentsViewModel(
                cardFizzyNumber: card.fizzyNumber,
                client: client,
                context: context
            )
>>>>>>> origin/develop
        } else {
            self.stepsViewModel = nil
            self.commentsViewModel = nil
        }
        observeCardChanges(context: context)
    }

    deinit {
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// The four sync-authoritative snapshot fields (labels, assignees, watch,
    /// pin) go stale when a sync or CloudKit merge lands while the detail
    /// sheet is open — the next save() would write the stale labels set back
    /// over a remote addition (#20). Re-read them whenever this card changes
    /// underneath us. Text-edit fields (title, description, dueDate,
    /// isCompleted) stay untouched: refreshing those would clobber
    /// in-progress typing (documented LWW).
    private func observeCardChanges(context: NSManagedObjectContext) {
        observerToken = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange,
            object: context,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.refreshSnapshotFields(from: notification)
            }
        }
    }

    private func refreshSnapshotFields(from notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        let changed = [NSUpdatedObjectsKey, NSRefreshedObjectsKey]
            .compactMap { userInfo[$0] as? Set<NSManagedObject> }
            .reduce(Set<NSManagedObject>()) { $0.union($1) }
        guard changed.contains(card), !card.isDeleted, card.managedObjectContext != nil else { return }
        selectedLabels = card.labels as? Set<Label> ?? []
        assignees = card.assignees
        isWatched = card.isWatched
        isPinned = card.isPinned
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
            // A sync can soft-delete the card while the push is in flight
            // (#20 guard family, BoardViewModel precedent): reverting a dead
            // card would fire a fault. Stand down — the failure is moot.
            guard !card.isDeleted, card.managedObjectContext != nil else { return }
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

    /// Fizzy-only affordances (assignments, watch, pin) share this gate:
    /// paired card + live client (issue #19).
    var isFizzyPaired: Bool {
        card.fizzyNumber > 0 && fizzyClient != nil
    }

    /// Assignments are fizzy-only: the row renders (and toggles run) only
    /// for paired cards with a live client (issue #19 wave 2).
    var canEditAssignments: Bool { isFizzyPaired }

    /// Toggles a user's assignment: optimistic blob update, POST toggle,
    /// state-recheck revert on failure (same pattern as `toggleLabel` —
    /// last writer wins locally; the next pull reconciles the server).
    func toggleAssignment(_ user: FizzyUser) async {
        guard card.fizzyNumber > 0, let client = fizzyClient else { return }
        let wasAssigned = assignees.contains { $0.id == user.id }
        if wasAssigned {
            assignees.removeAll { $0.id == user.id }
        } else {
            assignees.append(CardAssignee(id: user.id, name: user.name))
        }
        cardRepository.updateAssignees(for: card, to: assignees)

        do {
            try await client.toggleCardAssignment(number: Int(card.fizzyNumber), assigneeID: user.id)
        } catch {
            // #20 guard family: stand down if a sync deleted the card mid-flight.
            guard !card.isDeleted, card.managedObjectContext != nil else { return }
            // Revert only if no later toggle changed this user's state while
            // the POST was in flight.
            if assignees.contains(where: { $0.id == user.id }) != wasAssigned {
                if wasAssigned {
                    assignees.append(CardAssignee(id: user.id, name: user.name))
                } else {
                    assignees.removeAll { $0.id == user.id }
                }
                cardRepository.updateAssignees(for: card, to: assignees)
            }
            errorMessage = "Couldn't update assignment for \(user.name) on Fizzy."
        }
    }

    /// Watch state is local write-only: Fizzy accepts watch/unwatch but never
    /// reports current state (no wire field, no watchers endpoint) — Captain's
    /// ruling, #19 wave 3. Optimistic flip + state-recheck revert; can drift
    /// if toggled from another client (documented MVP limitation).
    func toggleWatched() async {
        guard card.fizzyNumber > 0, let client = fizzyClient else { return }
        let wasWatched = isWatched
        isWatched = !wasWatched
        cardRepository.setWatched(isWatched, for: card)
        do {
            if wasWatched {
                try await client.unwatchCard(number: Int(card.fizzyNumber))
            } else {
                try await client.watchCard(number: Int(card.fizzyNumber))
            }
        } catch {
            // #20 guard family: stand down if a sync deleted the card mid-flight.
            guard !card.isDeleted, card.managedObjectContext != nil else { return }
            // Revert only if no later toggle changed the state in flight.
            if isWatched != wasWatched {
                isWatched = wasWatched
                cardRepository.setWatched(isWatched, for: card)
            }
            errorMessage = "Couldn't update watch state on Fizzy."
        }
    }

    /// Pin state is remote-authoritative via GET /my/pins on sync; the toggle
    /// is optimistic with state-recheck revert (issue #19 wave 3).
    func togglePinned() async {
        guard card.fizzyNumber > 0, let client = fizzyClient else { return }
        let wasPinned = isPinned
        isPinned = !wasPinned
        cardRepository.setPinned(isPinned, for: card)
        do {
            if wasPinned {
                try await client.unpinCard(number: Int(card.fizzyNumber))
            } else {
                try await client.pinCard(number: Int(card.fizzyNumber))
            }
        } catch {
            // #20 guard family: stand down if a sync deleted the card mid-flight.
            guard !card.isDeleted, card.managedObjectContext != nil else { return }
            if isPinned != wasPinned {
                isPinned = wasPinned
                cardRepository.setPinned(isPinned, for: card)
            }
            errorMessage = "Couldn't update pin on Fizzy."
        }
    }

    /// Golden is local-first (works unpaired); paired cards also push to
    /// Fizzy's goldness endpoint so the next pull doesn't revert the flip —
    /// applyRemote is remote-authoritative on `golden` (#19 wave 3 fixes
    /// the silent-revert latent bug). State-recheck revert on failure.
    func toggleGolden() async {
        let wasGolden = card.isGolden
        applyGoldenLocally(!wasGolden)

        guard card.fizzyNumber > 0, let client = fizzyClient else { return }
        do {
            if wasGolden {
                try await client.unmarkCardGolden(number: Int(card.fizzyNumber))
            } else {
                try await client.markCardGolden(number: Int(card.fizzyNumber))
            }
        } catch {
            // #20 guard family: stand down if a sync deleted the card
            // mid-flight — the isGolden read below would fire a fault.
            guard !card.isDeleted, card.managedObjectContext != nil else { return }
            if card.isGolden != wasGolden {
                applyGoldenLocally(wasGolden)
            }
            errorMessage = "Couldn't update golden ticket on Fizzy."
        }
    }

    /// Golden keeps its modifiedAt bump (unlike watch/pin): golden is pulled
    /// card content, and the bump blocks the LWW pull branch until the push
    /// cycle completes — protecting against stale-pull reverts.
    private func applyGoldenLocally(_ golden: Bool) {
        card.isGolden = golden
        card.modifiedAt = Date()
        card.column?.modifiedAt = Date()
        card.column?.board?.modifiedAt = Date()
        try? card.managedObjectContext?.save()
        objectWillChange.send()
    }
}
