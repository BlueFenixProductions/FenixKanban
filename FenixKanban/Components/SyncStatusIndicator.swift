import SwiftUI

struct SyncStatusIndicator: View {
    let status: SyncStatus

    var body: some View {
        Group {
            switch status {
            case .idle, .succeeded:
                Image(systemName: "checkmark.icloud")
                    .foregroundStyle(.green)
            case .syncing:
                Image(systemName: "arrow.triangle.2.circlepath.icloud")
                    .foregroundStyle(.blue)
                    .symbolEffect(.variableColor)
            case .failed:
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
            case .noAccount, .disabled:
                Image(systemName: "icloud.slash")
                    .foregroundStyle(.secondary)
            }
        }
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
