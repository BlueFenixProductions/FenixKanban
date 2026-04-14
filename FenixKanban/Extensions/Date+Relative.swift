import Foundation

extension Date {
    var relativeDisplay: String {
        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(self) {
            return "Today"
        } else if calendar.isDateInTomorrow(self) {
            return "Tomorrow"
        } else if calendar.isDateInYesterday(self) {
            return "Yesterday"
        }

        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: self)).day ?? 0

        if days > 0 && days <= 7 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: self)
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: self)
    }

    var isOverdue: Bool {
        self < Calendar.current.startOfDay(for: Date())
    }

    var isDueToday: Bool {
        Calendar.current.isDateInToday(self)
    }

    var isDueSoon: Bool {
        let calendar = Calendar.current
        let now = Date()
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: self)).day ?? 0
        return days >= 0 && days <= 2
    }
}
