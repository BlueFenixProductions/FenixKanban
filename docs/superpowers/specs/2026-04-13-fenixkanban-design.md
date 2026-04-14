# FenixKanban Design Spec

**Date:** 2026-04-13
**Status:** Approved
**Repository:** BlueFenixProductions/FenixKanban
**Local path:** ~/Documents/GitHub/FenixKanban

## Overview

FenixKanban is a full-featured Kanban board app for iPhone, iPad, and Mac built with SwiftUI and CoreData with CloudKit sync. V1 targets personal use (1-3 devices) with an architecture designed to support team collaboration in v2.

## Product Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Target audience | Personal, architect for team growth | Ship lean, extensible architecture |
| Platforms | iPhone + iPad + Mac | Full Apple ecosystem via SwiftUI |
| Board layout | Single-column focus (iPhone portrait), multi-column (landscape/iPad/Mac) | Natural adaptive UX |
| Card complexity | Minimal: title, description, one label, due date | Focused v1, schema supports extension |
| V1 scope | Core + sync + notifications | Defer teams/sharing/collaboration to v2 |
| Board organization | Multiple boards, board list home screen | Standard kanban pattern |
| Visual design | Dark-first power tool | Dense, efficient, GitHub Projects aesthetic |
| Labels | Global library, color + name | Shared across all boards |
| Offline | Full functionality, automatic conflict resolution | CoreData is always source of truth |
| Notifications | Due date reminders + sync changes + daily digest | Full engagement layer |

## Architecture

### Pattern: MVVM + Repository

```
View -> ViewModel -> Repository -> CoreData/CloudKit
```

- **Views** observe ViewModels via `@StateObject` / `@ObservedObject`
- **ViewModels** own presentation logic, expose `@Published` state
- **Repositories** abstract CoreData — one per aggregate root (Board, Card, Label)
- **PersistenceController** wraps `NSPersistentCloudKitContainer`
- **Services** handle cross-cutting concerns (auth, notifications, sync monitoring)

Dependency injection via initializers. No DI framework. Protocols on repositories and services for testability.

### Layer Diagram

```
SwiftUI Views
       |  @StateObject / @ObservedObject
ViewModels (BoardListVM, BoardVM, CardDetailVM, LabelManagementVM, NotificationSettingsVM, SettingsVM)
       |  calls
Repositories (BoardRepository, CardRepository, LabelRepository)
       |  NSManagedObjectContext
PersistenceController (NSPersistentCloudKitContainer)
       |  automatic
CloudKit (Private Database)
```

## Data Model

### Entities

**Board**
- `id: UUID` — non-optional, default generated
- `name: String` — non-optional
- `createdAt: Date` — non-optional
- `modifiedAt: Date` — non-optional
- `sortOrder: Int32` — non-optional, position in board list
- `colorHex: String` — optional, accent color

**Column**
- `id: UUID` — non-optional
- `name: String` — non-optional
- `createdAt: Date` — non-optional
- `modifiedAt: Date` — non-optional
- `sortOrder: Int32` — non-optional, position within board

**Card**
- `id: UUID` — non-optional
- `title: String` — non-optional
- `cardDescription: String` — optional (avoids NSObject reserved name)
- `createdAt: Date` — non-optional
- `modifiedAt: Date` — non-optional
- `dueDate: Date` — optional
- `sortOrder: Int32` — non-optional, position within column
- `isCompleted: Bool` — non-optional, default false

**Label**
- `id: UUID` — non-optional
- `name: String` — non-optional
- `colorHex: String` — non-optional, hex string like "#FF5733"
- `createdAt: Date` — non-optional

### Relationships

| From | To | Type | Delete Rule | Inverse |
|------|----|------|-------------|---------|
| Board.columns | Column | to-many | Cascade | Column.board |
| Column.cards | Card | to-many | Cascade | Card.column |
| Card.label | Label | to-one | Nullify | Label.cards |

### CloudKit Compatibility Constraints

1. No ordered relationships — use `sortOrder: Int32` with gap-based insertion
2. No unique constraints — UUIDs generated client-side, no DB enforcement
3. All non-optional attributes have defaults — CloudKit can deliver partial records
4. No transformable attributes — `colorHex` is a plain string
5. Cascade deletes on Board->Column and Column->Card; Nullify on Card->Label

### Ordering Strategy

Gap-based `sortOrder` to minimize CoreData objects dirtied per reorder:
- Initial items spaced by 1000 (0, 1000, 2000, ...)
- Insert between two items at midpoint (e.g., 1500)
- Re-normalize all siblings back to 1000-spacing when gap < 2

## UI Screens

### Screen List (12 screens)

