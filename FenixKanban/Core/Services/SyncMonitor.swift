import CoreData
import CloudKit
import SwiftUI

final class SyncMonitor: ObservableObject {
    @Published var status: SyncStatus = .idle

    private var eventSubscription: NSObjectProtocol?

    init(container: NSPersistentContainer) {
        guard container is NSPersistentCloudKitContainer else {
            status = .disabled
            return
        }

        checkAccountStatus()
        observeSyncEvents()
    }

    private func checkAccountStatus() {
        CKContainer(identifier: "iCloud.com.bluefenixproductions.FenixKanban")
            .accountStatus { [weak self] accountStatus, _ in
                DispatchQueue.main.async {
                    if accountStatus == .noAccount {
                        self?.status = .noAccount
                    }
                }
            }
    }

    private func observeSyncEvents() {
        eventSubscription = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }

            if event.endDate == nil {
                self?.status = .syncing
            } else if let error = event.error {
                self?.status = .failed(error.localizedDescription)
            } else {
                self?.status = .succeeded
            }
        }
    }

    deinit {
        if let sub = eventSubscription {
            NotificationCenter.default.removeObserver(sub)
        }
    }
}
