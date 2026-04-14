import SwiftUI

struct SyncStatusIndicator: View {
    let status: SyncStatus

    @State private var isVisible = true

    var body: some View {
        Group {
            switch status {
            case .idle, .succeeded:
                Image(systemName: "checkmark.icloud")
                    .foregroundStyle(.green)
                    .opacity(isVisible ? 1 : 0)
                    .onAppear {
                        withAnimation(.easeOut(duration: 0.5).delay(3)) {
                            isVisible = false
                        }
                    }
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
        .onChange(of: status) {
            isVisible = true
        }
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