1. **AuthView** — Sign in with Apple + skip option
2. **BoardListView** — Home screen, list of boards with accent color stripe
3. **BoardView** — Adaptive layout: single-column (iPhone portrait), multi-column (landscape/iPad/Mac)
4. **CardDetailView** — Sheet with title, description, column picker, label, due date, completed toggle
5. **NewBoardSheet** — Create/edit board (name, color)
6. **NewColumnSheet** — Create/edit column (name, inline or sheet)
7. **NewCardSheet** — Create card (title, optional fields)
8. **LabelManagementView** — Global label list with CRUD
9. **LabelPickerView** — Select label within card detail
10. **LabelEditorSheet** — Create/edit single label (name, color)
11. **NotificationSettingsView** — Toggle reminders, configure digest
12. **SettingsView** — Account, appearance, data management

### Adaptive Layout

- **iPhone portrait:** `TabView(.page)` for column swiping, shows one column at a time with "2 of 4" indicator and swipe hints
- **iPhone landscape:** `ScrollView(.horizontal)` + `LazyHStack` showing all columns
- **iPad / Mac:** `NavigationSplitView` with board list sidebar, full multi-column board view in detail
- Detection via `@Environment(\.horizontalSizeClass)` + `GeometryReader` for orientation

### Reusable Components

- `CardView` — card cell used in every layout
- `ColumnView` — vertical list of cards with column header
- `LabelBadge` — colored pill with label name
- `DueDateBadge` — relative date with color coding (green/yellow/red)
- `SyncStatusIndicator` — toolbar icon showing sync state
- `EmptyStateView` — reusable empty state for boards, columns, cards

### Navigation Structure

- `BoardListView` is the root
- `NavigationSplitView` on iPad/Mac, `NavigationStack` on iPhone
- Card detail, new/edit forms, label picker presented as `.sheet()` modals
- Settings and notification prefs from gear icon on board list

## Sync Architecture

### CloudKit Configuration

- `NSPersistentCloudKitContainer` with single persistent store
- Private database only (v1)
- Single auto-managed `CKRecordZone`
- No direct CKRecord or CKDatabase manipulation

### Sync Flow

1. Local write saves to background context, merges to viewContext immediately
2. Container batches and exports changes to CloudKit
3. Remote changes arrive via silent push, container imports and fires context save notifications
4. UI updates automatically through published ViewModel properties

### Conflict Resolution

Last-write-wins (server record wins) — built into `NSPersistentCloudKitContainer`. Acceptable for single-user multi-device sync. Field-level merge deferred to v2 with team collaboration.

### SyncMonitor

Observes `NSPersistentCloudKitContainer.eventChangedNotification`, publishes:
- `idle` — no active sync (small checkmark, fades after 3s)
- `syncing` — import/export in progress (animated circular arrow)
- `succeeded` — last sync completed (small checkmark, fades)
- `failed(Error)` — last sync failed (orange exclamation, tappable)
- `noAccount` — no iCloud account (subtle "offline" badge)
- `disabled` — user turned off sync (subtle "offline" badge)

### Offline Behavior

No special offline mode. CoreData is always the local source of truth. All CRUD works offline. Container catches up automatically when connectivity returns.

### CloudKit Gotchas

1. First sync can take 30-60s on new device — show progress indicator
2. No server-side filtering — entire private DB syncs (fine for personal use)
3. Rate limiting on rapid writes — container batches internally; bulk ops should batch saves
4. Schema migration is additive only — removing/renaming attributes requires careful migration
5. iCloud account required for sync only — app works fully offline without one

## Notifications

### Three Channels

**1. Due Date Reminders (Local)**
Scheduled via `UNUserNotificationCenter` when `dueDate` is set/changed:
- Day before due (9:00 AM) — toggleable
- Morning of due date (9:00 AM) — toggleable
- Day after if overdue (9:00 AM) — toggleable
- Identifier: `dueDate-{cardUUID}-{dayBefore|dayOf|overdue}`
- Cancelled when card deleted, completed, or due date changed

**2. Sync Changes (Silent Push)**
Built-in `NSPersistentCloudKitContainer` behavior. Silent push wakes app in background, container imports changes. No user-visible notification.

**3. Daily Digest (Local, Rescheduled on Foreground)**
Repeating `UNCalendarNotificationTrigger` at user-configured time (default 8:00 AM):
- Content (card counts) baked in at schedule time — rescheduled on each app foreground and after sync import to keep counts fresh
- Shows count of cards due today and overdue
- Suppressed (not scheduled) if zero cards due/overdue
- Tapping opens the app to the board list

### Notification Preferences

Stored in `UserDefaults` synced via `NSUbiquitousKeyValueStore`:
- `dueDateReminderDayBefore: Bool` (default: true)
- `dueDateReminderDayOf: Bool` (default: true)
- `dueDateReminderOverdue: Bool` (default: false)
- `dailyDigestEnabled: Bool` (default: true)
- `dailyDigestHour: Int` (default: 8)
- `dailyDigestMinute: Int` (default: 0)

