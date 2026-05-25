import Testing
import SwiftUI
@testable import FenixKanban

@Suite("AppearanceMode")
struct AppearanceModeTests {

    @Test("colorScheme maps system→nil, light→.light, dark→.dark")
    func colorSchemeMapping() {
        #expect(AppearanceMode.system.colorScheme == nil)
        #expect(AppearanceMode.light.colorScheme == .light)
        #expect(AppearanceMode.dark.colorScheme == .dark)
    }

    @Test("raw value round-trips for every case")
    func rawValueRoundTrip() {
        for mode in AppearanceMode.allCases {
            #expect(AppearanceMode(rawValue: mode.rawValue) == mode)
        }
    }

    @Test("allCases ordering is system, light, dark")
    func allCasesOrder() {
        #expect(AppearanceMode.allCases == [.system, .light, .dark])
    }

    @Test("label strings are user-visible names")
    func labels() {
        #expect(AppearanceMode.system.label == "System")
        #expect(AppearanceMode.light.label == "Light")
        #expect(AppearanceMode.dark.label == "Dark")
    }
}
