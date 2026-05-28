import Testing
import Foundation
@testable import FenixKanban

@Suite("FirstSyncMode")
struct FirstSyncModeTests {

    @Test("allCases order locks the picker order")
    func allCasesOrder() {
        #expect(FirstSyncMode.allCases == [.pushLocalToFizzy, .replaceLocalWithFizzy, .mergeIfNoConflicts])
    }

    @Test("raw value round-trips for every case")
    func rawValueRoundTrip() {
        for mode in FirstSyncMode.allCases {
            #expect(FirstSyncMode(rawValue: mode.rawValue) == mode)
        }
    }

    @Test("label strings are user-visible names")
    func labels() {
        #expect(FirstSyncMode.pushLocalToFizzy.label    == "Push local to Fizzy")
        #expect(FirstSyncMode.replaceLocalWithFizzy.label == "Replace local with Fizzy")
        #expect(FirstSyncMode.mergeIfNoConflicts.label   == "Merge if no conflicts")
    }
}
