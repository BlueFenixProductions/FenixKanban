import Foundation

/// The four states `FizzyAuthView` can be in, computed from
/// `FizzyAuthState.isConfigured` + `FizzyBoardPairingStore.isEmpty`.
///
/// - `.unconfigured`: no token in Keychain → show verify view.
/// - `.unpaired`: token + slug set but no board pairing → show pair view.
/// - `.paired`: fully configured → show status view.
/// - `.pairedNoToken`: pairing persists but token was cleared mid-session
///   by a 401 in `FizzySyncEngine.sync()`. Shows the status view with the
///   inline yellow re-auth banner; tapping "Re-enter Token" sets the
///   parent's `forceVerify` override.
enum FizzyAuthPhase: Equatable {
    case unconfigured
    case unpaired
    case paired
    case pairedNoToken
}
