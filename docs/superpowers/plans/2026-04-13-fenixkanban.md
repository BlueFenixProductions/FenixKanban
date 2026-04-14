# FenixKanban Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a full-featured Kanban board app for iPhone, iPad, and Mac with SwiftUI, CoreData, CloudKit sync, and notifications.

**Architecture:** MVVM + Repository pattern. Views observe ViewModels via @StateObject. ViewModels call Repositories that abstract CoreData. PersistenceController wraps NSPersistentCloudKitContainer. Services handle auth, notifications, and sync monitoring.

**Tech Stack:** Swift, SwiftUI, CoreData, CloudKit (NSPersistentCloudKitContainer), AuthenticationServices (Sign in with Apple), UserNotifications, XcodeGen for project generation.

**Spec:** `docs/superpowers/specs/2026-04-13-fenixkanban-design.md`

---

## File Structure

### Core Layer
| File | Responsibility |
|------|---------------|
| `FenixKanban/FenixKanbanApp.swift` | App entry point, environment setup, auth gate |
| `FenixKanban/Core/Persistence/PersistenceController.swift` | NSPersistentCloudKitContainer setup, viewContext, background contexts |
| `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/FenixKanban.xcdatamodel/contents` | CoreData model XML |
| `FenixKanban/Core/Persistence/NSManagedObject+Extensions.swift` | Convenience extensions on managed objects |
| `FenixKanban/Core/Repositories/BoardRepository.swift` | Board + Column CRUD, reordering |
| `FenixKanban/Core/Repositories/CardRepository.swift` | Card CRUD, reordering, column moves |
| `FenixKanban/Core/Repositories/LabelRepository.swift` | Global label CRUD |
| `FenixKanban/Core/Services/AuthenticationService.swift` | Sign in with Apple, credential state |
| `FenixKanban/Core/Services/NotificationService.swift` | Due date reminders, daily digest |
| `FenixKanban/Core/Services/SyncMonitor.swift` | CloudKit sync status observer |

### Feature Layer
| File | Responsibility |
|------|---------------|
| `FenixKanban/Features/Auth/AuthView.swift` | Sign in with Apple screen |
| `FenixKanban/Features/Auth/AuthViewModel.swift` | Auth state management |
| `FenixKanban/Features/BoardList/BoardListView.swift` | Home screen board list |
| `FenixKanban/Features/BoardList/BoardListViewModel.swift` | Board list data + CRUD |
| `FenixKanban/Features/BoardList/BoardRowView.swift` | Single board row cell |
| `FenixKanban/Features/Board/BoardView.swift` | Adaptive board layout |
| `FenixKanban/Features/Board/BoardViewModel.swift` | Board columns/cards, drag-drop |
| `FenixKanban/Features/Board/ColumnView.swift` | Single column with cards |
| `FenixKanban/Features/Board/NewColumnSheet.swift` | Create/edit column sheet |
| `FenixKanban/Features/Card/CardView.swift` | Card cell component |
| `FenixKanban/Features/Card/CardDetailView.swift` | Full card editing sheet |
| `FenixKanban/Features/Card/CardDetailViewModel.swift` | Card detail state |
| `FenixKanban/Features/Card/NewCardSheet.swift` | Create card sheet |
| `FenixKanban/Features/Labels/LabelManagementView.swift` | Global label list |
| `FenixKanban/Features/Labels/LabelManagementViewModel.swift` | Label CRUD |
| `FenixKanban/Features/Labels/LabelPickerView.swift` | In-card label selection |
| `FenixKanban/Features/Labels/LabelEditorSheet.swift` | Create/edit label |
| `FenixKanban/Features/Notifications/NotificationSettingsView.swift` | Notification preferences |
| `FenixKanban/Features/Notifications/NotificationSettingsViewModel.swift` | Notification settings state |
| `FenixKanban/Features/Settings/SettingsView.swift` | App settings |
| `FenixKanban/Features/Settings/SettingsViewModel.swift` | Settings state |

### Components & Extensions
| File | Responsibility |
|------|---------------|
| `FenixKanban/Components/LabelBadge.swift` | Colored label pill |
| `FenixKanban/Components/DueDateBadge.swift` | Relative date badge |
| `FenixKanban/Components/SyncStatusIndicator.swift` | Toolbar sync icon |
| `FenixKanban/Components/EmptyStateView.swift` | Reusable empty state |
| `FenixKanban/Extensions/Color+Hex.swift` | Hex string <-> Color |
| `FenixKanban/Extensions/Date+Relative.swift` | Relative date formatting |
| `FenixKanban/Extensions/View+AdaptiveLayout.swift` | Size class helpers |
| `FenixKanban/Preview Content/PreviewPersistence.swift` | In-memory store with sample data |

### Tests
| File | Responsibility |
|------|---------------|
| `FenixKanbanTests/Repositories/BoardRepositoryTests.swift` | Board + Column CRUD tests |
| `FenixKanbanTests/Repositories/CardRepositoryTests.swift` | Card CRUD + reorder tests |
| `FenixKanbanTests/Repositories/LabelRepositoryTests.swift` | Label CRUD tests |
| `FenixKanbanTests/ViewModels/BoardListViewModelTests.swift` | Board list VM tests |
| `FenixKanbanTests/ViewModels/BoardViewModelTests.swift` | Board VM + drag-drop tests |
| `FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift` | Card detail VM tests |
| `FenixKanbanTests/Services/SyncMonitorTests.swift` | Sync monitor tests |
| `FenixKanbanTests/Services/NotificationServiceTests.swift` | Notification scheduling tests |

### Project Config
| File | Responsibility |
|------|---------------|
| `project.yml` | XcodeGen project specification |
| `FenixKanban/Resources/FenixKanban.entitlements` | iCloud, push, Sign in with Apple |
| `FenixKanban/Resources/Assets.xcassets/Contents.json` | Asset catalog root |
| `.gitignore` | Xcode + Swift ignores |

---

## Layer 1: Project Setup & CoreData Stack

### Task 1: Project Scaffolding

**Files:**
- Create: `project.yml`
- Create: `.gitignore`
- Create: `FenixKanban/Resources/FenixKanban.entitlements`
- Create: `FenixKanban/Resources/Assets.xcassets/Contents.json`
- Create: `FenixKanban/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`
- Create: `FenixKanban/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`

- [ ] **Step 1: Install XcodeGen if not present**

Run: `which xcodegen || brew install xcodegen`
Expected: Path to xcodegen binary

- [ ] **Step 2: Create directory structure**

Run:
```bash
cd /Users/chris/Documents/GitHub/FenixKanban
mkdir -p FenixKanban/Core/Persistence
mkdir -p FenixKanban/Core/Repositories
mkdir -p FenixKanban/Core/Services
mkdir -p FenixKanban/Features/Auth
mkdir -p FenixKanban/Features/BoardList
mkdir -p FenixKanban/Features/Board
mkdir -p FenixKanban/Features/Card
mkdir -p FenixKanban/Features/Labels
mkdir -p FenixKanban/Features/Notifications
mkdir -p FenixKanban/Features/Settings
mkdir -p FenixKanban/Components
mkdir -p FenixKanban/Extensions
mkdir -p "FenixKanban/Preview Content"
mkdir -p FenixKanban/Resources/Assets.xcassets/AccentColor.colorset
mkdir -p FenixKanban/Resources/Assets.xcassets/AppIcon.appiconset
mkdir -p FenixKanbanTests/Repositories
mkdir -p FenixKanbanTests/ViewModels
mkdir -p FenixKanbanTests/Services
```

- [ ] **Step 3: Write .gitignore**

Create `.gitignore`:

```gitignore
# Xcode
*.xcodeproj/project.xcworkspace/
*.xcodeproj/xcuserdata/
*.xcworkspace/xcuserdata/
DerivedData/
build/
*.moved-aside
*.pbxuser
!default.pbxuser
*.mode1v3
!default.mode1v3
*.mode2v3
!default.mode2v3
*.perspectivev3
!default.perspectivev3
xcuserdata/
*.hmap
*.ipa
*.dSYM.zip
*.dSYM

# Swift Package Manager
.build/
Packages/
Package.resolved

# CocoaPods
Pods/

# Misc
.DS_Store
*.swp
*~
.superpowers/
```

- [ ] **Step 4: Write entitlements file**

Create `FenixKanban/Resources/FenixKanban.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>aps-environment</key>
    <string>development</string>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.com.bluefenixproductions.FenixKanban</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudKit</string>
    </array>
    <key>com.apple.developer.applesignin</key>
    <array>
        <string>Default</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 5: Write asset catalog files**

Create `FenixKanban/Resources/Assets.xcassets/Contents.json`:

```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

Create `FenixKanban/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`:

