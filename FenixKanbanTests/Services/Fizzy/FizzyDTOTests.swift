import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzyDTOs decode")
struct FizzyDTOTests {

    private func loadFixture(_ name: String) throws -> Data {
        // Try to load from test bundle resources first
        let bundle = Bundle(for: FixtureLocator.self)
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/fizzy") {
            return try Data(contentsOf: url)
        }

        // Fall back to non-subdir layout if the build system flattened resources
        if let flatURL = bundle.url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: flatURL)
        }

        // Final fallback: load from source directory using #file path
        // This allows tests to find fixtures during development without requiring resource bundling
        let testFile = #file
        let testURL = URL(fileURLWithPath: testFile)
        // From FizzyDTOTests.swift -> Fizzy -> Services -> FenixKanbanTests
        let testBundleDir = testURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixturesDir = testBundleDir.appendingPathComponent("Fixtures").appendingPathComponent("fizzy")
        let fixturePath = fixturesDir.appendingPathComponent("\(name).json")

        if FileManager.default.fileExists(atPath: fixturePath.path) {
            return try Data(contentsOf: fixturePath)
        }

        Issue.record("Could not locate fixture \(name).json in test bundle at \(fixturePath.path)")
        throw CocoaError(.fileNoSuchFile)
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    @Test("identity.json decodes")
    func identity() throws {
        let data = try loadFixture("identity")
        let identity = try decoder.decode(FizzyIdentity.self, from: data)
        #expect(identity.accounts.count == 1)
        let account = try #require(identity.accounts.first)
        #expect(account.id == "03f5v9zjskhcii2r45ih3u1rq")
        #expect(account.slug == "/897362094")
        #expect(account.user.emailAddress == "chris@bluefenix.net")
    }

    @Test("boards.json decodes (array root)")
    func boards() throws {
        let data = try loadFixture("boards")
        let boards = try decoder.decode([FizzyBoard].self, from: data)
        #expect(boards.count == 1)
        #expect(boards[0].name == "Roadmap")
        #expect(boards[0].allAccess == true)
        #expect(boards[0].autoPostponePeriodInDays == 30)
    }

    @Test("columns.json decodes (array root, 3 columns)")
    func columns() throws {
        let data = try loadFixture("columns")
        let columns = try decoder.decode([FizzyColumn].self, from: data)
        #expect(columns.count == 3)
        #expect(columns.map(\.name) == ["Triage", "In Progress", "Review"])
        #expect(columns[1].color.name == "Lime")
    }

    @Test("cards.json decodes (list endpoint, no column field)")
    func cardsList() throws {
        let data = try loadFixture("cards")
        let cards = try decoder.decode([FizzyCard].self, from: data)
        #expect(cards.count == 3)
        #expect(cards[1].golden == true)
        #expect(cards[1].tags == ["urgent", "bug"])
        #expect(cards[1].column == nil)
        #expect(cards[2].imageURL?.absoluteString == "https://fizzy.bluefenix.net/uploads/cards/3.png")
    }

    @Test("card_single.json decodes (single endpoint with column + steps)")
    func cardSingle() throws {
        let data = try loadFixture("card_single")
        let card = try decoder.decode(FizzyCard.self, from: data)
        #expect(card.title == "First card")
        let column = try #require(card.column)
        #expect(column.name == "In Progress")
        let steps = try #require(card.steps)
        #expect(steps.count == 2)
        #expect(steps[1].completed == true)
    }

    // Live capture (2026-06-12): 32 real cards from the Playground "Ready"
    // column. Verbatim bytes — no scrubbing. Each card carries `column`
    // because per-column endpoint is the only list source that includes it.
    // RED-first: this test fails until `make generate` embeds the fixture
    // in the test bundle (project.yml resources:FenixKanbanTests/Fixtures).
    @Test("playground_column_cards.json decodes 32 live FizzyCards with column present")
    func playgroundColumnCards() throws {
        let data = try loadFixture("playground_column_cards")
        let cards = try decoder.decode([FizzyCard].self, from: data)
        #expect(cards.count == 32, "Expected 32 cards in the Playground Ready column live capture")
        for card in cards {
            let column = try #require(card.column, "Every card from a per-column endpoint must carry a column field")
            #expect(!column.id.isEmpty)
        }
    }
}

private final class FixtureLocator {}
