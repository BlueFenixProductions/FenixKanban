import XCTest

/// End-to-end coverage for the card-drag flow that the unit test suite
/// can't reach (drag-and-drop is system-mediated and only observable
/// at the actual touch surface). One test per concern so a failure
/// points at the broken interaction directly.
///
/// Run from CLI:
///   xcodebuild test -scheme FenixKanban \
///       -destination 'platform=iOS Simulator,name=iPhone 17'
final class FenixKanbanUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // setUp creates the application but doesn't launch — each
        // test calls launchClean() or launchSeeded() based on whether
        // it needs to drive the UI seed flow or skip it.
    }

    /// Launch with -uitest-reset-store only. Lands on the empty
    /// board list ("New Board" CTA). Use when the test needs to
    /// exercise the create-board / create-column / create-card UI.
    private func launchClean() {
        app.launchArguments += ["-uitest-reset-store"]
        app.launch()
    }

    /// Launch with -uitest-reset-store AND -uitest-seed-board so
    /// the app starts with Board "Test Board" → Column "Todo" →
    /// Card "Test Card" pre-created and selected. Skips 20–30s of
    /// UI seed per test for the drag + tap suites that don't need
    /// to verify the creation flow.
    private func launchSeeded() {
        app.launchArguments += ["-uitest-reset-store", "-uitest-seed-board"]
        app.launch()

        // NavigationSplitView on iPhone may show the sidebar first
        // even with a pre-selected boardID, so tap into the row if
        // we're still on the list. Detection: presence of "Add Card"
        // means we're already inside BoardView.
        if !app.buttons["Add Card"].firstMatch.waitForExistence(timeout: 1) {
            let row = app.staticTexts["Test Board"]
            if row.waitForExistence(timeout: 2) {
                row.tap()
            }
        }
    }

    override func tearDown() {
        // Always attach a screenshot + a11y dump so a failure tells
        // us what was on screen and what the test runner could see.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "final-state"
        shot.lifetime = .keepAlways
        add(shot)

        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "a11y-hierarchy"
        tree.lifetime = .keepAlways
        add(tree)

        super.tearDown()
    }

    // MARK: - Seed helpers

    /// Drives the new-board sheet end-to-end. Mirrors the human flow
    /// (tap CTA → type name → tap Create) so any regression in the
    /// onboarding sheet shows up here too.
    private func createBoard(named name: String) {
        let newBoardButton = app.buttons["New Board"]
        XCTAssertTrue(newBoardButton.waitForExistence(timeout: 5), "empty-state New Board CTA missing")
        newBoardButton.tap()

        let nameField = app.textFields["Enter name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3), "board name field missing")
        nameField.tap()
        nameField.typeText(name)

        app.buttons["Create"].tap()
    }

    private func openBoard(named name: String) {
        let row = app.staticTexts[name]
        XCTAssertTrue(row.waitForExistence(timeout: 3), "board row \(name) missing")
        row.tap()
    }

    private func addColumn(named name: String) {
        // Either the empty-state Add Column CTA, or the toolbar + menu.
        let cta = app.buttons["Add Column"]
        if cta.waitForExistence(timeout: 1) {
            cta.tap()
        } else {
            // Toolbar plus is wrapped in a Button labeled "Add" (the
            // `plus` SF Symbol is the Image inside); tap that, then
            // pick "New Column" from the menu.
            app.buttons["Add"].tap()
            app.buttons["New Column"].tap()
        }

        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 3), "column name field missing")
        nameField.tap()
        nameField.typeText(name)
        app.buttons["Create"].tap()
    }

    private func addCard(titled title: String, inColumnNamed _: String) {
        // The "Add Card" pill is always at the foot of the column body.
        // Multiple columns can each expose one — use firstMatch since
        // single-column tests only ever have one visible.
        let addCardButton = app.buttons["Add Card"].firstMatch
        XCTAssertTrue(addCardButton.waitForExistence(timeout: 3), "Add Card pill missing")
        addCardButton.tap()

        let titleField = app.textFields.firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 3), "card title field missing")
        titleField.tap()
        titleField.typeText(title)
        app.buttons["Create"].tap()
    }

    // MARK: - Tests

    /// Smoke: seed flow reaches a state where a card is rendered and
    /// tappable. Anchor for the drag tests below — if this fails the
    /// onboarding flow is broken, not the drag. This is the only
    /// test that exercises the UI-driven create flow (launches clean,
    /// not seeded).
    func testSeedingBoardColumnAndCardLandsACardOnScreen() throws {
        launchClean()

        createBoard(named: "Drag Test Board")
        openBoard(named: "Drag Test Board")
        addColumn(named: "Todo")
        addCard(titled: "Card A", inColumnNamed: "Todo")

        let card = app.descendants(matching: .any)["card-Card A"]
        XCTAssertTrue(card.waitForExistence(timeout: 3),
                      "card-Card A not rendered after seeding — seed flow broken before drag can be exercised")
    }

    /// Long-press-drag a card onto the gold chip → CardView must
    /// render the `ticket.fill` overlay (`accessibilityLabel:
    /// "Golden ticket priority"`). Exercises `.draggable` →
    /// GoldZoneChip `.dropDestination` → `toggleGolden` end-to-end.
    func testLongPressDragCardToGoldChipMarksItGolden() throws {
        launchSeeded()

        let card = app.descendants(matching: .any)["card-Test Card"]
        let goldChip = app.descendants(matching: .any)["gold-chip"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 3), "source card missing")
        XCTAssertTrue(goldChip.waitForExistence(timeout: 3), "gold chip missing")

        // Coordinate-level press with explicit velocity + post-drop
        // hold. XCUIElement.press(forDuration:thenDragTo:) ships an
        // instantaneous-release synthesized event that the slower
        // GitHub-hosted runners drop mid-flight — the lift happens
        // but the drop callback never fires (CI run 26410301217:
        // press succeeded, no context menu, but no badge either).
        //
        // - forDuration 1.2s: > SwiftUI .draggable's ~0.5s long-press
        //   so lift wins over context-menu arbitration.
        // - withVelocity .slow: gives the system enough touch
        //   samples to register the drag intent on slow CI sims.
        // - thenHoldForDuration 0.8s: keeps the touch down on the
        //   drop target so dropDestination(isTargeted:) fires + the
        //   drop callback commits before release.
        let cardCenter = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let chipCenter = goldChip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        cardCenter.press(
            forDuration: 1.2,
            thenDragTo: chipCenter,
            withVelocity: .slow,
            thenHoldForDuration: 0.8
        )

        let badge = app.images["Golden ticket priority"]
        // 6s — drop callback → CoreData save → @FetchRequest update →
        // CardView re-render → badge composite. Locally <1s; CI is
        // slower across that whole chain.
        XCTAssertTrue(badge.waitForExistence(timeout: 6),
                      "golden-ticket badge never appeared — drag-to-chip did not toggle isGolden")
    }

    // NOTE: a cross-column drag test (Todo → Done) belongs on an iPad
    // destination — `singleColumnLayout` on iPhone portrait only
    // renders one column at a time (paged "1 of 2") so the target
    // column isn't in the visible a11y tree until the user pages to
    // it, which `.press(forDuration:thenDragTo:)` can't drive in one
    // shot. Add when the UI test matrix grows to iPad.

    /// Tap (without hold) still opens card detail — drag rework must
    /// not have eaten the click sequence on tap-only inputs.
    func testTapCardOpensDetail() throws {
        launchSeeded()

        let card = app.descendants(matching: .any)["card-Test Card"]
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        card.tap()

        // Detail view shows the editable title field with the card's
        // current title as initial text — that's a unique marker.
        let detailTitleField = app.textFields["Test Card"]
        XCTAssertTrue(detailTitleField.waitForExistence(timeout: 3),
                      "tap did not push card detail — gesture rework may have eaten the tap")
    }
}
