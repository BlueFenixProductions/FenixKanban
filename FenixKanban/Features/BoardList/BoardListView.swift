import SwiftUI
import CoreData

struct BoardListView: View {
    @StateObject private var viewModel: BoardListViewModel
    @State private var newBoardName = ""
    @State private var newBoardColor = "#0F3460"

    init(context: NSManagedObjectContext) {
        _viewModel = StateObject(wrappedValue: BoardListViewModel(context: context))
    }

    // For preview injection
    init(viewModel: BoardListViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
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
                    viewModel.showNewBoardSheet = true
                }
            } else {
                boardList
            }
        }
        .navigationTitle("Boards")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.showNewBoardSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $viewModel.showNewBoardSheet) {
            NewBoardSheet(
                name: $newBoardName,
                colorHex: $newBoardColor
            ) {
                if !newBoardName.trimmingCharacters(in: .whitespaces).isEmpty {
                    viewModel.createBoard(name: newBoardName, colorHex: newBoardColor)
                    newBoardName = ""
                    newBoardColor = "#0F3460"
                }
            }
        }
    }

    private var boardList: some View {
        List {
            ForEach(viewModel.boards, id: \.objectID) { board in
                NavigationLink(value: board.objectID) {
                    BoardRowView(board: board)
                }
                .listRowBackground(Color(.secondarySystemBackground))
            }
            .onDelete(perform: viewModel.deleteBoards)
            .onMove(perform: viewModel.moveBoard)
        }
        .listStyle(.plain)
    }
}

struct NewBoardSheet: View {
    @Binding var name: String
    @Binding var colorHex: String
    let onCreate: () -> Void
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
            .navigationTitle("New Board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