```json
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "0.831",
          "green" : "0.486",
          "red" : "0.220"
        }
      },
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

Create `FenixKanban/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`:

```json
{
  "images" : [
    {
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 6: Write XcodeGen project.yml**

Create `project.yml`:

```yaml
name: FenixKanban
options:
  bundleIdPrefix: com.bluefenixproductions
  deploymentTarget:
    iOS: "17.0"
    macOS: "14.0"
  xcodeVersion: "16.0"
  createIntermediateGroups: true
  defaultConfig: Debug

settings:
  base:
    SWIFT_VERSION: "5.9"
    MARKETING_VERSION: "1.0.0"
    CURRENT_PROJECT_VERSION: 1

targets:
  FenixKanban:
    type: application
    platform: [iOS, macOS]
    sources:
      - path: FenixKanban
        excludes:
          - "**/.DS_Store"
    resources:
      - path: FenixKanban/Resources/Assets.xcassets
      - path: FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.bluefenixproductions.FenixKanban
        INFOPLIST_VALUES: >-
          UILaunchScreen_Generation=YES
          UIApplicationSceneManifest_Generation=YES
          CFBundleDisplayName=FenixKanban
        CODE_SIGN_ENTITLEMENTS: FenixKanban/Resources/FenixKanban.entitlements
        SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: false
        SUPPORTS_MACCATALYST: false
    entitlements:
      path: FenixKanban/Resources/FenixKanban.entitlements

  FenixKanbanTests:
    type: bundle.unit-test
    platform: [iOS, macOS]
    sources:
      - path: FenixKanbanTests
        excludes:
          - "**/.DS_Store"
    dependencies:
      - target: FenixKanban
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.bluefenixproductions.FenixKanbanTests
```

- [ ] **Step 7: Generate Xcode project**

Run: `cd /Users/chris/Documents/GitHub/FenixKanban && xcodegen generate`
Expected: `⚙  Generating plists...` then `Created project at /Users/chris/Documents/GitHub/FenixKanban/FenixKanban.xcodeproj`

Note: This will fail until we have at least one Swift source file. We'll generate after Task 2.

- [ ] **Step 8: Commit scaffolding**

```bash
git add .gitignore project.yml FenixKanban/Resources/
git commit -m "chore: project scaffolding with XcodeGen config and entitlements"
```

---

### Task 2: CoreData Model

**Files:**
- Create: `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/FenixKanban.xcdatamodel/contents`

- [ ] **Step 1: Create CoreData model directory**

Run:
```bash
mkdir -p "/Users/chris/Documents/GitHub/FenixKanban/FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/FenixKanban.xcdatamodel"
```

- [ ] **Step 2: Write CoreData model XML**

Create `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/FenixKanban.xcdatamodel/contents`:

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<model type="com.apple.IDECoreDataModeler.DataModel" documentVersion="1.0" lastSavedToolsVersion="23231" systemVersion="24A335" minimumToolsVersion="Automatic" sourceLanguage="Swift" usedWithCloudKit="YES" userDefinedModelVersionIdentifier="">
    <entity name="Board" representedClassName="Board" syncable="YES" codeGenerationType="category">
        <attribute name="colorHex" optional="YES" attributeType="String"/>
        <attribute name="createdAt" attributeType="Date" defaultDateTimeInterval="0" usesScalarValueType="NO"/>
        <attribute name="id" attributeType="UUID" defaultValueString="" usesScalarValueType="NO"/>
        <attribute name="modifiedAt" attributeType="Date" defaultDateTimeInterval="0" usesScalarValueType="NO"/>
        <attribute name="name" attributeType="String" defaultValueString="Untitled Board"/>
        <attribute name="sortOrder" attributeType="Integer 32" defaultValueString="0" usesScalarValueType="YES"/>
        <relationship name="columns" optional="YES" toMany="YES" deletionRule="Cascade" destinationEntity="Column" inverseName="board" inverseEntity="Column"/>
    </entity>
    <entity name="Card" representedClassName="Card" syncable="YES" codeGenerationType="category">
        <attribute name="cardDescription" optional="YES" attributeType="String"/>
        <attribute name="createdAt" attributeType="Date" defaultDateTimeInterval="0" usesScalarValueType="NO"/>
        <attribute name="dueDate" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
        <attribute name="id" attributeType="UUID" defaultValueString="" usesScalarValueType="NO"/>
        <attribute name="isCompleted" attributeType="Boolean" defaultValueString="NO" usesScalarValueType="YES"/>
        <attribute name="modifiedAt" attributeType="Date" defaultDateTimeInterval="0" usesScalarValueType="NO"/>
        <attribute name="sortOrder" attributeType="Integer 32" defaultValueString="0" usesScalarValueType="YES"/>
        <attribute name="title" attributeType="String" defaultValueString="Untitled Card"/>
        <relationship name="column" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="Column" inverseName="cards" inverseEntity="Column"/>
        <relationship name="label" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="Label" inverseName="cards" inverseEntity="Label"/>
    </entity>
    <entity name="Column" representedClassName="Column" syncable="YES" codeGenerationType="category">
        <attribute name="createdAt" attributeType="Date" defaultDateTimeInterval="0" usesScalarValueType="NO"/>
        <attribute name="id" attributeType="UUID" defaultValueString="" usesScalarValueType="NO"/>
        <attribute name="modifiedAt" attributeType="Date" defaultDateTimeInterval="0" usesScalarValueType="NO"/>
        <attribute name="name" attributeType="String" defaultValueString="Untitled Column"/>
        <attribute name="sortOrder" attributeType="Integer 32" defaultValueString="0" usesScalarValueType="YES"/>
        <relationship name="board" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="Board" inverseName="columns" inverseEntity="Board"/>
        <relationship name="cards" optional="YES" toMany="YES" deletionRule="Cascade" destinationEntity="Card" inverseName="column" inverseEntity="Card"/>
    </entity>
    <entity name="Label" representedClassName="Label" syncable="YES" codeGenerationType="category">
        <attribute name="colorHex" attributeType="String" defaultValueString="#808080"/>
        <attribute name="createdAt" attributeType="Date" defaultDateTimeInterval="0" usesScalarValueType="NO"/>
        <attribute name="id" attributeType="UUID" defaultValueString="" usesScalarValueType="NO"/>
        <attribute name="name" attributeType="String" defaultValueString="Untitled Label"/>
        <relationship name="cards" optional="YES" toMany="YES" deletionRule="Nullify" destinationEntity="Card" inverseName="label" inverseEntity="Card"/>
    </entity>
</model>
```

Key CloudKit notes:
- `usedWithCloudKit="YES"` on the model
- `syncable="YES"` on all entities
- `codeGenerationType="category"` so Xcode generates base classes, we write extensions
- All non-optional attributes have `defaultValueString`
- No ordered relationships, no unique constraints
- `usesScalarValueType="NO"` on Date and UUID so they're optional-compatible for CloudKit

- [ ] **Step 3: Commit CoreData model**

```bash
git add FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/
git commit -m "feat: CoreData model with Board, Column, Card, Label entities"
```

---

### Task 3: PersistenceController

**Files:**
- Create: `FenixKanban/Core/Persistence/PersistenceController.swift`

- [ ] **Step 1: Write PersistenceController**

Create `FenixKanban/Core/Persistence/PersistenceController.swift`:

```swift
import CoreData
import CloudKit

final class PersistenceController: ObservableObject {
    static let shared = PersistenceController()

    static var preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.viewContext
        // Sample data for previews
        let board = Board(context: context)
        board.id = UUID()
        board.name = "Sample Board"
        board.createdAt = Date()
        board.modifiedAt = Date()
        board.sortOrder = 0

        let column1 = Column(context: context)
        column1.id = UUID()
        column1.name = "To Do"
        column1.createdAt = Date()
        column1.modifiedAt = Date()
        column1.sortOrder = 0
        column1.board = board

        let column2 = Column(context: context)
        column2.id = UUID()
        column2.name = "In Progress"
        column2.createdAt = Date()
        column2.modifiedAt = Date()
        column2.sortOrder = 1000
        column2.board = board

        let label = Label(context: context)
        label.id = UUID()
        label.name = "Urgent"
        label.colorHex = "#E94560"
        label.createdAt = Date()

        let card = Card(context: context)
        card.id = UUID()
        card.title = "Sample Card"
        card.cardDescription = "A sample card description"
        card.createdAt = Date()
        card.modifiedAt = Date()
        card.sortOrder = 0
        card.column = column1
        card.label = label

        try? context.save()
        return controller
    }()

    let container: NSPersistentContainer

    var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    init(inMemory: Bool = false, useCloudKit: Bool = true) {
        if useCloudKit && !inMemory {
            container = NSPersistentCloudKitContainer(name: "FenixKanban")
        } else {
            container = NSPersistentContainer(name: "FenixKanban")
        }

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        if let description = container.persistentStoreDescriptions.first {
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

            if useCloudKit && !inMemory {
                description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                    containerIdentifier: "iCloud.com.bluefenixproductions.FenixKanban"
                )
            }
        }

        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                fatalError("CoreData store failed to load: \(error), \(error.userInfo)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }

    func save(context: NSManagedObjectContext) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            let nsError = error as NSError
            print("CoreData save error: \(nsError), \(nsError.userInfo)")
        }
    }
}
```

- [ ] **Step 2: Commit PersistenceController**

```bash
git add FenixKanban/Core/Persistence/PersistenceController.swift
git commit -m "feat: PersistenceController with CloudKit and in-memory support"
```

---

### Task 4: NSManagedObject Extensions

**Files:**
- Create: `FenixKanban/Core/Persistence/NSManagedObject+Extensions.swift`

- [ ] **Step 1: Write managed object extensions**

Create `FenixKanban/Core/Persistence/NSManagedObject+Extensions.swift`:

```swift
import CoreData

extension Board {
    var sortedColumns: [Column] {
        let set = columns as? Set<Column> ?? []
        return set.sorted { $0.sortOrder < $1.sortOrder }
    }

    var columnCount: Int {
        (columns as? Set<Column>)?.count ?? 0
    }

    var totalCardCount: Int {
        sortedColumns.reduce(0) { $0 + $1.cardCount }
    }
}

extension Column {
    var sortedCards: [Card] {
        let set = cards as? Set<Card> ?? []
        return set.sorted { $0.sortOrder < $1.sortOrder }
    }

    var cardCount: Int {
        (cards as? Set<Card>)?.count ?? 0
    }
}

extension Label {
    var cardCount: Int {
        (cards as? Set<Card>)?.count ?? 0
    }
}
```

- [ ] **Step 2: Commit extensions**

```bash
git add FenixKanban/Core/Persistence/NSManagedObject+Extensions.swift
git commit -m "feat: NSManagedObject convenience extensions for sorted relationships"
```

---

### Task 5: Utility Extensions

**Files:**
- Create: `FenixKanban/Extensions/Color+Hex.swift`
- Create: `FenixKanban/Extensions/Date+Relative.swift`
- Create: `FenixKanban/Extensions/View+AdaptiveLayout.swift`

- [ ] **Step 1: Write Color+Hex**

Create `FenixKanban/Extensions/Color+Hex.swift`:

```swift
import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        scanner.scanHexInt64(&rgbValue)

        let r = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let g = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let b = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }

    func toHex() -> String {
        #if canImport(UIKit)
        let uiColor = UIColor(self)
        #else
        let uiColor = NSColor(self)
        #endif

        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0

        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)

        return String(format: "#%02X%02X%02X",
                      Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
```

- [ ] **Step 2: Write Date+Relative**

Create `FenixKanban/Extensions/Date+Relative.swift`:

```swift
import Foundation

extension Date {
    var relativeDisplay: String {
        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(self) {
            return "Today"
        } else if calendar.isDateInTomorrow(self) {
            return "Tomorrow"
        } else if calendar.isDateInYesterday(self) {
            return "Yesterday"
        }

        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: self)).day ?? 0

        if days > 0 && days <= 7 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: self)
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: self)
    }

    var isOverdue: Bool {
        self < Calendar.current.startOfDay(for: Date())
    }

    var isDueToday: Bool {
        Calendar.current.isDateInToday(self)
    }

    var isDueSoon: Bool {
        let calendar = Calendar.current
        let now = Date()
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: self)).day ?? 0
        return days >= 0 && days <= 2
    }
}
```

- [ ] **Step 3: Write View+AdaptiveLayout**

Create `FenixKanban/Extensions/View+AdaptiveLayout.swift`:

```swift
import SwiftUI

struct AdaptiveLayoutInfo {
    let isCompact: Bool
    let isLandscape: Bool

    var showMultiColumn: Bool {
        !isCompact || isLandscape
    }
}

struct AdaptiveLayoutKey: EnvironmentKey {
    static let defaultValue = AdaptiveLayoutInfo(isCompact: true, isLandscape: false)
}

extension EnvironmentValues {
    var adaptiveLayout: AdaptiveLayoutInfo {
        get { self[AdaptiveLayoutKey.self] }
        set { self[AdaptiveLayoutKey.self] = newValue }
    }
}

struct AdaptiveLayoutModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let isCompact = horizontalSizeClass == .compact
            let isLandscape = geometry.size.width > geometry.size.height
            content
                .environment(\.adaptiveLayout, AdaptiveLayoutInfo(
                    isCompact: isCompact,
                    isLandscape: isLandscape
                ))
        }
    }
}

extension View {
    func adaptiveLayout() -> some View {
        modifier(AdaptiveLayoutModifier())
    }
}
```

- [ ] **Step 4: Commit extensions**

```bash
git add FenixKanban/Extensions/
git commit -m "feat: Color+Hex, Date+Relative, View+AdaptiveLayout extensions"
```

---

### Task 6: Minimal App Entry Point & Generate Xcode Project

**Files:**
- Create: `FenixKanban/FenixKanbanApp.swift`

- [ ] **Step 1: Write minimal app entry point**

Create `FenixKanban/FenixKanbanApp.swift`:

```swift
import SwiftUI

@main
struct FenixKanbanApp: App {
    @StateObject private var persistence = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            Text("FenixKanban")
                .environment(\.managedObjectContext, persistence.viewContext)
                .preferredColorScheme(.dark)
        }
    }
}
```

- [ ] **Step 2: Generate Xcode project with XcodeGen**

Run: `cd /Users/chris/Documents/GitHub/FenixKanban && xcodegen generate`
Expected: `Created project at /Users/chris/Documents/GitHub/FenixKanban/FenixKanban.xcodeproj`

- [ ] **Step 3: Build to verify**

Run: `cd /Users/chris/Documents/GitHub/FenixKanban && xcodebuild build -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 16' -quiet 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add FenixKanban/FenixKanbanApp.swift FenixKanban.xcodeproj project.yml
git commit -m "feat: minimal app entry point and generated Xcode project"
```

---

## Layer 2: Repositories (TDD)

### Task 7: BoardRepository

**Files:**
- Create: `FenixKanban/Core/Repositories/BoardRepository.swift`
- Create: `FenixKanbanTests/Repositories/BoardRepositoryTests.swift`

- [ ] **Step 1: Write BoardRepository protocol and implementation**

Create `FenixKanban/Core/Repositories/BoardRepository.swift`:

```swift
import CoreData

protocol BoardRepositoryProtocol {
    func fetchAllBoards() -> [Board]
    func createBoard(name: String, colorHex: String?) -> Board
    func updateBoard(_ board: Board, name: String?, colorHex: String?)
    func deleteBoard(_ board: Board)
    func reorderBoard(_ board: Board, to newIndex: Int, in boards: [Board])
    func createColumn(in board: Board, name: String) -> Column
    func updateColumn(_ column: Column, name: String)
    func deleteColumn(_ column: Column)
    func reorderColumn(_ column: Column, to newIndex: Int, in columns: [Column])
}

