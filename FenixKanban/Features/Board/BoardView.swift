import CoreData
import SwiftUI

struct BoardView: View {
    @StateObject private var viewModel: BoardViewModel
    @Environment(\.adaptiveLayout) private var layout
    @State private var selectedCard: Card?
    @State private var newCardTitle = ""

    // Column sheet state — handles both create and edit
    @State private var columnSheetName = ""
    @State private var columnSheetColor: String? = nil
    @State private var editingColumn: Column? = nil
    @State private var showColumnSheet = false

    init(board: Board, context: NSManagedObjectContext) {
        _viewModel = StateObject(wrappedValue: BoardViewModel(board: board, context: context))
    }

    var body: some View {
        boardContent
            .navigationTitle(viewModel.board.name ?? "Board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: boardToolbar)
            .sheet(isPresented: $showColumnSheet) {
                NewColumnSheet(
                    name: $columnSheetName,
                    colorHex: $columnSheetColor,
                    isEditing: editingColumn != nil
                ) {
                    let trimmed = columnSheetName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    if let existing = editingColumn {
                        viewModel.updateColumn(existing, name: trimmed, colorHex: columnSheetColor)
                    } else {
                        viewModel.addColumn(name: trimmed, colorHex: columnSheetColor)
                    }
                    resetColumnSheet()
                }
            }
            .sheet(item: $viewModel.selectedColumnForNewCard) { column in
                NewCardSheet(title: $newCardTitle) {
                    if !newCardTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                        viewModel.addCard(to: column, title: newCardTitle)
                        newCardTitle = ""
                    }
                }
            }
            .sheet(item: $selectedCard) { card in
                CardDetailView(card: card, context: viewModel.board.managedObjectContext!)
            }
    }

    @ToolbarContentBuilder
    private func boardToolbar() -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    presentNewColumnSheet()
                } label: {
                    SwiftUI.Label("New Column", systemImage: "rectangle.split.3x1")
                }
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    @ViewBuilder
    private var boardContent: some View {
        if viewModel.columns.isEmpty {
            EmptyStateView(
                icon: "rectangle.3.group",
                title: "No Columns",
                message: "Add a column to start organizing cards",
                actionTitle: "Add Column"
            ) {
                presentNewColumnSheet()
            }
        } else if layout.showMultiColumn {
            multiColumnLayout
        } else {
            singleColumnLayout
        }
    }

    // MARK: - Column Sheet Helpers

    private func presentNewColumnSheet() {
        editingColumn = nil
        columnSheetName = ""
        columnSheetColor = nil
        showColumnSheet = true
    }

    private func presentEditColumnSheet(for column: Column) {
        editingColumn = column
        columnSheetName = column.name ?? ""
        columnSheetColor = column.colorHex
        showColumnSheet = true
    }

    private func resetColumnSheet() {
        editingColumn = nil
        columnSheetName = ""
        columnSheetColor = nil
    }

    // MARK: - Multi-Column (iPad / Mac / Landscape)

    private var multiColumnLayout: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(viewModel.columns, id: \.objectID) { column in
                    ColumnView(
                        column: column,
                        cards: column.sortedCards,
                        onAddCard: {
                            viewModel.selectedColumnForNewCard = column
                        },
                        onDeleteCard: { card in
                            viewModel.deleteCard(card)
                        },
                        onSelectCard: { card in
                            selectedCard = card
                        },
                        onDropCard: { cardID, index in
                            viewModel.moveCard(cardID, to: column, at: index)
                        },
                        onEditColumn: {
                            presentEditColumnSheet(for: column)
                        },
                        onDeleteColumn: {
                            viewModel.deleteColumn(column)
                        }
                    )
                    .frame(width: 280)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Single Column (iPhone Portrait)

    private var singleColumnLayout: some View {
        VStack(spacing: 0) {
            // Column indicator
            if viewModel.columns.count > 1 {
                HStack {
                    Text(viewModel.columns[viewModel.selectedColumnIndex].name ?? "")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(viewModel.selectedColumnIndex + 1) of \(viewModel.columns.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            TabView(selection: $viewModel.selectedColumnIndex) {
                ForEach(Array(viewModel.columns.enumerated()), id: \.element.objectID) { index, column in
                    ColumnView(
                        column: column,
                        cards: column.sortedCards,
                        onAddCard: {
                            viewModel.selectedColumnForNewCard = column
                        },
                        onDeleteCard: { card in
                            viewModel.deleteCard(card)
                        },
                        onSelectCard: { card in
                            selectedCard = card
                        },
                        onDropCard: { cardID, idx in
                            viewModel.reorderCard(
                                column.sortedCards.first { $0.id?.uuidString == String(describing: cardID) }!,
                                to: idx,
                                in: column
                            )
                        },
                        onEditColumn: {
                            presentEditColumnSheet(for: column)
                        },
                        onDeleteColumn: {
                            viewModel.deleteColumn(column)
                        }
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }
}
