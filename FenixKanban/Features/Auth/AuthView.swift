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
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Organize your work, your way")
                    .font(.subheadline)
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
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Continue without signing in") {
                    viewModel.skip()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Text("Sign in to sync across devices")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 40)

            Spacer()
                .frame(height: 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .background(Color(uiColor: .systemBackground))
        #elseif os(macOS)
        .background(Color(nsColor: .windowBackgroundColor))
        #endif
    }
}

#Preview {
    AuthView(viewModel: AuthViewModel(authService: AuthenticationService()))
        .preferredColorScheme(.dark)
}
