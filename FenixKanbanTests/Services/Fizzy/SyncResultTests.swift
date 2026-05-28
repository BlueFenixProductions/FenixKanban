import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzySyncResult")
struct FizzySyncResultTests {

    @Test("default init is all zeros, empty errors")
    func defaultInit() {
        let result = FizzySyncResult()
        #expect(result.itemsCreated == 0)
        #expect(result.itemsUpdated == 0)
        #expect(result.itemsDeleted == 0)
        #expect(result.errors.isEmpty)
    }

    @Test("combine sums counters and concatenates errors")
    func combine() {
        let a = FizzySyncResult(itemsCreated: 2, itemsUpdated: 1, itemsDeleted: 0, errors: ["err1"])
        let b = FizzySyncResult(itemsCreated: 1, itemsUpdated: 3, itemsDeleted: 1, errors: ["err2"])
        let merged = a.combined(with: b)

        #expect(merged.itemsCreated == 3)
        #expect(merged.itemsUpdated == 4)
        #expect(merged.itemsDeleted == 1)
        #expect(merged.errors == ["err1", "err2"])
    }
}
