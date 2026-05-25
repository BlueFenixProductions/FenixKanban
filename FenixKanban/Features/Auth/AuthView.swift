import SwiftUI
import AuthenticationServices

struct AuthView: View {
    @StateObject var viewModel: AuthViewModel

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.accentColor)

                Text("FenixKanban")
                    .font(.crossPlatformLargeTitle)
                    .fontWeight(.bold)

                Text("Organize your work, your way")
                    .font(.crossPlatformSubheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 16) {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.email, .fullName]
                } onCompletion: { result in
                    viewModel.handleSignInResult(result)
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 50)
                .cornerRadius(8)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.crossPlatformCaption)
                        .foregroundStyle(.red)
                }

                Button("Continue without signing in") {
                    viewModel.skip()
                }
                .font(.crossPlatformSubheadline)
                .foregroundStyle(.secondary)

                Text("Sign in to sync across devices")
                    .font(.crossPlatformCaption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 40)

            Spacer()
                .frame(height: 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    AuthView(viewModel: AuthViewModel(authService: AuthenticationService()))
        .preferredColorScheme(.dark)
}
