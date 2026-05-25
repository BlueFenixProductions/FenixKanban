import AppIntents

struct FenixKanbanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
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
    }
}