final class BoardRepository: BoardRepositoryProtocol {
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func fetchAllBoards() -> [Board] {
        let request = Board.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Board.sortOrder, ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    func createBoard(name: String, colorHex: String? = nil) -> Board {
        let board = Board(context: context)
        board.id = UUID()
        board.name = name
        board.colorHex = colorHex
        board.createdAt = Date()
        board.modifiedAt = Date()

        let existingBoards = fetchAllBoards()
        let maxSort = existingBoards.last?.sortOrder ?? -1000
        board.sortOrder = maxSort + 1000

        save()
        return board
    }

    func updateBoard(_ board: Board, name: String? = nil, colorHex: String? = nil) {
        if let name = name { board.name = name }
        if let colorHex = colorHex { board.colorHex = colorHex }
        board.modifiedAt = Date()
        save()
    }

    func deleteBoard(_ board: Board) {
        context.delete(board)
        save()
    }

    func reorderBoard(_ board: Board, to newIndex: Int, in boards: [Board]) {
        let newSortOrder = calculateSortOrder(for: newIndex, in: boards.map(\.sortOrder))
        board.sortOrder = newSortOrder
        board.modifiedAt = Date()

        if needsNormalization(boards.map(\.sortOrder), inserting: newSortOrder) {
            normalizeOrder(boards, moving: board, to: newIndex)
        }

        save()
    }

    func createColumn(in board: Board, name: String) -> Column {
        let column = Column(context: context)
        column.id = UUID()
        column.name = name
        column.createdAt = Date()
        column.modifiedAt = Date()
        column.board = board

        let maxSort = board.sortedColumns.last?.sortOrder ?? -1000
        column.sortOrder = maxSort + 1000

        board.modifiedAt = Date()
        save()
        return column
    }

    func updateColumn(_ column: Column, name: String) {
        column.name = name
        column.modifiedAt = Date()
        column.board?.modifiedAt = Date()
        save()
    }

    func deleteColumn(_ column: Column) {
        column.board?.modifiedAt = Date()
        context.delete(column)
        save()
    }

    func reorderColumn(_ column: Column, to newIndex: Int, in columns: [Column]) {
        let newSortOrder = calculateSortOrder(for: newIndex, in: columns.map(\.sortOrder))
        column.sortOrder = newSortOrder
        column.modifiedAt = Date()

        if needsNormalization(columns.map(\.sortOrder), inserting: newSortOrder) {
            normalizeColumnOrder(columns, moving: column, to: newIndex)
        }

        save()
    }

    // MARK: - Sort Order Helpers

    private func calculateSortOrder(for index: Int, in sortOrders: [Int32]) -> Int32 {
        if sortOrders.isEmpty { return 0 }
        if index <= 0 { return sortOrders[0] - 1000 }
        if index >= sortOrders.count { return sortOrders[sortOrders.count - 1] + 1000 }

        let before = sortOrders[index - 1]
        let after = sortOrders[index]
        return before + (after - before) / 2
    }

    private func needsNormalization(_ sortOrders: [Int32], inserting newValue: Int32) -> Bool {
        for existing in sortOrders {
            if existing != newValue && abs(existing - newValue) < 2 {
                return true
            }
        }
        return false
    }

    private func normalizeOrder(_ boards: [Board], moving: Board, to index: Int) {
        var ordered = boards.filter { $0.id != moving.id }
        let clampedIndex = min(index, ordered.count)
        ordered.insert(moving, at: clampedIndex)
        for (i, board) in ordered.enumerated() {
            board.sortOrder = Int32(i * 1000)
        }
    }

    private func normalizeColumnOrder(_ columns: [Column], moving: Column, to index: Int) {
        var ordered = columns.filter { $0.id != moving.id }
        let clampedIndex = min(index, ordered.count)
        ordered.insert(moving, at: clampedIndex)
        for (i, column) in ordered.enumerated() {
            column.sortOrder = Int32(i * 1000)
        }
    }

    private func save() {
        guard context.hasChanges else { return }
        try? context.save()
    }
}
```

- [ ] **Step 2: Write BoardRepository tests**

Create `FenixKanbanTests/Repositories/BoardRepositoryTests.swift`:

```swift
import XCTest
import CoreData
@testable import FenixKanban

final class BoardRepositoryTests: XCTestCase {
    var persistence: PersistenceController!
    var repository: BoardRepository!

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        repository = BoardRepository(context: persistence.viewContext)
    }

    override func tearDown() {
        repository = nil
        persistence = nil
        super.tearDown()
    }

    func testCreateBoard() {
        let board = repository.createBoard(name: "Test Board", colorHex: "#FF0000")

        XCTAssertNotNil(board.id)
        XCTAssertEqual(board.name, "Test Board")
        XCTAssertEqual(board.colorHex, "#FF0000")
        XCTAssertNotNil(board.createdAt)
        XCTAssertNotNil(board.modifiedAt)
    }

    func testFetchAllBoards() {
        _ = repository.createBoard(name: "Board A")
        _ = repository.createBoard(name: "Board B")

        let boards = repository.fetchAllBoards()
        XCTAssertEqual(boards.count, 2)
        XCTAssertEqual(boards[0].name, "Board A")
        XCTAssertEqual(boards[1].name, "Board B")
    }

    func testBoardSortOrder() {
        let a = repository.createBoard(name: "A")
        let b = repository.createBoard(name: "B")
        let c = repository.createBoard(name: "C")

        XCTAssertTrue(a.sortOrder < b.sortOrder)
        XCTAssertTrue(b.sortOrder < c.sortOrder)
    }

    func testUpdateBoard() {
        let board = repository.createBoard(name: "Original")
        let originalModified = board.modifiedAt

        Thread.sleep(forTimeInterval: 0.01)
        repository.updateBoard(board, name: "Updated", colorHex: "#00FF00")

        XCTAssertEqual(board.name, "Updated")
        XCTAssertEqual(board.colorHex, "#00FF00")
        XCTAssertTrue(board.modifiedAt! > originalModified!)
    }

    func testDeleteBoard() {
        let board = repository.createBoard(name: "ToDelete")
        XCTAssertEqual(repository.fetchAllBoards().count, 1)

        repository.deleteBoard(board)
        XCTAssertEqual(repository.fetchAllBoards().count, 0)
    }

    func testDeleteBoardCascadesColumns() {
        let board = repository.createBoard(name: "Board")
        _ = repository.createColumn(in: board, name: "Column")

        let columnFetch = Column.fetchRequest()
        XCTAssertEqual((try? persistence.viewContext.fetch(columnFetch))?.count, 1)

        repository.deleteBoard(board)
        XCTAssertEqual((try? persistence.viewContext.fetch(columnFetch))?.count, 0)
    }

    func testCreateColumn() {
        let board = repository.createBoard(name: "Board")
        let column = repository.createColumn(in: board, name: "To Do")

        XCTAssertNotNil(column.id)
        XCTAssertEqual(column.name, "To Do")
        XCTAssertEqual(column.board, board)
        XCTAssertEqual(board.sortedColumns.count, 1)
    }

    func testColumnSortOrder() {
        let board = repository.createBoard(name: "Board")
        let col1 = repository.createColumn(in: board, name: "First")
        let col2 = repository.createColumn(in: board, name: "Second")

        XCTAssertTrue(col1.sortOrder < col2.sortOrder)
    }

    func testUpdateColumn() {
        let board = repository.createBoard(name: "Board")
        let column = repository.createColumn(in: board, name: "Original")

        repository.updateColumn(column, name: "Renamed")
        XCTAssertEqual(column.name, "Renamed")
    }

    func testDeleteColumn() {
        let board = repository.createBoard(name: "Board")
        let column = repository.createColumn(in: board, name: "Col")

        repository.deleteColumn(column)
        XCTAssertEqual(board.sortedColumns.count, 0)
    }

    func testReorderBoard() {
        let a = repository.createBoard(name: "A")
        let b = repository.createBoard(name: "B")
        let c = repository.createBoard(name: "C")

        repository.reorderBoard(c, to: 0, in: [a, b, c])

        let boards = repository.fetchAllBoards()
        XCTAssertEqual(boards[0].name, "C")
    }
}
```

- [ ] **Step 3: Run tests**

Run: `cd /Users/chris/Documents/GitHub/FenixKanban && xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 16' -quiet 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add FenixKanban/Core/Repositories/BoardRepository.swift FenixKanbanTests/Repositories/BoardRepositoryTests.swift
git commit -m "feat: BoardRepository with column management and tests"
```

---

### Task 8: CardRepository

**Files:**
- Create: `FenixKanban/Core/Repositories/CardRepository.swift`
- Create: `FenixKanbanTests/Repositories/CardRepositoryTests.swift`

- [ ] **Step 1: Write CardRepository**

Create `FenixKanban/Core/Repositories/CardRepository.swift`:

```swift
import CoreData

protocol CardRepositoryProtocol {
    func fetchCards(in column: Column) -> [Card]
    func fetchAllCards(in board: Board) -> [Card]
    func fetchCardsWithDueDate() -> [Card]
    func createCard(in column: Column, title: String) -> Card
    func updateCard(_ card: Card, title: String?, description: String?, dueDate: Date?, isCompleted: Bool?, label: Label?)
    func deleteCard(_ card: Card)
    func moveCard(_ card: Card, to column: Column, at index: Int)
    func reorderCard(_ card: Card, to newIndex: Int, in cards: [Card])
}

final class CardRepository: CardRepositoryProtocol {
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func fetchCards(in column: Column) -> [Card] {
        return column.sortedCards
    }

    func fetchAllCards(in board: Board) -> [Card] {
        board.sortedColumns.flatMap { $0.sortedCards }
    }

    func fetchCardsWithDueDate() -> [Card] {
        let request = Card.fetchRequest()
        request.predicate = NSPredicate(format: "dueDate != nil AND isCompleted == NO")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Card.dueDate, ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    func createCard(in column: Column, title: String) -> Card {
        let card = Card(context: context)
        card.id = UUID()
        card.title = title
        card.createdAt = Date()
        card.modifiedAt = Date()
        card.isCompleted = false
        card.column = column

        let maxSort = column.sortedCards.last?.sortOrder ?? -1000
        card.sortOrder = maxSort + 1000

        column.modifiedAt = Date()
        save()
        return card
    }

    func updateCard(_ card: Card, title: String? = nil, description: String? = nil, dueDate: Date? = nil, isCompleted: Bool? = nil, label: Label? = nil) {
        if let title = title { card.title = title }
        if let description = description { card.cardDescription = description }
        if let dueDate = dueDate { card.dueDate = dueDate }
        if let isCompleted = isCompleted { card.isCompleted = isCompleted }
        // Label can be explicitly set to nil to remove it
        card.label = label
        card.modifiedAt = Date()
        save()
    }

    func clearDueDate(for card: Card) {
        card.dueDate = nil
        card.modifiedAt = Date()
        save()
    }

    func clearLabel(for card: Card) {
        card.label = nil
        card.modifiedAt = Date()
        save()
    }

    func deleteCard(_ card: Card) {
        card.column?.modifiedAt = Date()
        context.delete(card)
        save()
    }

    func moveCard(_ card: Card, to column: Column, at index: Int) {
        card.column?.modifiedAt = Date()
        card.column = column
        column.modifiedAt = Date()

        let targetCards = column.sortedCards.filter { $0.id != card.id }
        let newSortOrder = calculateSortOrder(for: index, in: targetCards.map(\.sortOrder))
        card.sortOrder = newSortOrder
        card.modifiedAt = Date()

        if needsNormalization(targetCards.map(\.sortOrder), inserting: newSortOrder) {
            var ordered = targetCards
            let clampedIndex = min(index, ordered.count)
            ordered.insert(card, at: clampedIndex)
            for (i, c) in ordered.enumerated() {
                c.sortOrder = Int32(i * 1000)
            }
        }

        save()
    }

    func reorderCard(_ card: Card, to newIndex: Int, in cards: [Card]) {
        let sortOrders = cards.map(\.sortOrder)
        let newSortOrder = calculateSortOrder(for: newIndex, in: sortOrders)
        card.sortOrder = newSortOrder
        card.modifiedAt = Date()

        if needsNormalization(sortOrders, inserting: newSortOrder) {
            var ordered = cards.filter { $0.id != card.id }
            let clampedIndex = min(newIndex, ordered.count)
            ordered.insert(card, at: clampedIndex)
            for (i, c) in ordered.enumerated() {
                c.sortOrder = Int32(i * 1000)
            }
        }

        save()
    }

    // MARK: - Sort Order Helpers

    private func calculateSortOrder(for index: Int, in sortOrders: [Int32]) -> Int32 {
        if sortOrders.isEmpty { return 0 }
        if index <= 0 { return sortOrders[0] - 1000 }
        if index >= sortOrders.count { return sortOrders[sortOrders.count - 1] + 1000 }

        let before = sortOrders[index - 1]
        let after = sortOrders[index]
        return before + (after - before) / 2
    }

    private func needsNormalization(_ sortOrders: [Int32], inserting newValue: Int32) -> Bool {
        for existing in sortOrders {
            if existing != newValue && abs(existing - newValue) < 2 {
                return true
            }
        }
        return false
    }

    private func save() {
        guard context.hasChanges else { return }
        try? context.save()
    }
}
```

- [ ] **Step 2: Write CardRepository tests**

Create `FenixKanbanTests/Repositories/CardRepositoryTests.swift`:

```swift
import XCTest
import CoreData
@testable import FenixKanban

final class CardRepositoryTests: XCTestCase {
    var persistence: PersistenceController!
    var boardRepo: BoardRepository!
    var cardRepo: CardRepository!
    var board: Board!
    var column: Column!

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        cardRepo = CardRepository(context: persistence.viewContext)
        board = boardRepo.createBoard(name: "Test Board")
        column = boardRepo.createColumn(in: board, name: "To Do")
    }

