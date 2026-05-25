import Testing
import CoreData
@testable import FenixKanban

@Suite("Board ViewModel Tests")
@MainActor
struct BoardViewModelTests {
    
    // Helper to create in-memory Core Data stack for testing
    func createTestContext() -> NSManagedObjectContext {
        let container = NSPersistentContainer(name: "FenixKanban")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        
        container.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Failed to load test store: \(error)")
            }
        }
        
        return container.viewContext
    }
    
    // Helper to create a test board
    func createTestBoard(in context: NSManagedObjectContext, name: String = "Test Board") -> Board {
        let board = Board(context: context)
        board.id = UUID()
        board.name = name
        board.order = 0
        board.createdAt = Date()
        return board
    }
    
    @Test("ViewModel initializes with board")
    func initialization() async throws {
        let context = createTestContext()
        let board = createTestBoard(in: context)
        
        let viewModel = BoardViewModel(board: board, context: context)
        
        #expect(viewModel.board.id == board.id)
        #expect(viewModel.columns.isEmpty)
        #expect(viewModel.selectedColumnIndex == 0)
    }
    
    @Test("Add column updates columns array")
    func addColumn() async throws {
        let context = createTestContext()
        let board = createTestBoard(in: context)
        let viewModel = BoardViewModel(board: board, context: context)
        
        viewModel.addColumn(name: "To Do", colorHex: "#FF0000")
        
        try context.save()
        viewModel.refreshColumns()
        
        #expect(viewModel.columns.count == 1)
        #expect(viewModel.columns.first?.name == "To Do")
        #expect(viewModel.columns.first?.colorHex == "#FF0000")
    }
    
    @Test("Delete column removes from array")
    func deleteColumn() async throws {
        let context = createTestContext()
        let board = createTestBoard(in: context)
        let viewModel = BoardViewModel(board: board, context: context)
        
        viewModel.addColumn(name: "Column 1")
        viewModel.addColumn(name: "Column 2")
        try context.save()
        viewModel.refreshColumns()
        
        let columnToDelete = viewModel.columns.first!
        viewModel.deleteColumn(columnToDelete)
        
        try context.save()
        viewModel.refreshColumns()
        
        #expect(viewModel.columns.count == 1)
        #expect(viewModel.columns.first?.name == "Column 2")
    }
    
    @Test("Delete column adjusts selection index")
    func deleteColumnAdjustsSelection() async throws {
        let context = createTestContext()
        let board = createTestBoard(in: context)
        let viewModel = BoardViewModel(board: board, context: context)
        
        viewModel.addColumn(name: "Column 1")
        viewModel.addColumn(name: "Column 2")
        viewModel.addColumn(name: "Column 3")
        try context.save()
        viewModel.refreshColumns()
        
        // Select last column
        viewModel.selectedColumnIndex = 2
        
        // Delete last column
        let lastColumn = viewModel.columns.last!
        viewModel.deleteColumn(lastColumn)
        try context.save()
        
        // Selection should be adjusted
        #expect(viewModel.selectedColumnIndex <= viewModel.columns.count - 1)
    }
    
    @Test("Add card to column")
    func addCard() async throws {
        let context = createTestContext()
        let board = createTestBoard(in: context)
        let viewModel = BoardViewModel(board: board, context: context)
        
        viewModel.addColumn(name: "To Do")
        try context.save()
        viewModel.refreshColumns()
        
        let column = viewModel.columns.first!
        viewModel.addCard(to: column, title: "Test Card")
        try context.save()
        viewModel.refreshColumns()
        
        let cards = viewModel.columns.first?.sortedCards ?? []
        #expect(cards.count == 1)
        #expect(cards.first?.title == "Test Card")
    }
    
    @Test("Update column name and color")
    func updateColumn() async throws {
        let context = createTestContext()
        let board = createTestBoard(in: context)
        let viewModel = BoardViewModel(board: board, context: context)
        
        viewModel.addColumn(name: "Original Name", colorHex: "#FF0000")
        try context.save()
        viewModel.refreshColumns()
        
        let column = viewModel.columns.first!
        viewModel.updateColumn(column, name: "Updated Name", colorHex: "#00FF00")
        try context.save()
        viewModel.refreshColumns()
        
        #expect(viewModel.columns.first?.name == "Updated Name")
        #expect(viewModel.columns.first?.colorHex == "#00FF00")
    }
    
    @Test("ViewModel deallocates cleanly")
    func deallocation() async throws {
        let context = createTestContext()
        let board = createTestBoard(in: context)
        
        var viewModel: BoardViewModel? = BoardViewModel(board: board, context: context)
        
        // Create a weak reference to check deallocation
        weak var weakViewModel = viewModel
        
        // Release the view model
        viewModel = nil
        
        // Give ARC a chance to deallocate
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        
        // View model should be deallocated
        #expect(weakViewModel == nil, "ViewModel should deallocate when no longer referenced")
    }
}

// MARK: - Integration Test Notes
/*
 These tests require:
 1. Core Data model file (FenixKanban.xcdatamodeld)
 2. Board, Column, Card entities properly configured
 3. BoardRepository and CardRepository implementations
 4. Relationship mappings between entities
 
 If tests fail:
 - Verify Core Data model is included in test target
 - Check entity relationships are configured
 - Ensure repositories handle in-memory stores correctly
 */
