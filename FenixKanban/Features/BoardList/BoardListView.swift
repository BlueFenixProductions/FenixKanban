import SwiftUI
import CoreData

struct BoardListView: View {
    @StateObject private var viewModel: BoardListViewModel
    @Binding var selection: NSManagedObjectID?

    // Board sheet state — handles both create and edit
    @State private var boardSheetName = ""
    @State private var boardSheetColor = "#0F3460"
    @State private var editingBoard: Board? = nil
    @State private var showBoardSheet = false

    @State private var boardPendingDelete: Board?

    init(context: NSManagedObjectContext, selection: Binding<NSManagedObjectID?> = .constant(nil)) {
        _viewModel = StateObject(wrappedValue: BoardListViewModel(context: context))
        _selection = selection
    }

    // For preview injection
    init(viewModel: BoardListViewModel, selection: Binding<NSManagedObjectID?> = .constant(nil)) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _selection = selection
    }

    var body: some View {
        Group {
            if viewModel.boards.isEmpty {
                EmptyStateView(
                    icon: "rectangle.on.rectangle.slash",
                    title: "No Boards Yet",
                    message: "Create your first board to get started",
                    actionTitle: "New Board"
                ) {
                    presentNewBoardSheet()
                }
            } else {
                boardList
            }
        }
        .navigationTitle("Boards")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarLeading) {
                EditButton()
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentNewBoardSheet()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showBoardSheet) {
            BoardEditorSheet(
                name: $boardSheetName,
                colorHex: $boardSheetColor,
                isEditing: editingBoard != nil
            ) {
                let trimmed = boardSheetName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                if let existing = editingBoard {
                    viewModel.updateBoard(existing, name: trimmed, colorHex: boardSheetColor)
                } else {
                    viewModel.createBoard(name: trimmed, colorHex: boardSheetColor)
                }
                resetBoardSheet()
            }
        }
        .confirmationDialog(
            "Delete Board?",
            isPresented: Binding(
                get: { boardPendingDelete != nil },
                set: { if !$0 { boardPendingDelete = nil } }
            ),
            presenting: boardPendingDelete
        ) { board in
            Button("Delete", role: .destructive) {
                if selection == board.objectID {
                    selection = nil
                }
                viewModel.deleteBoard(board)
                boardPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                boardPendingDelete = nil
            }
        } message: { board in
            let columnCount = board.columnCount
            let cardCount = board.totalCardCount
            let columnSuffix = columnCount == 1 ? "column" : "columns"
            let cardSuffix = cardCount == 1 ? "card" : "cards"
            Text("\"\(board.name ?? "Untitled")\" and its \(columnCount) \(columnSuffix) (\(cardCount) \(cardSuffix)) will be permanently deleted. This cannot be undone.")
        }
    }

    // MARK: - Sheet Helpers

    private func presentNewBoardSheet() {
        editingBoard = nil
        boardSheetName = ""
        boardSheetColor = "#0F3460"
        showBoardSheet = true
    }

    private func presentEditBoardSheet(for board: Board) {
        editingBoard = board
        boardSheetName = board.name ?? ""
        boardSheetColor = board.colorHex ?? "#0F3460"
        showBoardSheet = true
    }

    private func resetBoardSheet() {
        editingBoard = nil
        boardSheetName = ""
        boardSheetColor = "#0F3460"
    }

    // MARK: - Board List

    private var boardList: some View {
        List(selection: $selection) {
            ForEach(viewModel.boards, id: \.objectID) { board in
                // NavigationLink(value:) is the canonical pattern for
                // NavigationSplitView sidebars — pairs with the selection
                // binding to update the detail column on tap.
                NavigationLink(value: board.objectID) {
                    BoardRowView(board: board)
                }
                .listRowBackground(Color.crossPlatformSecondarySystemBackground)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        presentEditBoardSheet(for: board)
                    } label: {
                        SwiftUI.Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
                .contextMenu {
                    Button {
                        presentEditBoardSheet(for: board)
                    } label: {
                        SwiftUI.Label("Edit Board", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        boardPendingDelete = board
                    } label: {
                        SwiftUI.Label("Delete Board", systemImage: "trash")
                    }
                }
            }
            .onDelete { offsets in
                // Route swipe-to-delete through the confirmation dialog.
                if let index = offsets.first {
                    boardPendingDelete = viewModel.boards[index]
                }
            }
            .onMove(perform: viewModel.moveBoard)
        }
        .listStyle(.sidebar)
    }
}

struct BoardEditorSheet: View {
    @Binding var name: String
    @Binding var colorHex: String
    let isEditing: Bool
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let presetColors = [
        "#E94560", "#0F3460", "#16C79A", "#F5A623",
        "#9B59B6", "#3498DB", "#E67E22", "#1ABC9C"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Board Name") {
                    TextField("Enter name", text: $name)
                }

                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(presetColors, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 40, height: 40)
                                .overlay(
                                    Circle()
                                        .strokeBorder(.white, lineWidth: colorHex == hex ? 3 : 0)
                                )
                                .onTapGesture { colorHex = hex }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle(isEditing ? "Edit Board" : "New Board")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Create") {
                        onSave()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
