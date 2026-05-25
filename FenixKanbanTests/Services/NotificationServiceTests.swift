import Testing
import Foundation
@testable import FenixKanban

// .serialized because every test mutates UserDefaults under the same keys
// the NotificationService reads from. Parallel execution would race.
@Suite("Notification Service", .serialized)
@MainActor
final class NotificationServiceTests {
    let service: NotificationService

    init() {
        service = NotificationService()
    }

    @Test func defaultPreferences() {
        // register(defaults:) ensures these values are set on a clean install
        #expect(service.dayBeforeEnabled == true)
        #expect(service.dayOfEnabled == true)
        #expect(service.overdueEnabled == false)
        #expect(service.digestEnabled == true)
        #expect(service.digestHour == 8)
        #expect(service.digestMinute == 0)
    }

    @Test func preferencePersistence() {
        service.dayBeforeEnabled = false
        #expect(UserDefaults.standard.bool(forKey: "dueDateReminderDayBefore") == false)

        service.digestHour = 10
        #expect(UserDefaults.standard.integer(forKey: "dailyDigestHour") == 10)

        // Restore defaults so other tests are not affected
        service.dayBeforeEnabled = true
        service.digestHour = 8
    }
}
