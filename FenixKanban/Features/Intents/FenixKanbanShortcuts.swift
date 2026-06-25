import AppIntents

struct FenixKanbanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddCardIntent(),
            phrases: [
                "Add a card to \(.applicationName)",
                "Create a card in \(.applicationName)",
                "New card in \(.applicationName)"
            ],
            shortTitle: "Add Card",
            systemImageName: "plus.rectangle"
        )
        AppShortcut(
            intent: OpenBoardIntent(),
            phrases: [
                "Open \(\.$board) in \(.applicationName)",
                "Show \(\.$board) in \(.applicationName)",
                "Go to \(\.$board) in \(.applicationName)"
            ],
            shortTitle: "Open Board",
            systemImageName: "rectangle.3.group"
        )
        AppShortcut(
            intent: OpenCardIntent(),
            phrases: [
                "Open \(\.$card) in \(.applicationName)",
                "Show \(\.$card) in \(.applicationName)"
            ],
            shortTitle: "Open Card",
            systemImageName: "doc.text"
        )
        AppShortcut(
            intent: ToggleGoldenIntent(),
            phrases: [
                "Toggle golden ticket in \(.applicationName)",
                "Mark the golden ticket in \(.applicationName)"
            ],
            shortTitle: "Toggle Golden",
            systemImageName: "ticket.fill"
        )
        AppShortcut(
            intent: FindGoldenCardsIntent(),
            phrases: [
                "Find golden cards in \(.applicationName)",
                "Show my golden tickets in \(.applicationName)"
            ],
            shortTitle: "Find Golden Cards",
            systemImageName: "ticket"
        )
    }
}
