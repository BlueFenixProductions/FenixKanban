import Testing
import CoreData
@testable import FenixKanban

/// Tests for Card.lifecycleStatus — the computed property over lifecycleStatusRaw
/// that exposes CardLifecycleStatus (.active / .closed / .notNow).
///
/// Lifecycle (active|closed|notNow) is a *different* concept from Fizzy's
/// publish-state field (`status`: "published"/"drafted") — hence the attribute
/// is named lifecycleStatusRaw, not statusRaw.
@Suite("Card lifecycle accessor", .serialized)
struct CardLifecycleTests {

    /// In-memory stack using the CURRENT compiled model (v9).
    private func makeContext() throws -> NSManagedObjectContext {
        let model = try migrationTestModel(named: nil)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let ctx = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        ctx.persistentStoreCoordinator = coordinator
        return ctx
    }

    @Test("default lifecycleStatus is .active when lifecycleStatusRaw is 'active'")
    func defaultIsActive() throws {
        let ctx = try makeContext()
        let card = Card(context: ctx)
        card.title = "Test card"
        // lifecycleStatusRaw defaults to "active" via model default
        #expect(card.lifecycleStatus == .active)
    }

    @Test("setting .closed sets lifecycleStatus and stamps closedAt")
    func settingClosedStampsDate() throws {
        let ctx = try makeContext()
        let card = Card(context: ctx)
        card.title = "Test card"
        let before = Date()
        card.lifecycleStatus = .closed
        let after = Date()
        #expect(card.lifecycleStatus == .closed)
        let closedAt = try #require(card.closedAt, "closedAt should be set when transitioning to .closed")
        #expect(closedAt >= before)
        #expect(closedAt <= after)
    }

    @Test("setting .active clears closedAt")
    func settingActiveClearsClosedAt() throws {
        let ctx = try makeContext()
        let card = Card(context: ctx)
        card.title = "Test card"
        card.lifecycleStatus = .closed
        #expect(card.closedAt != nil)
        card.lifecycleStatus = .active
        #expect(card.closedAt == nil)
    }

    @Test("setting .notNow clears closedAt")
    func settingNotNowClearsClosedAt() throws {
        let ctx = try makeContext()
        let card = Card(context: ctx)
        card.title = "Test card"
        card.lifecycleStatus = .closed
        #expect(card.closedAt != nil)
        card.lifecycleStatus = .notNow
        #expect(card.closedAt == nil)
    }

    @Test("unknown raw value falls back to .active")
    func unknownRawFallsBackToActive() throws {
        let ctx = try makeContext()
        let card = Card(context: ctx)
        card.title = "Test card"
        card.lifecycleStatusRaw = "someFutureStatus"
        #expect(card.lifecycleStatus == .active)
    }
}
