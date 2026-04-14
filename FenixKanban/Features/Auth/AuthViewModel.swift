import AuthenticationServices
import SwiftUI

final class AuthViewModel: ObservableObject {
    @Published var errorMessage: String?
    @Published var isLoading = false

    let authService: AuthenticationService

    init(authService: AuthenticationService) {
        self.authService = authService
    }

    func handleSignInResult(_ result: Result<ASAuthorization, Error>) {
        isLoading = true
        errorMessage = nil

        switch result {
        case .success(let authorization):
            if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
                authService.handleSignInResult(userID: credential.user)
            }
        case .failure(let error):
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                errorMessage = "Sign in failed. Please try again."
            }
        }

        isLoading = false
    }

    func skip() {
        UserDefaults.standard.set(true, forKey: "hasSkippedAuth")
        authService.skipSignIn()
    }
}
