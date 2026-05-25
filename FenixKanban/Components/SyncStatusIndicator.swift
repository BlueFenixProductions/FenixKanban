import SwiftUI

struct SyncStatusIndicator: View {
    let status: SyncStatus

    private var iconName: String {
        switch status {
        case .idle, .succeeded:    return "checkmark.icloud"
        case .syncing:             return "arrow.triangle.2.circlepath.icloud"
        case .failed:              return "exclamationmark.icloud"
        case .noAccount, .disabled: return "icloud.slash"
        }
    }

    private var iconColor: Color {
        switch status {
        case .idle, .succeeded:    return .green
        case .syncing:             return .blue
        case .failed:              return .orange
        case .noAccount, .disabled: return Color(.secondaryLabel)
        }
    }

    var body: some View {
        Image(systemName: iconName)
            .foregroundStyle(iconColor)
            .font(.subheadline)
    }
}

enum SyncStatus: Equatable {
    case idle
    case syncing
    case succeeded
    case failed(String)
    case noAccount
    case disabled

    static func == (lhs: SyncStatus, rhs: SyncStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.syncing, .syncing), (.succeeded, .succeeded),
             (.noAccount, .noAccount), (.disabled, .disabled):
            return true
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

#Preview {
    HStack(spacing: 20) {
        SyncStatusIndicator(status: .syncing)
        SyncStatusIndicator(status: .succeeded)
        SyncStatusIndicator(status: .failed("Network error"))
        SyncStatusIndicator(status: .noAccount)
    }
    .padding()
    .preferredColorScheme(.dark)
}
