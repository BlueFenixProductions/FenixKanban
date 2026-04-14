import UserNotifications
import CoreData

protocol NotificationServiceProtocol {
    func requestAuthorization() async -> Bool
    func scheduleReminders(for card: Card)
    func cancelReminders(for cardID: UUID)
    func refreshAllReminders(context: NSManagedObjectContext)
    func scheduleDigest()
    func cancelDigest()
}

final class NotificationService: ObservableObject, NotificationServiceProtocol {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()

    // MARK: - Preferences

    @Published var dayBeforeEnabled: Bool {
        didSet { UserDefaults.standard.set(dayBeforeEnabled, forKey: "dueDateReminderDayBefore") }
    }
    @Published var dayOfEnabled: Bool {
        didSet { UserDefaults.standard.set(dayOfEnabled, forKey: "dueDateReminderDayOf") }
    }
    @Published var overdueEnabled: Bool {
        didSet { UserDefaults.standard.set(overdueEnabled, forKey: "dueDateReminderOverdue") }
    }
    @Published var digestEnabled: Bool {
        didSet { UserDefaults.standard.set(digestEnabled, forKey: "dailyDigestEnabled") }
    }
    @Published var digestHour: Int {
        didSet { UserDefaults.standard.set(digestHour, forKey: "dailyDigestHour") }
    }
    @Published var digestMinute: Int {
        didSet { UserDefaults.standard.set(digestMinute, forKey: "dailyDigestMinute") }
    }

    init() {
        let defaults = UserDefaults.standard
        // Register defaults so first-run values are correct
        defaults.register(defaults: [
            "dueDateReminderDayBefore": true,
            "dueDateReminderDayOf": true,
            "dueDateReminderOverdue": false,
            "dailyDigestEnabled": true,
            "dailyDigestHour": 8,
            "dailyDigestMinute": 0
        ])
        self.dayBeforeEnabled = defaults.bool(forKey: "dueDateReminderDayBefore")
        self.dayOfEnabled = defaults.bool(forKey: "dueDateReminderDayOf")
        self.overdueEnabled = defaults.bool(forKey: "dueDateReminderOverdue")
        self.digestEnabled = defaults.bool(forKey: "dailyDigestEnabled")
        self.digestHour = defaults.integer(forKey: "dailyDigestHour")
        self.digestMinute = defaults.integer(forKey: "dailyDigestMinute")
    }

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    // MARK: - Due Date Reminders

    func scheduleReminders(for card: Card) {
        guard let cardID = card.id, let dueDate = card.dueDate else { return }
        guard !card.isCompleted else {
            cancelReminders(for: cardID)
            return
        }

        cancelReminders(for: cardID)

        let title = card.title ?? "Card"

        if dayBeforeEnabled {
            if let dayBefore = Calendar.current.date(byAdding: .day, value: -1, to: dueDate) {
                scheduleNotification(
                    id: "dueDate-\(cardID)-dayBefore",
                    title: "Due Tomorrow",
                    body: "\"\(title)\" is due tomorrow",
                    date: dayBefore,
                    hour: 9, minute: 0
                )
            }
        }

        if dayOfEnabled {
            scheduleNotification(
                id: "dueDate-\(cardID)-dayOf",
                title: "Due Today",
                body: "\"\(title)\" is due today",
                date: dueDate,
                hour: 9, minute: 0
            )
        }

        if overdueEnabled {
            if let dayAfter = Calendar.current.date(byAdding: .day, value: 1, to: dueDate) {
                scheduleNotification(
                    id: "dueDate-\(cardID)-overdue",
                    title: "Overdue",
                    body: "\"\(title)\" is overdue",
                    date: dayAfter,
                    hour: 9, minute: 0
                )
            }
        }
    }

    func cancelReminders(for cardID: UUID) {
        let identifiers = [
            "dueDate-\(cardID)-dayBefore",
            "dueDate-\(cardID)-dayOf",
            "dueDate-\(cardID)-overdue"
        ]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func refreshAllReminders(context: NSManagedObjectContext) {
        center.removeAllPendingNotificationRequests()

        let request = Card.fetchRequest()
        request.predicate = NSPredicate(format: "dueDate != nil AND isCompleted == NO")
        guard let cards = try? context.fetch(request) else { return }

        for card in cards {
            scheduleReminders(for: card)
        }

        if digestEnabled {
            scheduleDigest(context: context)
        }
    }

    // MARK: - Daily Digest

    func scheduleDigest() {
        // No-context version — schedules with generic message
        scheduleDigestNotification(dueToday: 0, overdue: 0, forceSchedule: true)
    }

    func scheduleDigest(context: NSManagedObjectContext) {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday)!

        let dueTodayRequest = Card.fetchRequest()
        dueTodayRequest.predicate = NSPredicate(
            format: "dueDate >= %@ AND dueDate < %@ AND isCompleted == NO",
            startOfToday as NSDate, endOfToday as NSDate
        )
        let dueToday = (try? context.count(for: dueTodayRequest)) ?? 0

        let overdueRequest = Card.fetchRequest()
        overdueRequest.predicate = NSPredicate(
            format: "dueDate < %@ AND isCompleted == NO",
            startOfToday as NSDate
        )
        let overdue = (try? context.count(for: overdueRequest)) ?? 0

        scheduleDigestNotification(dueToday: dueToday, overdue: overdue, forceSchedule: false)
    }

    func cancelDigest() {
        center.removePendingNotificationRequests(withIdentifiers: ["dailyDigest"])
    }

    // MARK: - Private Helpers

    private func scheduleNotification(id: String, title: String, body: String, date: Date, hour: Int, minute: Int) {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let req = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(req)
    }

    private func scheduleDigestNotification(dueToday: Int, overdue: Int, forceSchedule: Bool) {
        cancelDigest()

        guard digestEnabled else { return }
        guard forceSchedule || dueToday > 0 || overdue > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Daily Summary"

        var parts: [String] = []
        if dueToday > 0 { parts.append("\(dueToday) due today") }
        if overdue > 0 { parts.append("\(overdue) overdue") }
        content.body = parts.isEmpty ? "You're all caught up!" : parts.joined(separator: ", ")
        content.sound = .default

        var components = DateComponents()
        components.hour = digestHour
        components.minute = digestMinute

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let req = UNNotificationRequest(identifier: "dailyDigest", content: content, trigger: trigger)
        center.add(req)
    }
}
