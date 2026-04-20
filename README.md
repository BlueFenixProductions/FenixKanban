# FenixKanban

A native iOS Kanban board app with iCloud sync. Create boards, organize work into columns, and keep everything in sync across all your devices — automatically.

<!-- Screenshot -->
<!-- Add a screenshot here: docs/screenshot.png -->

## Features

- **Boards** — create and manage multiple Kanban boards
- **Columns** — customize workflow stages per board
- **Cards** — rich cards with due dates, labels, and notes
- **Drag-and-drop** — reorder cards and columns with a long press
- **iCloud sync** — automatic sync across all your devices via CloudKit
- **Dark mode** — full support for iOS light and dark appearance
- **Tip jar** — optional in-app purchase to support development

## Requirements

- iOS 26+
- Xcode 16+
- An Apple Developer account (for iCloud / CloudKit entitlements)

## Building

```bash
git clone https://github.com/BlueFenixProductions/FenixKanban.git
cd FenixKanban
```

Copy the xcconfig example and fill in your Team ID (find it at [developer.apple.com](https://developer.apple.com) under Membership):

```bash
cp Config/Development.xcconfig.example Config/Development.xcconfig
# edit Config/Development.xcconfig and set DEVELOPMENT_TEAM = <your 10-char Team ID>
```

Then either open `FenixKanban.xcodeproj` in Xcode directly, or regenerate the project first:

```bash
xcodegen generate
open FenixKanban.xcodeproj
```

## Architecture

FenixKanban follows **MVVM + Repository** with a clean layer separation:

| Layer | Technology |
|---|---|
| UI | SwiftUI |
| State | `@StateObject` / `@ObservedObject` view models |
| Data | Core Data (local) + CloudKit (remote) |
| Sync | `NSPersistentCloudKitContainer` via `PersistenceController` |

```
FenixKanban/
├── Core/
│   ├── Persistence/   # Core Data stack + CloudKit container
│   ├── Repositories/  # BoardRepository, CardRepository, LabelRepository
│   ├── Services/      # SyncMonitor, AuthenticationService, NotificationService
│   └── Plugins/       # BoardSyncProvider protocol + PluginRegistry
├── Features/          # One folder per screen (Board, Card, BoardList, …)
├── Components/        # Reusable SwiftUI views
└── Extensions/        # Swift / SwiftUI helpers
```

## Plugin Development

FenixKanban has a plugin system for connecting boards to external project-management services (GitHub Projects, Jira, Linear, etc.).

Implement [`BoardSyncProvider`](FenixKanban/Core/Plugins/BoardSyncProvider.swift) and register with `PluginRegistry`:

```swift
public protocol BoardSyncProvider {
    var providerName: String { get }   // e.g. "GitHub Projects"
    var iconName: String { get }       // SF Symbol name
    var isAuthenticated: Bool { get }

    func authenticate() async throws
    func signOut() async throws
    func fetchRemoteBoards() async throws -> [RemoteBoard]
    func sync(boardId: UUID, remoteProjectId: String) async throws -> SyncResult
    func lastSyncDate(for boardId: UUID) -> Date?
}
```

See [`PluginRegistry.swift`](FenixKanban/Core/Plugins/PluginRegistry.swift) for how providers are registered at app startup.

## Contributing

Pull requests are welcome. For major changes, open an issue first to discuss what you'd like to change.

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes
4. Push to the branch and open a pull request

## License

MIT — see [LICENSE](LICENSE) for details.