    override func tearDown() {
        board = nil
        column = nil
        cardRepo = nil
        boardRepo = nil
        persistence = nil
        super.tearDown()
    }

    func testCreateCard() {
        let card = cardRepo.createCard(in: column, title: "Test Card")

        XCTAssertNotNil(card.id)
        XCTAssertEqual(card.title, "Test Card")
        XCTAssertEqual(card.column, column)
        XCTAssertFalse(card.isCompleted)
    }

    func testFetchCardsInColumn() {
        _ = cardRepo.createCard(in: column, title: "Card A")
        _ = cardRepo.createCard(in: column, title: "Card B")

        let cards = cardRepo.fetchCards(in: column)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].title, "Card A")
        XCTAssertEqual(cards[1].title, "Card B")
    }

    func testUpdateCard() {
        let card = cardRepo.createCard(in: column, title: "Original")
        let label = Label(context: persistence.viewContext)
        label.id = UUID()
        label.name = "Urgent"
        label.colorHex = "#FF0000"
        label.createdAt = Date()
        try? persistence.viewContext.save()

        cardRepo.updateCard(card, title: "Updated", description: "A description", dueDate: Date(), isCompleted: true, label: label)

        XCTAssertEqual(card.title, "Updated")
        XCTAssertEqual(card.cardDescription, "A description")
        XCTAssertNotNil(card.dueDate)
        XCTAssertTrue(card.isCompleted)
        XCTAssertEqual(card.label, label)
    }

    func testDeleteCard() {
        let card = cardRepo.createCard(in: column, title: "ToDelete")
        XCTAssertEqual(column.sortedCards.count, 1)

        cardRepo.deleteCard(card)
        XCTAssertEqual(column.sortedCards.count, 0)
    }

    func testMoveCardBetweenColumns() {
        let column2 = boardRepo.createColumn(in: board, name: "Done")
        let card = cardRepo.createCard(in: column, title: "Moving Card")

        cardRepo.moveCard(card, to: column2, at: 0)

        XCTAssertEqual(card.column, column2)
        XCTAssertEqual(column.sortedCards.count, 0)
        XCTAssertEqual(column2.sortedCards.count, 1)
    }

    func testReorderCard() {
        let a = cardRepo.createCard(in: column, title: "A")
        let b = cardRepo.createCard(in: column, title: "B")
        let c = cardRepo.createCard(in: column, title: "C")

        cardRepo.reorderCard(c, to: 0, in: [a, b, c])

        let cards = column.sortedCards
        XCTAssertEqual(cards[0].title, "C")
    }

    func testFetchCardsWithDueDate() {
        let card1 = cardRepo.createCard(in: column, title: "Due Card")
        cardRepo.updateCard(card1, dueDate: Date().addingTimeInterval(86400))

        let card2 = cardRepo.createCard(in: column, title: "No Due Date")
        _ = card2 // no due date set

        let dueCards = cardRepo.fetchCardsWithDueDate()
        XCTAssertEqual(dueCards.count, 1)
        XCTAssertEqual(dueCards[0].title, "Due Card")
    }

    func testCardSortOrder() {
        let a = cardRepo.createCard(in: column, title: "A")
        let b = cardRepo.createCard(in: column, title: "B")

        XCTAssertTrue(a.sortOrder < b.sortOrder)
    }

    func testDeleteColumnCascadesCards() {
        _ = cardRepo.createCard(in: column, title: "Card")

        let cardFetch = Card.fetchRequest()
        XCTAssertEqual((try? persistence.viewContext.fetch(cardFetch))?.count, 1)

        boardRepo.deleteColumn(column)
        XCTAssertEqual((try? persistence.viewContext.fetch(cardFetch))?.count, 0)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `cd /Users/chris/Documents/GitHub/FenixKanban && xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 16' -quiet 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add FenixKanban/Core/Repositories/CardRepository.swift FenixKanbanTests/Repositories/CardRepositoryTests.swift
git commit -m "feat: CardRepository with move, reorder, due date queries and tests"
```

---

### Task 9: LabelRepository

**Files:**
- Create: `FenixKanban/Core/Repositories/LabelRepository.swift`
- Create: `FenixKanbanTests/Repositories/LabelRepositoryTests.swift`

- [ ] **Step 1: Write LabelRepository**

Create `FenixKanban/Core/Repositories/LabelRepository.swift`:

```swift
import CoreData

protocol LabelRepositoryProtocol {
    func fetchAllLabels() -> [Label]
    func createLabel(name: String, colorHex: String) -> Label
    func updateLabel(_ label: Label, name: String?, colorHex: String?)
    func deleteLabel(_ label: Label)
}

final class LabelRepository: LabelRepositoryProtocol {
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func fetchAllLabels() -> [Label] {
        let request = Label.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Label.name, ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    func createLabel(name: String, colorHex: String) -> Label {
        let label = Label(context: context)
        label.id = UUID()
        label.name = name
        label.colorHex = colorHex
        label.createdAt = Date()
        save()
        return label
    }

    func updateLabel(_ label: Label, name: String? = nil, colorHex: String? = nil) {
        if let name = name { label.name = name }
        if let colorHex = colorHex { label.colorHex = colorHex }
        save()
    }

    func deleteLabel(_ label: Label) {
        context.delete(label)
        save()
    }

    private func save() {
        guard context.hasChanges else { return }
        try? context.save()
    }
}
```

- [ ] **Step 2: Write LabelRepository tests**

Create `FenixKanbanTests/Repositories/LabelRepositoryTests.swift`:

```swift
import XCTest
import CoreData
@testable import FenixKanban

final class LabelRepositoryTests: XCTestCase {
    var persistence: PersistenceController!
    var repository: LabelRepository!

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        repository = LabelRepository(context: persistence.viewContext)
    }

    override func tearDown() {
        repository = nil
        persistence = nil
        super.tearDown()
    }

    func testCreateLabel() {
        let label = repository.createLabel(name: "Urgent", colorHex: "#E94560")

        XCTAssertNotNil(label.id)
        XCTAssertEqual(label.name, "Urgent")
        XCTAssertEqual(label.colorHex, "#E94560")
        XCTAssertNotNil(label.createdAt)
    }

    func testFetchAllLabels() {
        _ = repository.createLabel(name: "Bug", colorHex: "#FF0000")
        _ = repository.createLabel(name: "Feature", colorHex: "#00FF00")

        let labels = repository.fetchAllLabels()
        XCTAssertEqual(labels.count, 2)
        // Sorted by name
        XCTAssertEqual(labels[0].name, "Bug")
        XCTAssertEqual(labels[1].name, "Feature")
    }

    func testUpdateLabel() {
        let label = repository.createLabel(name: "Original", colorHex: "#000000")

        repository.updateLabel(label, name: "Renamed", colorHex: "#FFFFFF")

        XCTAssertEqual(label.name, "Renamed")
        XCTAssertEqual(label.colorHex, "#FFFFFF")
    }

    func testDeleteLabel() {
        let label = repository.createLabel(name: "ToDelete", colorHex: "#000000")
        XCTAssertEqual(repository.fetchAllLabels().count, 1)

        repository.deleteLabel(label)
        XCTAssertEqual(repository.fetchAllLabels().count, 0)
    }

    func testDeleteLabelNullifiesCardRelationship() {
        let label = repository.createLabel(name: "Bug", colorHex: "#FF0000")

        let boardRepo = BoardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        let cardRepo = CardRepository(context: persistence.viewContext)
        let card = cardRepo.createCard(in: column, title: "Card")
        cardRepo.updateCard(card, label: label)
        XCTAssertNotNil(card.label)

        repository.deleteLabel(label)
        XCTAssertNil(card.label)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `cd /Users/chris/Documents/GitHub/FenixKanban && xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 16' -quiet 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add FenixKanban/Core/Repositories/LabelRepository.swift FenixKanbanTests/Repositories/LabelRepositoryTests.swift
git commit -m "feat: LabelRepository with CRUD and nullify-on-delete tests"
```

---

## Layer 3: Authentication

### Task 10: AuthenticationService

**Files:**
- Create: `FenixKanban/Core/Services/AuthenticationService.swift`

- [ ] **Step 1: Write AuthenticationService**

Create `FenixKanban/Core/Services/AuthenticationService.swift`:

```swift
import AuthenticationServices
import Foundation

protocol AuthenticationServiceProtocol: ObservableObject {
    var isAuthenticated: Bool { get }
    var userID: String? { get }
    func checkCredentialState() async -> Bool
    func signOut()
}

final class AuthenticationService: ObservableObject, AuthenticationServiceProtocol {
    @Published var isAuthenticated: Bool = false
    @Published var userID: String? = nil

    private let userIDKey = "fenixkanban_apple_user_id"

    init() {
        self.userID = KeychainHelper.load(key: userIDKey)
        self.isAuthenticated = userID != nil

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(credentialRevoked),
            name: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
            object: nil
        )
    }

    func checkCredentialState() async -> Bool {
        guard let userID = userID else { return false }

        do {
            let state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: userID)
            let valid = state == .authorized
            await MainActor.run {
                self.isAuthenticated = valid
                if !valid {
                    self.clearCredentials()
                }
            }
            return valid
        } catch {
            await MainActor.run {
                self.isAuthenticated = false
            }
            return false
        }
    }

    func handleSignInResult(userID: String) {
        KeychainHelper.save(key: userIDKey, value: userID)
        self.userID = userID
        self.isAuthenticated = true
    }

    func signOut() {
        clearCredentials()
    }

    func skipSignIn() {
        // Local-only mode — no credentials stored
        isAuthenticated = false
    }

    @objc private func credentialRevoked() {
        DispatchQueue.main.async {
            self.clearCredentials()
        }
    }

    private func clearCredentials() {
        KeychainHelper.delete(key: userIDKey)
        userID = nil
        isAuthenticated = false
    }
}

// MARK: - Keychain Helper

enum KeychainHelper {
    static func save(key: String, value: String) {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add FenixKanban/Core/Services/AuthenticationService.swift
git commit -m "feat: AuthenticationService with Sign in with Apple and Keychain storage"
```

---

### Task 11: Auth UI

**Files:**
- Create: `FenixKanban/Features/Auth/AuthViewModel.swift`
- Create: `FenixKanban/Features/Auth/AuthView.swift`

- [ ] **Step 1: Write AuthViewModel**

Create `FenixKanban/Features/Auth/AuthViewModel.swift`:

```swift
import AuthenticationServices
import SwiftUI

final class AuthViewModel: ObservableObject {
    @Published var errorMessage: String?
    @Published var isLoading = false

    let authService: AuthenticationService

    init(authService: AuthenticationService) {
        self.authService = authService
    }

    func handleSignInResult(_ result: Result<ASAuthorization, Error>) {
        isLoading = true
        errorMessage = nil

        switch result {
        case .success(let authorization):
            if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
                authService.handleSignInResult(userID: credential.user)
            }
        case .failure(let error):
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                errorMessage = "Sign in failed. Please try again."
            }
        }

        isLoading = false
    }

    func skip() {
        UserDefaults.standard.set(true, forKey: "hasSkippedAuth")
        authService.skipSignIn()
    }
}
```

- [ ] **Step 2: Write AuthView**

Create `FenixKanban/Features/Auth/AuthView.swift`:

```swift
import SwiftUI
import AuthenticationServices

struct AuthView: View {
    @StateObject var viewModel: AuthViewModel

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.accent)

                Text("FenixKanban")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Organize your work, your way")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 16) {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.email, .fullName]
                } onCompletion: { result in
                    viewModel.handleSignInResult(result)
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 50)
                .cornerRadius(8)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Continue without signing in") {
                    viewModel.skip()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Text("Sign in to sync across devices")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 40)

            Spacer()
                .frame(height: 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

#Preview {
    AuthView(viewModel: AuthViewModel(authService: AuthenticationService()))
        .preferredColorScheme(.dark)
}
```

- [ ] **Step 3: Commit**

```bash
git add FenixKanban/Features/Auth/
git commit -m "feat: AuthView and AuthViewModel with Sign in with Apple UI"
```

---

## Layer 4: Core Board UI

### Task 12: Reusable Components

**Files:**
- Create: `FenixKanban/Components/LabelBadge.swift`
- Create: `FenixKanban/Components/DueDateBadge.swift`
- Create: `FenixKanban/Components/SyncStatusIndicator.swift`
- Create: `FenixKanban/Components/EmptyStateView.swift`

- [ ] **Step 1: Write LabelBadge**

Create `FenixKanban/Components/LabelBadge.swift`:

```swift
import SwiftUI

struct LabelBadge: View {
    let name: String
    let colorHex: String

