import SwiftUI

/// Phase-switching parent that hosts one of three sub-views based on the
/// current `FizzyAuthState` + `FizzyBoardMapping` state. Owns:
/// - The `FizzySyncProvider` reference (passed down to sub-views).
/// - A `forceVerify` flag the Status view's "Re-enter Token" CTA sets
///   when authState was cleared by a 401 — the parent then routes to the
///   verify view regardless of the computed phase.
/// - A `refreshTrigger` (UUID @State) the sub-views bump on phase
///   transitions; mutating it forces SwiftUI to re-evaluate `phase`.
///
/// `phase` is recomputed on every body render, so as soon as a sub-view
/// writes `authState`/`mapping` and bumps `refreshTrigger`, the parent
/// renders the right next sub-view.
struct FizzyAuthView: View {

    let provider: FizzySyncProvider

    @State private var forceVerify: Bool = false
    @State private var refreshTrigger: UUID = UUID()

    var body: some View {
        let resolved = forceVerify ? FizzyAuthPhase.unconfigured : computePhase()
        Group {
            switch resolved {
            case .unconfigured:
                FizzyAuthVerifyView(
                    provider: provider,
                    onVerified: {
                        forceVerify = false
                        refreshTrigger = UUID()
                    }
                )
            case .unpaired:
                FizzyAuthPairView(
                    provider: provider,
                    onPaired: { refreshTrigger = UUID() },
                    onSignOutRequested: handleSignOut
                )
            case .paired, .pairedNoToken:
                FizzyAuthStatusView(
                    provider: provider,
                    showsReauthBanner: resolved == .pairedNoToken,
                    onReauthRequested: { forceVerify = true },
                    onSignOutRequested: handleSignOut,
                    onSyncFinished: { refreshTrigger = UUID() }
                )
            }
        }
        .id(refreshTrigger)
        .navigationTitle("Fizzy")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func computePhase() -> FizzyAuthPhase {
        let configured = provider.authStateRef.isConfigured
        let paired = provider.mappingRef.isPaired
        switch (configured, paired) {
        case (false, false): return .unconfigured
        case (true,  false): return .unpaired
        case (true,  true):  return .paired
        case (false, true):  return .pairedNoToken
        }
    }

    private func handleSignOut() {
        Task {
            try? await provider.signOut()
            await MainActor.run {
                forceVerify = false
                refreshTrigger = UUID()
            }
        }
    }
}

