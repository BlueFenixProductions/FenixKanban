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
}

private final class FixtureLocator {}