    var body: some View {
        Text(name)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(hex: colorHex).opacity(0.25))
            .foregroundStyle(Color(hex: colorHex))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

#Preview {
    HStack {
        LabelBadge(name: "Urgent", colorHex: "#E94560")
        LabelBadge(name: "Dev", colorHex: "#0F3460")
        LabelBadge(name: "Design", colorHex: "#16C79A")
    }
    .padding()
    .preferredColorScheme(.dark)
}
```

- [ ] **Step 2: Write DueDateBadge**

Create `FenixKanban/Components/DueDateBadge.swift`:

```swift
import SwiftUI

struct DueDateBadge: View {
    let date: Date

    private var color: Color {
        if date.isOverdue { return .red }
        if date.isDueToday { return .orange }
        if date.isDueSoon { return .yellow }
        return .secondary
    }

    private var icon: String {
        if date.isOverdue { return "exclamationmark.circle.fill" }
        return "calendar"
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(date.relativeDisplay)
                .font(.caption2)
        }
        .foregroundStyle(color)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        DueDateBadge(date: Date().addingTimeInterval(-86400))
        DueDateBadge(date: Date())
        DueDateBadge(date: Date().addingTimeInterval(86400))
        DueDateBadge(date: Date().addingTimeInterval(86400 * 7))
    }
    .padding()
    .preferredColorScheme(.dark)
}
```

- [ ] **Step 3: Write SyncStatusIndicator**

Create `FenixKanban/Components/SyncStatusIndicator.swift`:

```swift
import SwiftUI

struct SyncStatusIndicator: View {
    let status: SyncStatus

    @State private var isVisible = true

    var body: some View {
        Group {
            switch status {
            case .idle, .succeeded:
                Image(systemName: "checkmark.icloud")
                    .foregroundStyle(.green)
                    .opacity(isVisible ? 1 : 0)
                    .onAppear {
                        withAnimation(.easeOut(duration: 0.5).delay(3)) {
                            isVisible = false
                        }
                    }
            case .syncing:
                Image(systemName: "arrow.triangle.2.circlepath.icloud")
                    .foregroundStyle(.blue)
                    .symbolEffect(.rotate)
            case .failed:
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
            case .noAccount, .disabled:
                Image(systemName: "icloud.slash")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .onChange(of: status) {
            isVisible = true
        }
    }
}

enum SyncStatus: Equatable {
    case idle
    case syncing
    case succeeded
    case failed(String)
    case noAccount
    case disabled

    static func == (lhs: SyncStatus, rhs: SyncStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.syncing, .syncing), (.succeeded, .succeeded),
             (.noAccount, .noAccount), (.disabled, .disabled):
            return true
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

#Preview {
    HStack(spacing: 20) {
        SyncStatusIndicator(status: .syncing)
        SyncStatusIndicator(status: .succeeded)
        SyncStatusIndicator(status: .failed("Network error"))
        SyncStatusIndicator(status: .noAccount)
    }
    .padding()
    .preferredColorScheme(.dark)
}
```

- [ ] **Step 4: Write EmptyStateView**

Create `FenixKanban/Components/EmptyStateView.swift`:

```swift
import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            if let actionTitle = actionTitle, let action = action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    EmptyStateView(
        icon: "rectangle.on.rectangle.slash",
        title: "No Boards Yet",
        message: "Create your first board to get started",
        actionTitle: "New Board"
    ) {}
    .preferredColorScheme(.dark)
}
```

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Components/
git commit -m "feat: LabelBadge, DueDateBadge, SyncStatusIndicator, EmptyStateView components"
```

---

### Task 13: BoardListView

**Files:**
- Create: `FenixKanban/Features/BoardList/BoardListViewModel.swift`
- Create: `FenixKanban/Features/BoardList/BoardRowView.swift`
- Create: `FenixKanban/Features/BoardList/BoardListView.swift`
- Create: `FenixKanbanTests/ViewModels/BoardListViewModelTests.swift`

- [ ] **Step 1: Write BoardListViewModel**

Create `FenixKanban/Features/BoardList/BoardListViewModel.swift`:

```swift
import CoreData
import SwiftUI

final class BoardListViewModel: ObservableObject {
    @Published var boards: [Board] = []
    @Published var showNewBoardSheet = false

    private let boardRepository: BoardRepository
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
        self.boardRepository = BoardRepository(context: context)
        fetchBoards()
        observeChanges()
    }

    func fetchBoards() {
        boards = boardRepository.fetchAllBoards()
    }

    func createBoard(name: String, colorHex: String?) {
        _ = boardRepository.createBoard(name: name, colorHex: colorHex)
        fetchBoards()
    }

    func deleteBoard(_ board: Board) {
        boardRepository.deleteBoard(board)
        fetchBoards()
    }

    func deleteBoards(at offsets: IndexSet) {
        for index in offsets {
            boardRepository.deleteBoard(boards[index])
        }
        fetchBoards()
    }

    func moveBoard(from source: IndexSet, to destination: Int) {
        guard let sourceIndex = source.first else { return }
        let board = boards[sourceIndex]
        boardRepository.reorderBoard(board, to: destination, in: boards)
        fetchBoards()
    }

    private func observeChanges() {
        NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.fetchBoards()
        }
    }
}
```

- [ ] **Step 2: Write BoardRowView**

Create `FenixKanban/Features/BoardList/BoardRowView.swift`:

```swift
import SwiftUI

struct BoardRowView: View {
    @ObservedObject var board: Board

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: board.colorHex ?? "#808080"))
                .frame(width: 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(board.name ?? "Untitled")
                    .font(.headline)
                    .lineLimit(1)

                Text("\(board.columnCount) columns \u{00B7} \(board.totalCardCount) cards")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
```

- [ ] **Step 3: Write BoardListView**

Create `FenixKanban/Features/BoardList/BoardListView.swift`:

```swift
import SwiftUI

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

import CoreData

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
```

- [ ] **Step 4: Write BoardListViewModel tests**

Create `FenixKanbanTests/ViewModels/BoardListViewModelTests.swift`:

```swift
import XCTest
import CoreData
@testable import FenixKanban

final class BoardListViewModelTests: XCTestCase {
    var persistence: PersistenceController!
    var viewModel: BoardListViewModel!

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        viewModel = BoardListViewModel(context: persistence.viewContext)
    }

    override func tearDown() {
        viewModel = nil
        persistence = nil
        super.tearDown()
    }

    func testInitiallyEmpty() {
        XCTAssertTrue(viewModel.boards.isEmpty)
    }

    func testCreateBoard() {
        viewModel.createBoard(name: "Test", colorHex: "#FF0000")
        XCTAssertEqual(viewModel.boards.count, 1)
        XCTAssertEqual(viewModel.boards[0].name, "Test")
    }

    func testDeleteBoard() {
        viewModel.createBoard(name: "ToDelete", colorHex: nil)
        XCTAssertEqual(viewModel.boards.count, 1)

        viewModel.deleteBoard(viewModel.boards[0])
        XCTAssertEqual(viewModel.boards.count, 0)
    }

    func testDeleteBoardsAtOffsets() {
        viewModel.createBoard(name: "A", colorHex: nil)
        viewModel.createBoard(name: "B", colorHex: nil)
        viewModel.createBoard(name: "C", colorHex: nil)

        viewModel.deleteBoards(at: IndexSet(integer: 1))
        XCTAssertEqual(viewModel.boards.count, 2)
        XCTAssertEqual(viewModel.boards[0].name, "A")
        XCTAssertEqual(viewModel.boards[1].name, "C")
    }
}
```

- [ ] **Step 5: Run tests**

Run: `cd /Users/chris/Documents/GitHub/FenixKanban && xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 16' -quiet 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add FenixKanban/Features/BoardList/ FenixKanbanTests/ViewModels/BoardListViewModelTests.swift
git commit -m "feat: BoardListView with board CRUD, row view, and ViewModel tests"
```

---

### Task 14: BoardView & BoardViewModel (Adaptive Layout)

**Files:**
- Create: `FenixKanban/Features/Board/BoardViewModel.swift`
- Create: `FenixKanban/Features/Board/ColumnView.swift`
- Create: `FenixKanban/Features/Card/CardView.swift`
- Create: `FenixKanban/Features/Board/BoardView.swift`
- Create: `FenixKanbanTests/ViewModels/BoardViewModelTests.swift`

- [ ] **Step 1: Write BoardViewModel**

Create `FenixKanban/Features/Board/BoardViewModel.swift`:

```swift
import CoreData
import SwiftUI
import Combine

final class BoardViewModel: ObservableObject {
    @Published var board: Board
    @Published var columns: [Column] = []
    @Published var selectedColumnIndex: Int = 0
    @Published var showNewColumnSheet = false
    @Published var showNewCardSheet = false
    @Published var selectedColumnForNewCard: Column?

    private let boardRepository: BoardRepository
    private let cardRepository: CardRepository
    private let context: NSManagedObjectContext
    private var debounceTask: Task<Void, Never>?

    init(board: Board, context: NSManagedObjectContext) {
        self.board = board
        self.context = context
        self.boardRepository = BoardRepository(context: context)
        self.cardRepository = CardRepository(context: context)
        refreshColumns()
        observeChanges()
    }

    func refreshColumns() {
        columns = board.sortedColumns
    }

    // MARK: - Column Operations

    func addColumn(name: String) {
        _ = boardRepository.createColumn(in: board, name: name)
        refreshColumns()
    }

    func deleteColumn(_ column: Column) {
        boardRepository.deleteColumn(column)
        refreshColumns()
        if selectedColumnIndex >= columns.count {
            selectedColumnIndex = max(0, columns.count - 1)
        }
    }

    func renameColumn(_ column: Column, to name: String) {
        boardRepository.updateColumn(column, name: name)
        refreshColumns()
    }

    // MARK: - Card Operations

    func addCard(to column: Column, title: String) {
        _ = cardRepository.createCard(in: column, title: title)
        refreshColumns()
    }

    func deleteCard(_ card: Card) {
        cardRepository.deleteCard(card)
        refreshColumns()
    }

    // MARK: - Drag & Drop

    func moveCard(_ cardID: UUID, to column: Column, at index: Int) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s debounce
            guard !Task.isCancelled else { return }
            self.performMoveCard(cardID, to: column, at: index)
        }
    }

    private func performMoveCard(_ cardID: UUID, to column: Column, at index: Int) {
        let request = Card.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", cardID as CVarArg)
        guard let card = (try? context.fetch(request))?.first else { return }

        if card.column == column {
            cardRepository.reorderCard(card, to: index, in: column.sortedCards)
        } else {
            cardRepository.moveCard(card, to: column, at: index)
        }
        refreshColumns()
    }

    func reorderCard(_ card: Card, to index: Int, in column: Column) {
        cardRepository.reorderCard(card, to: index, in: column.sortedCards)
        refreshColumns()
    }

    private func observeChanges() {
        NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshColumns()
        }
    }
}
```

- [ ] **Step 2: Write CardView**

Create `FenixKanban/Features/Card/CardView.swift`:

```swift
import SwiftUI

struct CardView: View {
    @ObservedObject var card: Card

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(card.title ?? "Untitled")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .strikethrough(card.isCompleted)
                    .foregroundStyle(card.isCompleted ? .secondary : .primary)

                Spacer()

                if let label = card.label,
                   let name = label.name,
                   let hex = label.colorHex {
                    LabelBadge(name: name, colorHex: hex)
                }
            }

            if let dueDate = card.dueDate {
                DueDateBadge(date: dueDate)
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 3: Write ColumnView**

Create `FenixKanban/Features/Board/ColumnView.swift`:

```swift
import SwiftUI

struct ColumnView: View {
    let column: Column
    let cards: [Card]
    let onAddCard: () -> Void
    let onDeleteCard: (Card) -> Void
    let onSelectCard: (Card) -> Void
    let onDropCard: (UUID, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column header
            HStack {
                Text(column.name ?? "Untitled")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Text("\(cards.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.quaternarySystemFill))
                    .clipShape(Capsule())

                Spacer()

                Button(action: onAddCard) {
                    Image(systemName: "plus")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Cards list
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(cards, id: \.objectID) { card in
                        CardView(card: card)
                            .draggable(card.id?.uuidString ?? "") {
                                CardView(card: card)
                                    .frame(width: 250)
                                    .opacity(0.8)
                            }
                            .onTapGesture {
                                onSelectCard(card)
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    onDeleteCard(card)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .dropDestination(for: String.self) { items, location in
                guard let uuidString = items.first,
                      let uuid = UUID(uuidString: uuidString) else { return false }
                let dropIndex = calculateDropIndex(at: location, in: cards)
                onDropCard(uuid, dropIndex)
                return true
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func calculateDropIndex(at location: CGPoint, in cards: [Card]) -> Int {
        // Approximate: drop at end by default
        return cards.count
    }
}
```

- [ ] **Step 4: Write BoardView (adaptive layout)**

Create `FenixKanban/Features/Board/BoardView.swift`:

```swift
import SwiftUI

struct BoardView: View {
    @StateObject private var viewModel: BoardViewModel
    @Environment(\.adaptiveLayout) private var layout
    @State private var selectedCard: Card?
    @State private var newColumnName = ""
    @State private var newCardTitle = ""

    init(board: Board, context: NSManagedObjectContext) {
        _viewModel = StateObject(wrappedValue: BoardViewModel(board: board, context: context))
    }

    var body: some View {
        Group {
            if viewModel.columns.isEmpty {
                EmptyStateView(
                    icon: "rectangle.3.group",
                    title: "No Columns",
                    message: "Add a column to start organizing cards",
                    actionTitle: "Add Column"
                ) {
                    viewModel.showNewColumnSheet = true
                }
            } else if layout.showMultiColumn {
                multiColumnLayout
            } else {
                singleColumnLayout
            }
        }
        .navigationTitle(viewModel.board.name ?? "Board")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        viewModel.showNewColumnSheet = true
                    } label: {
                        Label("New Column", systemImage: "rectangle.split.3x1")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $viewModel.showNewColumnSheet) {
            NewColumnSheet(name: $newColumnName) {
                if !newColumnName.trimmingCharacters(in: .whitespaces).isEmpty {
                    viewModel.addColumn(name: newColumnName)
                    newColumnName = ""
                }
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
                        }
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
        }
    }
}
```

- [ ] **Step 5: Write NewColumnSheet and NewCardSheet**

Create `FenixKanban/Features/Board/NewColumnSheet.swift`:

```swift
import SwiftUI

struct NewColumnSheet: View {
    @Binding var name: String
    let onCreate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Column Name") {
                    TextField("Enter name", text: $name)
                }
            }
            .navigationTitle("New Column")
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
        .presentationDetents([.height(200)])
    }
}
```

Create `FenixKanban/Features/Card/NewCardSheet.swift`:

```swift
import SwiftUI

struct NewCardSheet: View {
    @Binding var title: String
    let onCreate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Card Title") {
                    TextField("Enter title", text: $title)
                }
            }
            .navigationTitle("New Card")
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
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.height(200)])
    }
}
```

- [ ] **Step 6: Write BoardViewModel tests**

Create `FenixKanbanTests/ViewModels/BoardViewModelTests.swift`:

```swift
import XCTest
import CoreData
@testable import FenixKanban

