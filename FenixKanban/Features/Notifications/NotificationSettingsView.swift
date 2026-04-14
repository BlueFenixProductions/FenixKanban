import SwiftUI

struct NotificationSettingsView: View {
    @StateObject private var viewModel: NotificationSettingsViewModel
    @ObservedObject private var notificationService: NotificationService

    init(notificationService: NotificationService = .shared) {
        self.notificationService = notificationService
        _viewModel = StateObject(wrappedValue: NotificationSettingsViewModel(notificationService: notificationService))
    }

    var body: some View {
        Form {
            if viewModel.authorizationDenied {
                Section {
                    HStack {
                        Image(systemName: "bell.slash")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading) {
                            Text("Notifications Disabled")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("Enable in System Settings to receive reminders")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Settings") {
                            #if canImport(UIKit)
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                            #endif
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } else if !viewModel.isAuthorized {
                Section {
                    Button("Enable Notifications") {
                        viewModel.requestAuthorization()
                    }
                }
            }

            Section("Due Date Reminders") {
                Toggle("Day before due", isOn: $notificationService.dayBeforeEnabled)
                Toggle("Morning of due date", isOn: $notificationService.dayOfEnabled)
                Toggle("When overdue", isOn: $notificationService.overdueEnabled)
            }

            Section("Daily Digest") {
                Toggle("Enabled", isOn: $notificationService.digestEnabled)

                if notificationService.digestEnabled {
                    DatePicker(
                        "Delivery time",
                        selection: digestTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                }
            }
        }
        .navigationTitle("Notifications")
    }

    private var digestTimeBinding: Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = notificationService.digestHour
                components.minute = notificationService.digestMinute
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                notificationService.digestHour = components.hour ?? 8
                notificationService.digestMinute = components.minute ?? 0
            }
        )
    }
}

#Preview {
    NavigationStack {
        NotificationSettingsView()
    }
    .preferredColorScheme(.dark)
}
