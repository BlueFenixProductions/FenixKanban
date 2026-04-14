import SwiftUI
import UserNotifications

final class NotificationSettingsViewModel: ObservableObject {
    @Published var isAuthorized = false
    @Published var authorizationDenied = false

    let notificationService: NotificationService

    init(notificationService: NotificationService = .shared) {
        self.notificationService = notificationService
        checkAuthorization()
    }

    func checkAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.isAuthorized = settings.authorizationStatus == .authorized
                self?.authorizationDenied = settings.authorizationStatus == .denied
            }
        }
    }

    func requestAuthorization() {
        Task { @MainActor in
            let granted = await notificationService.requestAuthorization()
            isAuthorized = granted
            authorizationDenied = !granted
        }
    }
}
