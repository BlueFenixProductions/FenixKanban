import CoreData
import SwiftUI

struct BoardView: View {
    @StateObject private var viewModel: BoardViewModel
    @Environment(\.adaptiveLayout) private var layout
    @State private var selectedCard: Card?
    @State private var newCardTitle = ""
    @State private var cardPendingDelete: Card?
    @State private var columnPendingDelete: Column?

    // Column sheet state — handles both create and edit
    @State private var columnSheetName = ""
    @State private var columnSheetColor: String? = nil
    @State private var editingColumn: Column? = nil
    @State private var showColumnSheet = false

    // Fizzy server notifications — present only when Fizzy is paired.
    @State private var notificationsViewModel: FizzyNotificationsViewModel?

    // Per-board Fizzy Sync menu (issue #18 follow-on).
    private let fizzyProvider: FizzySyncProvider?
    @State private var fizzySync: BoardFizzySyncModel?
    @State private var showFizzySetup = false
    @State private var showLinkSheet = false
    @State private var linkCandidates: [RemoteBoard] = []
    @State private var pendingUnpair = false
    // Pairing store isn't observable; bump to force the menu to re-derive state.
    @State private var fizzyRefresh = UUID()

    init(board: Board, context: NSManagedObjectContext) {
        let provider = PluginRegistry.shared.provider(named: "Fizzy") as? FizzySyncProvider
        let client = provider?.makeClient()
        _viewModel = StateObject(wrappedValue: BoardViewModel(
            board: board,
            context: context,
            fizzyClient: client
        ))
        _notificationsViewModel = State(
            initialValue: client.map { FizzyNotificationsViewModel(client: $0) }
        )
        self.fizzyProvider = provider
        if let provider, let boardID = board.id {
            _fizzySync = State(initialValue: BoardFizzySyncModel(
                provider: provider, boardID: boardID, boardName: board.name ?? "Board"))
        }
    }

    /// `true` when Fizzy has an active board pairing — used to decide whether
    /// to show sync badges on cards.
    private var boardIsPaired: Bool {
        let fizzy = PluginRegistry.shared.provider(named: "Fizzy") as? FizzySyncProvider
        return fizzy?.isPaired ?? false
    }

    var body: some View {
        boardContent
            .onAppear {
                (PluginRegistry.shared.provider(named: "Fizzy") as? FizzySyncProvider)?.currentBoardID = viewModel.board.id
            }
            .navigationTitle(viewModel.board.name ?? "Board")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
            .confirmationDialog(
                "Delete Card?",
                isPresented: Binding(
                    get: { cardPendingDelete != nil },
                    set: { if !$0 { cardPendingDelete = nil } }
                ),
                presenting: cardPendingDelete
            ) { card in
                Button("Delete", role: .destructive) {
                    viewModel.deleteCard(card)
                    cardPendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    cardPendingDelete = nil
                }
            } message: { card in
                Text("\"\(card.title ?? "Untitled")\" will be permanently deleted. This cannot be undone.")
            }
            .confirmationDialog(
                "Delete Column?",
                isPresented: Binding(
                    get: { columnPendingDelete != nil },
                    set: { if !$0 { columnPendingDelete = nil } }
                ),
                presenting: columnPendingDelete
            ) { column in
                Button("Delete", role: .destructive) {
                    viewModel.deleteColumn(column)
                    columnPendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    columnPendingDelete = nil
                }
            } message: { column in
                let cardCount = column.cardCount
                let cardSuffix = cardCount == 1 ? "card" : "cards"
                Text("\"\(column.name ?? "Untitled")\" and its \(cardCount) \(cardSuffix) will be permanently deleted. This cannot be undone.")
            }
            .modifier(FizzySyncPresentations(
                provider: fizzyProvider,
                model: fizzySync,
                showFizzySetup: $showFizzySetup,
                showLinkSheet: $showLinkSheet,
                linkCandidates: linkCandidates,
                pendingUnpair: $pendingUnpair,
                boardName: viewModel.board.name ?? "Board",
                fizzyRefresh: $fizzyRefresh
            ))
    }