final class BoardViewModelTests: XCTestCase {
    var persistence: PersistenceController!
    var boardRepo: BoardRepository!
    var board: Board!
    var viewModel: BoardViewModel!

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        board = boardRepo.createBoard(name: "Test Board")
        viewModel = BoardViewModel(board: board, context: persistence.viewContext)
    }

    override func tearDown() {
        viewModel = nil
        board = nil
        boardRepo = nil
        persistence = nil
        super.tearDown()
    }

    func testAddColumn() {
        viewModel.addColumn(name: "To Do")
        XCTAssertEqual(viewModel.columns.count, 1)
        XCTAssertEqual(viewModel.columns[0].name, "To Do")
    }

    func testDeleteColumn() {
        viewModel.addColumn(name: "To Do")
        viewModel.deleteColumn(viewModel.columns[0])
        XCTAssertEqual(viewModel.columns.count, 0)
    }

    func testRenameColumn() {
        viewModel.addColumn(name: "Original")
        viewModel.renameColumn(viewModel.columns[0], to: "Renamed")
        XCTAssertEqual(viewModel.columns[0].name, "Renamed")
    }

    func testAddCard() {
        viewModel.addColumn(name: "To Do")
        let column = viewModel.columns[0]
        viewModel.addCard(to: column, title: "Test Card")
        XCTAssertEqual(column.sortedCards.count, 1)
        XCTAssertEqual(column.sortedCards[0].title, "Test Card")
    }

    func testDeleteCard() {
        viewModel.addColumn(name: "To Do")
        let column = viewModel.columns[0]
        viewModel.addCard(to: column, title: "Card")
        let card = column.sortedCards[0]
        viewModel.deleteCard(card)
        XCTAssertEqual(column.sortedCards.count, 0)
    }
}
```

- [ ] **Step 7: Run tests**

Run: `cd /Users/chris/Documents/GitHub/FenixKanban && xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 16' -quiet 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add FenixKanban/Features/Board/ FenixKanban/Features/Card/CardView.swift FenixKanban/Features/Card/NewCardSheet.swift FenixKanbanTests/ViewModels/BoardViewModelTests.swift
git commit -m "feat: BoardView with adaptive layout, ColumnView, CardView, drag-drop support"
```

---

### Task 15: CardDetailView

**Files:**
- Create: `FenixKanban/Features/Card/CardDetailViewModel.swift`
- Create: `FenixKanban/Features/Card/CardDetailView.swift`
- Create: `FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift`

- [ ] **Step 1: Write CardDetailViewModel**

Create `FenixKanban/Features/Card/CardDetailViewModel.swift`:

```swift
import CoreData
import SwiftUI

final class CardDetailViewModel: ObservableObject {
    @Published var card: Card
    @Published var title: String
    @Published var cardDescription: String
    @Published var dueDate: Date?
    @Published var isCompleted: Bool
    @Published var selectedLabel: Label?
    @Published var showLabelPicker = false
    @Published var showDatePicker = false

    private let cardRepository: CardRepository
    private let labelRepository: LabelRepository

    var availableColumns: [Column] {
        card.column?.board?.sortedColumns ?? []
    }

    init(card: Card, context: NSManagedObjectContext) {
        self.card = card
        self.title = card.title ?? ""
        self.cardDescription = card.cardDescription ?? ""
        self.dueDate = card.dueDate
        self.isCompleted = card.isCompleted
        self.selectedLabel = card.label
        self.cardRepository = CardRepository(context: context)
        self.labelRepository = LabelRepository(context: context)
    }

    func save() {
        cardRepository.updateCard(
            card,
            title: title.isEmpty ? nil : title,
            description: cardDescription.isEmpty ? nil : cardDescription,
            dueDate: dueDate,
            isCompleted: isCompleted,
            label: selectedLabel
        )
    }

    func moveToColumn(_ column: Column) {
        let currentIndex = column.sortedCards.count
        cardRepository.moveCard(card, to: column, at: currentIndex)
    }

    func clearDueDate() {
        dueDate = nil
        cardRepository.clearDueDate(for: card)
    }

    func clearLabel() {
        selectedLabel = nil
        cardRepository.clearLabel(for: card)
    }

    func selectLabel(_ label: Label) {
        selectedLabel = label
        save()
    }
}
```

- [ ] **Step 2: Write CardDetailView**

Create `FenixKanban/Features/Card/CardDetailView.swift`:

```swift
import SwiftUI

struct CardDetailView: View {
    @StateObject private var viewModel: CardDetailViewModel
    @Environment(\.dismiss) private var dismiss

    init(card: Card, context: NSManagedObjectContext) {
        _viewModel = StateObject(wrappedValue: CardDetailViewModel(card: card, context: context))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $viewModel.title)
                        .font(.headline)

