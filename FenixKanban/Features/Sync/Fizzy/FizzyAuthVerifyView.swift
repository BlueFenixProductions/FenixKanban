import SwiftUI

/// Token-paste + verify form. Sub-view of FizzyAuthView at phase .unconfigured
/// (or when forceVerify is set by a 401 recovery).
struct FizzyAuthVerifyView: View {

    let provider: FizzySyncProvider
    let onVerified: () -> Void

    @State private var enteredToken: String = ""
    @State private var verifyError: String?
    @State private var isVerifying: Bool = false
    @State private var verifyTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                TextField("Paste your fizzy.bluefenix.net token", text: $enteredToken)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .monospaced()
                    .onSubmit(verify)
            } header: {
                Text("Access Token")
            } footer: {
                Text(LocalizedStringKey(
                    "Create or copy a token at [fizzy.bluefenix.net/me/access](https://fizzy.bluefenix.net/me/access)."
                ))
            }

            if let verifyError {
                Section {
                    Text(verifyError)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            Section {
                Button(action: verify) {
                    HStack {
                        if isVerifying { ProgressView().controlSize(.small) }
                        Text(isVerifying ? "Verifying…" : "Verify Connection")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(enteredToken.trimmingCharacters(in: .whitespaces).isEmpty || isVerifying)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .onDisappear { verifyTask?.cancel() }
    }

    private func verify() {
        verifyTask?.cancel()
        verifyError = nil
        let trimmed = enteredToken.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isVerifying = true
        verifyTask = Task { @MainActor in
            defer { isVerifying = false }
            // Build a throwaway client with empty slug — /my/identity skips slug interpolation.
            let client = provider.makeClient(accessToken: trimmed, accountSlug: "")
            do {
                let identity = try await client.get("/my/identity", as: FizzyIdentity.self)
                guard let firstAccount = identity.accounts.first else {
                    verifyError = "No accounts associated with this token."
                    return
                }
                provider.authStateRef.setAccessToken(trimmed)
                provider.authStateRef.setAccountSlug(firstAccount.slug)
                onVerified()
            } catch FizzyError.unauthorized {
                provider.authStateRef.clear()
                verifyError = "Invalid token. Check it on fizzy.bluefenix.net and paste again."
            } catch let error as FizzyError {
                verifyError = "Couldn't reach Fizzy: \(error)"
            } catch is CancellationError {
                // User dismissed; ignore.
            } catch {
                verifyError = "Couldn't reach Fizzy: \(error.localizedDescription)"
            }
        }
    }
}
