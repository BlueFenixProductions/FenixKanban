import CoreData

extension PersistenceController {
    static var previewWithData: PersistenceController {
        let controller = PersistenceController(inMemory: true, useCloudKit: false)
        let context = controller.viewContext

        // Labels
        let urgent = Label(context: context)
        urgent.id = UUID()
        urgent.name = "Urgent"
        urgent.colorHex = "#E94560"
        urgent.createdAt = Date()

        let dev = Label(context: context)
        dev.id = UUID()
        dev.name = "Dev"
        dev.colorHex = "#0F3460"
        dev.createdAt = Date()

        let design = Label(context: context)
        design.id = UUID()
        design.name = "Design"
        design.colorHex = "#16C79A"
        design.createdAt = Date()

        // Board
        let board = Board(context: context)
        board.id = UUID()
        board.name = "Project Alpha"
        board.colorHex = "#E94560"
        board.createdAt = Date()
        board.modifiedAt = Date()
        board.sortOrder = 0

        // Columns
        let todo = Column(context: context)
        todo.id = UUID()
        todo.name = "To Do"
        todo.createdAt = Date()
        todo.modifiedAt = Date()
        todo.sortOrder = 0
        todo.board = board

        let inProgress = Column(context: context)
        inProgress.id = UUID()
        inProgress.name = "In Progress"
        inProgress.createdAt = Date()
        inProgress.modifiedAt = Date()
        inProgress.sortOrder = 1000
        inProgress.board = board

        let done = Column(context: context)
        done.id = UUID()
        done.name = "Done"
        done.createdAt = Date()
        done.modifiedAt = Date()
        done.sortOrder = 2000
        done.board = board

        // Cards
        let card1 = Card(context: context)
        card1.id = UUID()
        card1.title = "Design mockups"
        card1.cardDescription = "Create wireframes for the new dashboard"
        card1.createdAt = Date()
        card1.modifiedAt = Date()
        card1.dueDate = Date().addingTimeInterval(86400 * 2)
        card1.sortOrder = 0
        card1.column = todo
        card1.addToLabels(urgent)

        let card2 = Card(context: context)
        card2.id = UUID()
        card2.title = "Write API spec"
        card2.createdAt = Date()
        card2.modifiedAt = Date()
        card2.sortOrder = 1000
        card2.column = todo
        card2.addToLabels(dev)

        let card3 = Card(context: context)
        card3.id = UUID()
        card3.title = "Backend refactor"
        card3.createdAt = Date()
        card3.modifiedAt = Date()
        card3.dueDate = Date().addingTimeInterval(-86400)
        card3.sortOrder = 0
        card3.column = inProgress
        card3.addToLabels(dev)

        let card4 = Card(context: context)
        card4.id = UUID()
        card4.title = "Project setup"
        card4.createdAt = Date()
        card4.modifiedAt = Date()
        card4.isCompleted = true
        card4.sortOrder = 0
        card4.column = done

        // Second board
        let board2 = Board(context: context)
        board2.id = UUID()
        board2.name = "Personal Tasks"
        board2.colorHex = "#0F3460"
        board2.createdAt = Date()
        board2.modifiedAt = Date()
        board2.sortOrder = 1000

        let personal = Column(context: context)
        personal.id = UUID()
        personal.name = "To Do"
        personal.createdAt = Date()
        personal.modifiedAt = Date()
        personal.sortOrder = 0
        personal.board = board2

        try? context.save()
        return controller
    }
}