    @ToolbarContentBuilder
    private func boardToolbar() -> some ToolbarContent {
        // Fizzy notifications bell — only shown when Fizzy is paired.
        if let notificationsVM = notificationsViewModel, boardIsPaired {
            ToolbarItem(placement: .secondaryAction) {
                NotificationBellButton(viewModel: notificationsVM)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    presentNewColumnSheet()
                } label: {
                    SwiftUI.Label("New Column", systemImage: "rectangle.split.3x1")
                }

                Divider()

                // "Show Closed" toggle — issue #34 default A.
                // Persisted globally via UserDefaults (no per-board settings
                // mechanism exists; see PR body for rationale).
                Toggle(isOn: Binding(
                    get: { viewModel.showClosedCards },
                    set: { viewModel.showClosedCards = $0 }
                )) {
                    SwiftUI.Label(
                        viewModel.showClosedCards ? "Hide Closed Cards" : "Show Closed Cards",
                        systemImage: viewModel.showClosedCards ? "eye.slash" : "eye"
                    )
                }

                fizzySyncMenuSection
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    @ViewBuilder
    private var fizzySyncMenuSection: some View {
        if let fizzySync {
            Divider()
            // `fizzyRefresh` is read so the menu re-derives after each action
            // (the pairing store is not observable).
            let _ = fizzyRefresh
            switch fizzySync.state {
            case .notConfigured:
                Button {
                    showFizzySetup = true
                } label: {
                    SwiftUI.Label("Set up Fizzy Sync…", systemImage: "arrow.triangle.2.circlepath")
                }
            case .unpaired:
                Button {
                    Task { await fizzySync.createOnFizzy(); fizzyRefresh = UUID() }
                } label: {
                    SwiftUI.Label("Create on Fizzy", systemImage: "plus.circle")
                }
                Button {
                    Task {
                        do {
                            linkCandidates = try await fizzySync.loadUnpairedRemoteBoards()
                            showLinkSheet = true
                        } catch {
                            fizzySync.actionError = "Couldn't load Fizzy boards: \(error)"
                        }
                    }
                } label: {
                    SwiftUI.Label("Link to Fizzy Board…", systemImage: "link")
                }
            case .paired(let enabled, _):
                Toggle(isOn: Binding(
                    get: { enabled },
                    set: { _ in fizzySync.toggleSync(); fizzyRefresh = UUID() }
                )) {
                    SwiftUI.Label("Fizzy Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    Task { await fizzySync.syncNow(); fizzyRefresh = UUID() }
                } label: {
                    SwiftUI.Label("Sync Now", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    pendingUnpair = true
                } label: {
                    SwiftUI.Label("Unpair…", systemImage: "minus.circle")
                }
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
                        cards: viewModel.visibleCards(in: column, showClosed: viewModel.showClosedCards),
                        boardIsPaired: boardIsPaired,
                        onAddCard: {
                            viewModel.selectedColumnForNewCard = column
                        },
                        onDeleteCard: { card in
                            cardPendingDelete = card
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
                            columnPendingDelete = column
                        },
                        onMoveCardUp: { card in
                            viewModel.moveCardUp(card)
                        },
                        onMoveCardDown: { card in
                            viewModel.moveCardDown(card)
                        },
                        onToggleGolden: { card in
                            viewModel.toggleGolden(for: card)
                        },
                        onToggleGoldenByID: { uuid in
                            viewModel.toggleGolden(cardID: uuid)
                        },
                        onLifecycleAction: { card, action in
                            viewModel.performLifecycleAction(action, on: card)
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
                        .font(.crossPlatformSubheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(viewModel.selectedColumnIndex + 1) of \(viewModel.columns.count)")
                        .font(.crossPlatformCaption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            TabView(selection: $viewModel.selectedColumnIndex) {
                ForEach(Array(viewModel.columns.enumerated()), id: \.element.objectID) { index, column in
                    ColumnView(
                        column: column,
                        cards: viewModel.visibleCards(in: column, showClosed: viewModel.showClosedCards),
                        boardIsPaired: boardIsPaired,
                        onAddCard: {
                            viewModel.selectedColumnForNewCard = column
                        },
                        onDeleteCard: { card in
                            cardPendingDelete = card
                        },
                        onSelectCard: { card in
                            selectedCard = card
                        },
                        onDropCard: { cardID, idx in
                            // Use moveCard which handles both same-column reorder
                            // and cross-column move without force-unwrapping.
                            viewModel.moveCard(cardID, to: column, at: idx)
                        },
                        onEditColumn: {
                            presentEditColumnSheet(for: column)
                        },
                        onDeleteColumn: {
                            columnPendingDelete = column
                        },
                        onMoveCardUp: { card in
                            viewModel.moveCardUp(card)
                        },
                        onMoveCardDown: { card in
                            viewModel.moveCardDown(card)
                        },
                        onToggleGolden: { card in
                            viewModel.toggleGolden(for: card)
                        },
                        onToggleGoldenByID: { uuid in
                            viewModel.toggleGolden(cardID: uuid)
                        },
                        onLifecycleAction: { card, action in
                            viewModel.performLifecycleAction(action, on: card)
                        }
                    )
                    .tag(index)
                }
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
        }
    }
}

/// Sheets, dialogs, and alerts for the per-board Fizzy Sync menu, kept in a
/// modifier so `BoardView.body` stays readable. Mirrors the wording used by
/// `FizzyBoardBrowserView`.
private struct FizzySyncPresentations: ViewModifier {
    let provider: FizzySyncProvider?
    let model: BoardFizzySyncModel?
    @Binding var showFizzySetup: Bool
    @Binding var showLinkSheet: Bool
    let linkCandidates: [RemoteBoard]
    @Binding var pendingUnpair: Bool
    let boardName: String
    @Binding var fizzyRefresh: UUID

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showFizzySetup, onDismiss: { fizzyRefresh = UUID() }) {
                if let provider {
                    NavigationStack { FizzyAuthView(provider: provider) }
                }
            }
            .sheet(isPresented: $showLinkSheet) {
                if let model {
                    LinkBoardSheet(
                        localBoardName: boardName,
                        candidates: linkCandidates,
                        onLink: { remote in
                            showLinkSheet = false
                            Task {
                                await model.linkExisting(
                                    toFizzyBoardID: remote.id, fizzyBoardName: remote.name)
                                fizzyRefresh = UUID()
                            }
                        },
                        onCancel: { showLinkSheet = false }
                    )
                }
            }
            .confirmationDialog(
                "Unpair this board?",
                isPresented: $pendingUnpair
            ) {
                Button("Unpair", role: .destructive) {
                    model?.unpair()
                    pendingUnpair = false
                    fizzyRefresh = UUID()
                }
                Button("Cancel", role: .cancel) { pendingUnpair = false }
            } message: {
                Text("Stops syncing this board. Your local cards are kept.")
            }
            .alert("Sync problem", isPresented: Binding(
                get: { model?.actionError != nil },
                set: { if !$0 { model?.actionError = nil } }
            )) {
                Button("OK", role: .cancel) { model?.actionError = nil }
            } message: {
                Text(model?.actionError ?? "")
            }
            .alert("Merged with collisions", isPresented: Binding(
                get: { model?.lastLinkCollisions != nil },
                set: { if !$0 { model?.lastLinkCollisions = nil } }
            )) {
                Button("OK", role: .cancel) { model?.lastLinkCollisions = nil }
            } message: {
                Text((model?.lastLinkCollisions ?? []).prefix(8).joined(separator: "\n"))
            }
    }
}