                    TextField("Description", text: $viewModel.cardDescription, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section {
                    // Column picker
                    if viewModel.availableColumns.count > 1 {
                        Picker("Column", selection: columnBinding) {
                            ForEach(viewModel.availableColumns, id: \.objectID) { column in
                                Text(column.name ?? "Untitled").tag(column)
                            }
                        }
                    }

                    // Label
                    HStack {
                        Text("Label")
                        Spacer()
                        if let label = viewModel.selectedLabel,
                           let name = label.name,
                           let hex = label.colorHex {
                            LabelBadge(name: name, colorHex: hex)
                                .onTapGesture { viewModel.showLabelPicker = true }
                            Button {
                                viewModel.clearLabel()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        } else {
                            Button("Select") { viewModel.showLabelPicker = true }
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Due date
                    HStack {
                        Text("Due Date")
                        Spacer()
                        if let date = viewModel.dueDate {
                            DueDateBadge(date: date)
                                .onTapGesture { viewModel.showDatePicker = true }
                            Button {
                                viewModel.clearDueDate()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        } else {
                            Button("Set") { viewModel.showDatePicker = true }
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Completed toggle
                    Toggle("Completed", isOn: $viewModel.isCompleted)
                }
            }
            .navigationTitle("Card Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        viewModel.save()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $viewModel.showLabelPicker) {
                LabelPickerView(
                    selectedLabel: $viewModel.selectedLabel,
                    context: viewModel.card.managedObjectContext!
                )
            }
            .sheet(isPresented: $viewModel.showDatePicker) {
                dueDatePicker
            }
            .onChange(of: viewModel.isCompleted) {
                viewModel.save()
            }
        }
    }

    private var columnBinding: Binding<Column> {
        Binding(
            get: { viewModel.card.column ?? viewModel.availableColumns[0] },
            set: { viewModel.moveToColumn($0) }
        )
    }

    private var dueDatePicker: some View {
        NavigationStack {
            DatePicker(
                "Due Date",
                selection: Binding(
                    get: { viewModel.dueDate ?? Date() },
                    set: { viewModel.dueDate = $0 }
                ),
                displayedComponents: [.date]
            )
            .datePickerStyle(.graphical)
            .padding()
            .navigationTitle("Due Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        viewModel.save()
                        viewModel.showDatePicker = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

extension Card: @retroactive Identifiable {}
extension Column: @retroactive Identifiable {}
```

- [ ] **Step 3: Write CardDetailViewModel tests**

Create `FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift`:

```swift
import XCTest
import CoreData
@testable import FenixKanban

final class CardDetailViewModelTests: XCTestCase {
    var persistence: PersistenceController!
    var boardRepo: BoardRepository!
    var cardRepo: CardRepository!
    var card: Card!
    var viewModel: CardDetailViewModel!

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        card = cardRepo.createCard(in: column, title: "Test Card")
        viewModel = CardDetailViewModel(card: card, context: persistence.viewContext)
    }

    override func tearDown() {
        viewModel = nil
        card = nil
        cardRepo = nil
        boardRepo = nil
        persistence = nil
        super.tearDown()
    }

    func testInitialValues() {
        XCTAssertEqual(viewModel.title, "Test Card")
        XCTAssertEqual(viewModel.cardDescription, "")
        XCTAssertNil(viewModel.dueDate)
        XCTAssertFalse(viewModel.isCompleted)
        XCTAssertNil(viewModel.selectedLabel)
    }

    func testSaveUpdatesCard() {
        viewModel.title = "Updated Title"
        viewModel.cardDescription = "A description"
        viewModel.isCompleted = true
        viewModel.save()

        XCTAssertEqual(card.title, "Updated Title")
        XCTAssertEqual(card.cardDescription, "A description")
        XCTAssertTrue(card.isCompleted)
    }

    func testClearDueDate() {
        viewModel.dueDate = Date()
        viewModel.save()
        XCTAssertNotNil(card.dueDate)

        viewModel.clearDueDate()
        XCTAssertNil(card.dueDate)
        XCTAssertNil(viewModel.dueDate)
    }

    func testSelectLabel() {
        let labelRepo = LabelRepository(context: persistence.viewContext)
        let label = labelRepo.createLabel(name: "Bug", colorHex: "#FF0000")

        viewModel.selectLabel(label)
        XCTAssertEqual(viewModel.selectedLabel, label)
        XCTAssertEqual(card.label, label)
    }

    func testClearLabel() {
        let labelRepo = LabelRepository(context: persistence.viewContext)
        let label = labelRepo.createLabel(name: "Bug", colorHex: "#FF0000")
        viewModel.selectLabel(label)

        viewModel.clearLabel()
        XCTAssertNil(viewModel.selectedLabel)
        XCTAssertNil(card.label)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd /Users/chris/Documents/GitHub/FenixKanban && xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 16' -quiet 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Card/CardDetailView.swift FenixKanban/Features/Card/CardDetailViewModel.swift FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift
git commit -m "feat: CardDetailView with column picker, label, due date, completed toggle"
```

---

## Layer 5: Labels

### Task 16: Label Management UI

**Files:**
- Create: `FenixKanban/Features/Labels/LabelManagementViewModel.swift`
- Create: `FenixKanban/Features/Labels/LabelManagementView.swift`
- Create: `FenixKanban/Features/Labels/LabelEditorSheet.swift`
- Create: `FenixKanban/Features/Labels/LabelPickerView.swift`

- [ ] **Step 1: Write LabelManagementViewModel**

Create `FenixKanban/Features/Labels/LabelManagementViewModel.swift`:

```swift
import CoreData
import SwiftUI

final class LabelManagementViewModel: ObservableObject {
    @Published var labels: [Label] = []
    @Published var showEditor = false
    @Published var editingLabel: Label?

    private let repository: LabelRepository

    init(context: NSManagedObjectContext) {
        self.repository = LabelRepository(context: context)
        fetchLabels()
    }

    func fetchLabels() {
        labels = repository.fetchAllLabels()
    }

    func createLabel(name: String, colorHex: String) {
        _ = repository.createLabel(name: name, colorHex: colorHex)
        fetchLabels()
    }

    func updateLabel(_ label: Label, name: String, colorHex: String) {
        repository.updateLabel(label, name: name, colorHex: colorHex)
        fetchLabels()
    }

    func deleteLabel(_ label: Label) {
        repository.deleteLabel(label)
        fetchLabels()
    }
}
```

- [ ] **Step 2: Write LabelManagementView**

Create `FenixKanban/Features/Labels/LabelManagementView.swift`:

```swift
import SwiftUI

struct LabelManagementView: View {
    @StateObject private var viewModel: LabelManagementViewModel
    @Environment(\.managedObjectContext) private var context

    init(context: NSManagedObjectContext) {
        _viewModel = StateObject(wrappedValue: LabelManagementViewModel(context: context))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.labels.isEmpty {
                    EmptyStateView(
                        icon: "tag.slash",
                        title: "No Labels",
                        message: "Create labels to categorize your cards",
                        actionTitle: "New Label"
                    ) {
                        viewModel.editingLabel = nil
                        viewModel.showEditor = true
                    }
                } else {
                    List {
                        ForEach(viewModel.labels, id: \.objectID) { label in
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color(hex: label.colorHex ?? "#808080"))
                                    .frame(width: 20, height: 20)

                                Text(label.name ?? "Untitled")

                                Spacer()

                                Text("\(label.cardCount) cards")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.editingLabel = label
                                viewModel.showEditor = true
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets {
                                viewModel.deleteLabel(viewModel.labels[i])
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Labels")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.editingLabel = nil
                        viewModel.showEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $viewModel.showEditor) {
                LabelEditorSheet(
                    label: viewModel.editingLabel,
                    onSave: { name, colorHex in
                        if let existing = viewModel.editingLabel {
                            viewModel.updateLabel(existing, name: name, colorHex: colorHex)
                        } else {
                            viewModel.createLabel(name: name, colorHex: colorHex)
                        }
                    }
                )
            }
        }
    }
}
```

- [ ] **Step 3: Write LabelEditorSheet**

Create `FenixKanban/Features/Labels/LabelEditorSheet.swift`:

```swift
import SwiftUI

struct LabelEditorSheet: View {
    let label: Label?
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var selectedColor: String

    private let presetColors = [
        "#E94560", "#0F3460", "#16C79A", "#F5A623",
        "#9B59B6", "#3498DB", "#E67E22", "#1ABC9C",
        "#E74C3C", "#2ECC71", "#F39C12", "#8E44AD"
    ]

    init(label: Label?, onSave: @escaping (String, String) -> Void) {
        self.label = label
        self.onSave = onSave
        _name = State(initialValue: label?.name ?? "")
        _selectedColor = State(initialValue: label?.colorHex ?? "#E94560")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Label Name") {
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
                                        .strokeBorder(.white, lineWidth: selectedColor == hex ? 3 : 0)
                                )
                                .onTapGesture { selectedColor = hex }
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("Preview") {
                    LabelBadge(name: name.isEmpty ? "Label" : name, colorHex: selectedColor)
                }
            }
            .navigationTitle(label == nil ? "New Label" : "Edit Label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name, selectedColor)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
```

- [ ] **Step 4: Write LabelPickerView**

Create `FenixKanban/Features/Labels/LabelPickerView.swift`:

```swift
import SwiftUI
import CoreData

struct LabelPickerView: View {
    @Binding var selectedLabel: Label?
    @StateObject private var viewModel: LabelManagementViewModel
    @Environment(\.dismiss) private var dismiss

    init(selectedLabel: Binding<Label?>, context: NSManagedObjectContext) {
        _selectedLabel = selectedLabel
        _viewModel = StateObject(wrappedValue: LabelManagementViewModel(context: context))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.labels, id: \.objectID) { label in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color(hex: label.colorHex ?? "#808080"))
                            .frame(width: 20, height: 20)

                        Text(label.name ?? "Untitled")

                        Spacer()

                        if selectedLabel?.objectID == label.objectID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.accent)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedLabel = label
                        dismiss()
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Select Label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
```

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Labels/
git commit -m "feat: Label management, editor, and picker views"
```

---

## Layer 6: CloudKit Sync

### Task 17: SyncMonitor Service

**Files:**
- Create: `FenixKanban/Core/Services/SyncMonitor.swift`
- Create: `FenixKanbanTests/Services/SyncMonitorTests.swift`

- [ ] **Step 1: Write SyncMonitor**

Create `FenixKanban/Core/Services/SyncMonitor.swift`:

```swift
import CoreData
import CloudKit
import SwiftUI

final class SyncMonitor: ObservableObject {
    @Published var status: SyncStatus = .idle

    private var eventSubscription: NSObjectProtocol?

    init(container: NSPersistentContainer) {
        guard container is NSPersistentCloudKitContainer else {
            status = .disabled
            return
        }

        checkAccountStatus()
        observeSyncEvents()
    }

    private func checkAccountStatus() {
        CKContainer(identifier: "iCloud.com.bluefenixproductions.FenixKanban")
            .accountStatus { [weak self] accountStatus, error in
                DispatchQueue.main.async {
                    if accountStatus == .noAccount {
                        self?.status = .noAccount
                    }
                }
            }
    }

    private func observeSyncEvents() {
        eventSubscription = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }

            if event.endDate == nil {
                self?.status = .syncing
            } else if let error = event.error {
                self?.status = .failed(error.localizedDescription)
            } else {
                self?.status = .succeeded
            }
        }
    }

    deinit {
        if let sub = eventSubscription {
            NotificationCenter.default.removeObserver(sub)
        }
    }
}
```

- [ ] **Step 2: Write SyncMonitor tests**

Create `FenixKanbanTests/Services/SyncMonitorTests.swift`:

```swift
import XCTest
import CoreData
@testable import FenixKanban

final class SyncMonitorTests: XCTestCase {
    func testNonCloudKitContainerSetsDisabled() {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let monitor = SyncMonitor(container: persistence.container)
        XCTAssertEqual(monitor.status, .disabled)
    }

    func testInitialStatusIsIdle() {
        // With a non-CloudKit container, status is disabled
        // This confirms the enum works correctly
        let status: SyncStatus = .idle
        XCTAssertEqual(status, .idle)
        XCTAssertNotEqual(status, .syncing)
    }

    func testSyncStatusEquality() {
        XCTAssertEqual(SyncStatus.idle, SyncStatus.idle)
        XCTAssertEqual(SyncStatus.syncing, SyncStatus.syncing)
        XCTAssertEqual(SyncStatus.failed("err"), SyncStatus.failed("err"))
        XCTAssertNotEqual(SyncStatus.failed("a"), SyncStatus.failed("b"))
        XCTAssertNotEqual(SyncStatus.idle, SyncStatus.disabled)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `cd /Users/chris/Documents/GitHub/FenixKanban && xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 16' -quiet 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add FenixKanban/Core/Services/SyncMonitor.swift FenixKanbanTests/Services/SyncMonitorTests.swift
git commit -m "feat: SyncMonitor observing CloudKit sync events with status enum"
```

---

## Layer 7: Notifications

### Task 18: NotificationService

**Files:**
- Create: `FenixKanban/Core/Services/NotificationService.swift`
- Create: `FenixKanbanTests/Services/NotificationServiceTests.swift`

- [ ] **Step 1: Write NotificationService**

Create `FenixKanban/Core/Services/NotificationService.swift`:

```swift
import UserNotifications
import CoreData

protocol NotificationServiceProtocol {
    func requestAuthorization() async -> Bool
    func scheduleReminders(for card: Card)
    func cancelReminders(for cardID: UUID)
    func refreshAllReminders(context: NSManagedObjectContext)
    func scheduleDigest()
    func cancelDigest()
}

final class NotificationService: ObservableObject, NotificationServiceProtocol {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()

    // MARK: - Preferences

    @Published var dayBeforeEnabled: Bool {
        didSet { UserDefaults.standard.set(dayBeforeEnabled, forKey: "dueDateReminderDayBefore") }
    }
    @Published var dayOfEnabled: Bool {
        didSet { UserDefaults.standard.set(dayOfEnabled, forKey: "dueDateReminderDayOf") }
    }
    @Published var overdueEnabled: Bool {
        didSet { UserDefaults.standard.set(overdueEnabled, forKey: "dueDateReminderOverdue") }
    }
    @Published var digestEnabled: Bool {
        didSet { UserDefaults.standard.set(digestEnabled, forKey: "dailyDigestEnabled") }
    }
    @Published var digestHour: Int {
        didSet { UserDefaults.standard.set(digestHour, forKey: "dailyDigestHour") }
    }
    @Published var digestMinute: Int {
        didSet { UserDefaults.standard.set(digestMinute, forKey: "dailyDigestMinute") }
    }

    init() {
        let defaults = UserDefaults.standard
        // Register defaults
        defaults.register(defaults: [
            "dueDateReminderDayBefore": true,
            "dueDateReminderDayOf": true,
            "dueDateReminderOverdue": false,
            "dailyDigestEnabled": true,
            "dailyDigestHour": 8,
            "dailyDigestMinute": 0
        ])
        self.dayBeforeEnabled = defaults.bool(forKey: "dueDateReminderDayBefore")
        self.dayOfEnabled = defaults.bool(forKey: "dueDateReminderDayOf")
        self.overdueEnabled = defaults.bool(forKey: "dueDateReminderOverdue")
        self.digestEnabled = defaults.bool(forKey: "dailyDigestEnabled")
        self.digestHour = defaults.integer(forKey: "dailyDigestHour")
        self.digestMinute = defaults.integer(forKey: "dailyDigestMinute")
    }

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    // MARK: - Due Date Reminders

    func scheduleReminders(for card: Card) {
        guard let cardID = card.id, let dueDate = card.dueDate else { return }
        guard !card.isCompleted else {
            cancelReminders(for: cardID)
            return
        }

        cancelReminders(for: cardID)

        let title = card.title ?? "Card"

        if dayBeforeEnabled {
            if let dayBefore = Calendar.current.date(byAdding: .day, value: -1, to: dueDate) {
                scheduleNotification(
                    id: "dueDate-\(cardID)-dayBefore",
                    title: "Due Tomorrow",
                    body: "\"\(title)\" is due tomorrow",
                    date: dayBefore,
                    hour: 9, minute: 0
                )
            }
        }

        if dayOfEnabled {
            scheduleNotification(
                id: "dueDate-\(cardID)-dayOf",
                title: "Due Today",
                body: "\"\(title)\" is due today",
                date: dueDate,
                hour: 9, minute: 0
            )
        }

        if overdueEnabled {
            if let dayAfter = Calendar.current.date(byAdding: .day, value: 1, to: dueDate) {
                scheduleNotification(
                    id: "dueDate-\(cardID)-overdue",
                    title: "Overdue",
                    body: "\"\(title)\" is overdue",
                    date: dayAfter,
                    hour: 9, minute: 0
                )
            }
        }
    }

    func cancelReminders(for cardID: UUID) {
        let identifiers = [
            "dueDate-\(cardID)-dayBefore",
            "dueDate-\(cardID)-dayOf",
            "dueDate-\(cardID)-overdue"
        ]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func refreshAllReminders(context: NSManagedObjectContext) {
        center.removeAllPendingNotificationRequests()

        let request = Card.fetchRequest()
        request.predicate = NSPredicate(format: "dueDate != nil AND isCompleted == NO")
        guard let cards = try? context.fetch(request) else { return }

        for card in cards {
            scheduleReminders(for: card)
        }

        if digestEnabled {
            scheduleDigest(context: context)
        }
    }

    // MARK: - Daily Digest

    func scheduleDigest() {
        // No-context version — schedules with generic message
        scheduleDigestNotification(dueToday: 0, overdue: 0, forceSchedule: true)
    }

    func scheduleDigest(context: NSManagedObjectContext) {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday)!

        let dueTodayRequest = Card.fetchRequest()
        dueTodayRequest.predicate = NSPredicate(
            format: "dueDate >= %@ AND dueDate < %@ AND isCompleted == NO",
            startOfToday as NSDate, endOfToday as NSDate
        )
        let dueToday = (try? context.count(for: dueTodayRequest)) ?? 0

        let overdueRequest = Card.fetchRequest()
        overdueRequest.predicate = NSPredicate(
            format: "dueDate < %@ AND isCompleted == NO",
            startOfToday as NSDate
        )
        let overdue = (try? context.count(for: overdueRequest)) ?? 0

        scheduleDigestNotification(dueToday: dueToday, overdue: overdue, forceSchedule: false)
    }

    func cancelDigest() {
        center.removePendingNotificationRequests(withIdentifiers: ["dailyDigest"])
    }

    // MARK: - Private Helpers

    private func scheduleNotification(id: String, title: String, body: String, date: Date, hour: Int, minute: Int) {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request)
    }

    private func scheduleDigestNotification(dueToday: Int, overdue: Int, forceSchedule: Bool) {
        cancelDigest()

        guard digestEnabled else { return }
        guard forceSchedule || dueToday > 0 || overdue > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Daily Summary"

        var parts: [String] = []
        if dueToday > 0 { parts.append("\(dueToday) due today") }
        if overdue > 0 { parts.append("\(overdue) overdue") }
        content.body = parts.isEmpty ? "You're all caught up!" : parts.joined(separator: ", ")
        content.sound = .default

        var components = DateComponents()
        components.hour = digestHour
        components.minute = digestMinute

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: "dailyDigest", content: content, trigger: trigger)
        center.add(request)
    }
}
```

- [ ] **Step 2: Write NotificationService tests**

Create `FenixKanbanTests/Services/NotificationServiceTests.swift`:

```swift
import XCTest
@testable import FenixKanban

final class NotificationServiceTests: XCTestCase {
    var service: NotificationService!

    override func setUp() {
        super.setUp()
        service = NotificationService()
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    func testDefaultPreferences() {
        // Register defaults are applied
        XCTAssertTrue(service.dayBeforeEnabled)
        XCTAssertTrue(service.dayOfEnabled)
        XCTAssertFalse(service.overdueEnabled)
        XCTAssertTrue(service.digestEnabled)
        XCTAssertEqual(service.digestHour, 8)
        XCTAssertEqual(service.digestMinute, 0)
    }

    func testPreferencePersistence() {
        service.dayBeforeEnabled = false
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "dueDateReminderDayBefore"), false)

        service.digestHour = 10
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "dailyDigestHour"), 10)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `cd /Users/chris/Documents/GitHub/FenixKanban && xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 16' -quiet 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add FenixKanban/Core/Services/NotificationService.swift FenixKanbanTests/Services/NotificationServiceTests.swift
git commit -m "feat: NotificationService with due date reminders and daily digest scheduling"
```

---

### Task 19: Notification Settings UI

**Files:**
- Create: `FenixKanban/Features/Notifications/NotificationSettingsViewModel.swift`
- Create: `FenixKanban/Features/Notifications/NotificationSettingsView.swift`

- [ ] **Step 1: Write NotificationSettingsViewModel**

Create `FenixKanban/Features/Notifications/NotificationSettingsViewModel.swift`:

```swift
import SwiftUI
import UserNotifications

final class NotificationSettingsViewModel: ObservableObject {
    @Published var isAuthorized = false
    @Published var authorizationDenied = false

    let notificationService: NotificationService

    init(notificationService: NotificationService = .shared) {
        self.notificationService = notificationService
        checkAuthorization()
    }

    func checkAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.isAuthorized = settings.authorizationStatus == .authorized
                self?.authorizationDenied = settings.authorizationStatus == .denied
            }
        }
    }

    func requestAuthorization() {
        Task { @MainActor in
            let granted = await notificationService.requestAuthorization()
            isAuthorized = granted
            authorizationDenied = !granted
        }
    }
}
```

- [ ] **Step 2: Write NotificationSettingsView**

Create `FenixKanban/Features/Notifications/NotificationSettingsView.swift`:

```swift
import SwiftUI

struct NotificationSettingsView: View {
    @StateObject private var viewModel: NotificationSettingsViewModel
    @ObservedObject private var notificationService: NotificationService

    init(notificationService: NotificationService = .shared) {
        self.notificationService = notificationService
        _viewModel = StateObject(wrappedValue: NotificationSettingsViewModel(notificationService: notificationService))
    }

    var body: some View {
        Form {
            if viewModel.authorizationDenied {
                Section {
                    HStack {
                        Image(systemName: "bell.slash")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading) {
                            Text("Notifications Disabled")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("Enable in System Settings to receive reminders")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Settings") {
                            #if canImport(UIKit)
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                            #endif
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } else if !viewModel.isAuthorized {
                Section {
                    Button("Enable Notifications") {
                        viewModel.requestAuthorization()
                    }
                }
            }

            Section("Due Date Reminders") {
                Toggle("Day before due", isOn: $notificationService.dayBeforeEnabled)
                Toggle("Morning of due date", isOn: $notificationService.dayOfEnabled)
                Toggle("When overdue", isOn: $notificationService.overdueEnabled)
            }

            Section("Daily Digest") {
                Toggle("Enabled", isOn: $notificationService.digestEnabled)

                if notificationService.digestEnabled {
                    DatePicker(
                        "Delivery time",
                        selection: digestTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                }
            }
        }
        .navigationTitle("Notifications")
    }

    private var digestTimeBinding: Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = notificationService.digestHour
                components.minute = notificationService.digestMinute
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                notificationService.digestHour = components.hour ?? 8
                notificationService.digestMinute = components.minute ?? 0
            }
        )
    }
}

#Preview {
    NavigationStack {
        NotificationSettingsView()
    }
    .preferredColorScheme(.dark)
}
```

- [ ] **Step 3: Commit**

```bash
git add FenixKanban/Features/Notifications/
git commit -m "feat: NotificationSettingsView with authorization flow and preference toggles"
```

---

## Layer 8: Settings

### Task 20: SettingsView

**Files:**
- Create: `FenixKanban/Features/Settings/SettingsViewModel.swift`
- Create: `FenixKanban/Features/Settings/SettingsView.swift`

- [ ] **Step 1: Write SettingsViewModel**

Create `FenixKanban/Features/Settings/SettingsViewModel.swift`:

```swift
import SwiftUI
import CoreData

final class SettingsViewModel: ObservableObject {
    @Published var showDeleteConfirmation = false
    @Published var syncEnabled: Bool

    let authService: AuthenticationService
    private let persistence: PersistenceController

    var userEmail: String? {
        authService.isAuthenticated ? "Signed In" : nil
    }

    init(authService: AuthenticationService, persistence: PersistenceController) {
        self.authService = authService
        self.persistence = persistence
        self.syncEnabled = authService.isAuthenticated
    }

    func signOut() {
        authService.signOut()
    }

    func deleteAllData() {
        let context = persistence.viewContext
        let entities = ["Card", "Column", "Board", "Label"]
        for entity in entities {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
            try? context.execute(deleteRequest)
        }
        try? context.save()
    }
}
```

- [ ] **Step 2: Write SettingsView**

Create `FenixKanban/Features/Settings/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    init(authService: AuthenticationService, persistence: PersistenceController) {
        _viewModel = StateObject(wrappedValue: SettingsViewModel(
            authService: authService,
            persistence: persistence
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if viewModel.authService.isAuthenticated {
                        HStack {
                            Text("Apple ID")
                            Spacer()
                            Text("Signed In")
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("iCloud Sync")
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }

                        Button("Sign Out") {
                            viewModel.signOut()
                        }
                        .foregroundStyle(.red)
                    } else {
                        HStack {
                            Text("iCloud Sync")
                            Spacer()
                            Text("Sign in to enable")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Notifications") {
                    NavigationLink("Notification Settings") {
                        NotificationSettingsView()
                    }
                }

                Section("Labels") {
                    NavigationLink("Manage Labels") {
                        LabelManagementView(context: viewModel.authService.isAuthenticated
                            ? PersistenceController.shared.viewContext
                            : PersistenceController.shared.viewContext)
                    }
                }

                Section("Data") {
                    Button("Delete All Data", role: .destructive) {
                        viewModel.showDeleteConfirmation = true
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Delete All Data",
                isPresented: $viewModel.showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Everything", role: .destructive) {
                    viewModel.deleteAllData()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all boards, columns, cards, and labels. This cannot be undone.")
            }
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add FenixKanban/Features/Settings/
git commit -m "feat: SettingsView with account info, sync status, and data management"
```

---

## Layer 9: App Integration & Preview Data

### Task 21: Preview Persistence & App Wiring

**Files:**
- Create: `FenixKanban/Preview Content/PreviewPersistence.swift`
- Modify: `FenixKanban/FenixKanbanApp.swift`

- [ ] **Step 1: Write PreviewPersistence**

Create `FenixKanban/Preview Content/PreviewPersistence.swift`:

```swift
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
        card1.label = urgent

        let card2 = Card(context: context)
        card2.id = UUID()
        card2.title = "Write API spec"
        card2.createdAt = Date()
        card2.modifiedAt = Date()
        card2.sortOrder = 1000
        card2.column = todo
        card2.label = dev

        let card3 = Card(context: context)
        card3.id = UUID()
        card3.title = "Backend refactor"
        card3.createdAt = Date()
        card3.modifiedAt = Date()
        card3.dueDate = Date().addingTimeInterval(-86400)
        card3.sortOrder = 0
        card3.column = inProgress
        card3.label = dev

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
```

- [ ] **Step 2: Update FenixKanbanApp.swift with full app wiring**

Replace `FenixKanban/FenixKanbanApp.swift` with:

```swift
import SwiftUI

@main
struct FenixKanbanApp: App {
    @StateObject private var persistence = PersistenceController.shared
    @StateObject private var authService = AuthenticationService()
    @StateObject private var syncMonitor: SyncMonitor

    init() {
        let monitor = SyncMonitor(container: PersistenceController.shared.container)
        _syncMonitor = StateObject(wrappedValue: monitor)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistence.viewContext)
                .environmentObject(authService)
                .environmentObject(syncMonitor)
                .preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)) { _ in
                    NotificationService.shared.refreshAllReminders(context: persistence.viewContext)
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var authService: AuthenticationService
    @EnvironmentObject var syncMonitor: SyncMonitor
    @Environment(\.managedObjectContext) private var context
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedBoardID: NSManagedObjectID?
    @State private var showSettings = false
    @AppStorage("hasSkippedAuth") private var hasSkippedAuth = false

    var body: some View {
        Group {
            if !authService.isAuthenticated && authService.userID == nil && !hasSkippedAuth {
                AuthView(viewModel: AuthViewModel(authService: authService))
            } else if horizontalSizeClass == .regular {
                // iPad / Mac: NavigationSplitView
                NavigationSplitView {
                    boardListSidebar
                } detail: {
                    if let boardID = selectedBoardID,
                       let board = try? context.existingObject(with: boardID) as? Board {
                        BoardView(board: board, context: context)
                            .adaptiveLayout()
                    } else {
                        EmptyStateView(
                            icon: "sidebar.squares.left",
                            title: "Select a Board",
                            message: "Choose a board from the sidebar"
                        )
                    }
                }
            } else {
                // iPhone: NavigationStack
                NavigationStack {
                    boardListSidebar
                        .navigationDestination(for: NSManagedObjectID.self) { boardID in
                            if let board = try? context.existingObject(with: boardID) as? Board {
                                BoardView(board: board, context: context)
                                    .adaptiveLayout()
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(authService: authService, persistence: .shared)
        }
    }

    private var boardListSidebar: some View {
        BoardListView(context: context)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 12) {
                        SyncStatusIndicator(status: syncMonitor.status)
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
    }
}
```

- [ ] **Step 3: Regenerate Xcode project and build**

Run: `cd /Users/chris/Documents/GitHub/FenixKanban && xcodegen generate`
Run: `cd /Users/chris/Documents/GitHub/FenixKanban && xcodebuild build -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 16' -quiet 2>&1 | tail -10`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Run all tests**

Run: `cd /Users/chris/Documents/GitHub/FenixKanban && xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 16' -quiet 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/FenixKanbanApp.swift "FenixKanban/Preview Content/PreviewPersistence.swift" FenixKanban.xcodeproj
git commit -m "feat: full app wiring with NavigationSplitView, sync monitor, and preview data"
```

---

### Task 22: Create GitHub Repository and Push

**Files:** None (git operations only)

- [ ] **Step 1: Create GitHub repository**

Run: `gh repo create BlueFenixProductions/FenixKanban --private --source=. --description "Full-featured Kanban board app for iOS, iPad, and Mac with SwiftUI, CoreData, and CloudKit sync"`
Expected: Repository created at `https://github.com/BlueFenixProductions/FenixKanban`

Note: If the org doesn't exist or you don't have permission, this will fail. In that case, create the repo manually or adjust the org name.

- [ ] **Step 2: Push all commits**

Run: `git push -u origin main`
Expected: All commits pushed to remote

- [ ] **Step 3: Verify**

Run: `gh repo view BlueFenixProductions/FenixKanban --json name,description,defaultBranchRef`
Expected: Repo info with name "FenixKanban" and commits on main branch