### Permission Flow

Deferred until contextually relevant (first due date set or notification settings opened). If denied, show inline message with System Settings link.

### Post-Sync Reconciliation

`refreshAllReminders()` runs after CloudKit import — fetches all cards with due dates on a background context and diffs against currently scheduled notifications.

## Drag-and-Drop

### APIs

- `.draggable()` on `CardView` — exports card UUID as `Transferable` (plain string)
- `.dropDestination()` on `ColumnView` — accepts card UUIDs

### Drop Scenarios

1. **Reorder within column** — update `sortOrder` via gap-based insertion
2. **Move to different column** — update `card.column` relationship + new `sortOrder`
3. **Drop at end of column** — `sortOrder = lastCard.sortOrder + 1000`

### Platform Behavior

- iPhone portrait: within-column reorder only (drag up/down). Cross-column move via column picker in card detail.
- iPhone landscape / iPad / Mac: full cross-column drag-and-drop

### Debounce

`BoardViewModel` debounces saves by 0.3 seconds during drag operations to batch `sortOrder` changes before committing to CoreData.

## Authentication

### Sign in with Apple (Primary & Only)

Flow:
1. App launch checks Keychain for stored Apple ID credential
2. Found & valid -> skip auth, load boards
3. Not found -> show auth screen with "Sign in with Apple" and "Skip"
4. Success -> store user ID in Keychain, CloudKit identity auto-linked
5. Skip -> local-only mode (no sync, no push)

### AuthenticationService

- `signInWithApple() async throws -> String` (returns user ID)
- `checkCredentialState() async -> Bool`
- `signOut()`

### Credential Revocation

Listens for `ASAuthorizationAppleIDProvider.credentialRevokedNotification`. On revocation: sign out locally, disable sync, show auth screen. No data loss.

### Local-Only Mode

- Uses plain `NSPersistentContainer` instead of CloudKit variant
- All features work except sync and push
- Signing in later swaps container type and triggers full initial sync export

## Project Structure

```
FenixKanban/
  FenixKanban.xcodeproj
  FenixKanban/
    FenixKanbanApp.swift
    Core/
      Persistence/
        PersistenceController.swift
        FenixKanban.xcdatamodeld/
        NSManagedObject+Extensions.swift
      Repositories/
        BoardRepository.swift
        CardRepository.swift
        LabelRepository.swift
      Services/
        AuthenticationService.swift
        NotificationService.swift
        SyncMonitor.swift
    Features/
      Auth/
        AuthView.swift, AuthViewModel.swift
      BoardList/
        BoardListView.swift, BoardListViewModel.swift, BoardRowView.swift
      Board/
        BoardView.swift, BoardViewModel.swift, ColumnView.swift, NewColumnSheet.swift
      Card/
        CardView.swift, CardDetailView.swift, CardDetailViewModel.swift, NewCardSheet.swift
      Labels/
        LabelManagementView.swift, LabelManagementViewModel.swift, LabelPickerView.swift, LabelEditorSheet.swift
      Notifications/
        NotificationSettingsView.swift, NotificationSettingsViewModel.swift
      Settings/
        SettingsView.swift, SettingsViewModel.swift
    Components/
      LabelBadge.swift, DueDateBadge.swift, SyncStatusIndicator.swift, EmptyStateView.swift
    Extensions/
      Color+Hex.swift, Date+Relative.swift, View+AdaptiveLayout.swift
    Resources/
      Assets.xcassets/, FenixKanban.entitlements
    Preview Content/
      PreviewPersistence.swift
  FenixKanbanTests/
    Repositories/
      BoardRepositoryTests.swift, CardRepositoryTests.swift, LabelRepositoryTests.swift
    Services/
      NotificationServiceTests.swift, SyncMonitorTests.swift
    ViewModels/
      BoardListViewModelTests.swift, BoardViewModelTests.swift, CardDetailViewModelTests.swift
```

### Build Targets

1. **FenixKanban** — main app
2. **FenixKanbanTests** — unit tests

### Deployment Targets

- iOS 17.0+
- macOS 14.0+ (Sonoma)

## V2 Preparation (Not Built in V1)

Architecture supports these v2 additions without refactoring ViewModels or Views:
- `BoardRepository.shareBoard()` creates `CKShare` for team boards
- Second persistent store configuration for shared CloudKit database
- User/Team entities added to CoreData model
- Card gains optional `assignee` relationship
- Field-level conflict merge in repositories

## Implementation Order

1. CoreData stack & persistence controller
2. Data models & CloudKit schema
3. Authentication (Sign in with Apple)
4. Core board UI (board list, board view, card detail)
5. Drag-and-drop
6. Labels & due dates
7. Offline mode & CloudKit sync
8. Notifications (due date reminders, sync, digest)
9. Settings & polish
