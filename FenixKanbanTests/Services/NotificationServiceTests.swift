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
        // register(defaults:) ensures these values are set on a clean install
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

        // Restore defaults so other tests are not affected
        service.dayBeforeEnabled = true
        service.digestHour = 8
    }
}
