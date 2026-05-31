import SwiftUI

struct LoginView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        NavigationStack {
            switch services.auth.step {
            case .enterEmail:
                EmailEntryView()
            case .enterCode(let email):
                CodeEntryView(email: email)
            }
        }
    }
}

// MARK: - Step 1: email

private struct EmailEntryView: View {
    @Environment(AppServices.self) private var services
    @State private var email = ""

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "cart.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("Shopping List")
                    .font(.largeTitle.bold())
                Text("Enter your email to sign in")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { submit() }

                if let error = services.auth.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    submit()
                } label: {
                    Group {
                        if services.auth.isLoading {
                            ProgressView()
                        } else {
                            Text("Send Code")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(services.auth.isLoading || email.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding()
    }

    private func submit() {
        Task { await services.auth.sendCode(email: email.trimmingCharacters(in: .whitespaces)) }
    }
}

// MARK: - Step 2: code

private struct CodeEntryView: View {
    let email: String
    @Environment(AppServices.self) private var services
    @State private var code = ""

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "envelope.badge")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("Check your email")
                    .font(.largeTitle.bold())
                Text("We sent a 6-digit code to\n**\(email)**")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                TextField("6-digit code", text: $code)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit { submit() }

                if let error = services.auth.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    submit()
                } label: {
                    Group {
                        if services.auth.isLoading {
                            ProgressView()
                        } else {
                            Text("Sign In")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(services.auth.isLoading || code.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Use a different email") {
                    services.auth.step = .enterEmail
                    services.auth.error = nil
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding()
    }

    private func submit() {
        Task { await services.auth.verifyCode(email: email, code: code.trimmingCharacters(in: .whitespaces)) }
    }
}
