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
        // Reset persistent state so the empty-board onboarding flow
        // always runs and the test is independent of any prior session.
        app.launchArguments += ["-uitest-reset-store"]
        app.launch()
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
    /// onboarding flow is broken, not the drag.
    func testSeedingBoardColumnAndCardLandsACardOnScreen() throws {
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
        createBoard(named: "Gold Drag Board")
        openBoard(named: "Gold Drag Board")
        addColumn(named: "Todo")
        addCard(titled: "Golden Candidate", inColumnNamed: "Todo")

        let card = app.descendants(matching: .any)["card-Golden Candidate"]
        let goldChip = app.descendants(matching: .any)["gold-chip"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 3), "source card missing")
        XCTAssertTrue(goldChip.waitForExistence(timeout: 3), "gold chip missing")

        // 1.2s — longer than the local-dev 0.7s baseline so the
        // slower GitHub-hosted macOS runner reliably crosses the
        // SwiftUI .draggable long-press threshold and lifts the
        // card before context menu / scroll gesture arbitration
        // kicks in. (CI run 26409795001 showed the context menu
        // opening at 0.7s on the runner; never observed locally.)
        card.press(forDuration: 1.2, thenDragTo: goldChip)

        let badge = app.images["Golden ticket priority"]
        XCTAssertTrue(badge.waitForExistence(timeout: 3),
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
        createBoard(named: "Tap Board")
        openBoard(named: "Tap Board")
        addColumn(named: "Todo")
        addCard(titled: "Tappable", inColumnNamed: "Todo")

        let card = app.descendants(matching: .any)["card-Tappable"]
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        card.tap()

        // Detail view shows the editable title field with the card's
        // current title as initial text — that's a unique marker.
        let detailTitleField = app.textFields["Tappable"]
        XCTAssertTrue(detailTitleField.waitForExistence(timeout: 3),
                      "tap did not push card detail — gesture rework may have eaten the tap")
    }
}
