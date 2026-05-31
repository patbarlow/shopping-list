import SwiftUI

struct HouseholdSetupView: View {
    @Environment(AppServices.self) private var services
    @State private var householdName = ""
    @State private var inviteCode    = ""
    @State private var mode: Mode    = .create

    enum Mode { case create, join }

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 8) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.green)
                    Text("Your Household")
                        .font(.largeTitle.bold())
                    Text("Create a new household or join one with an invite code.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Picker("", selection: $mode) {
                    Text("Create").tag(Mode.create)
                    Text("Join").tag(Mode.join)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if let error = services.auth.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                VStack(spacing: 12) {
                    if mode == .create {
                        TextField("Household name (e.g. \"The Smiths\")", text: $householdName)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.done)
                            .onSubmit { createOrJoin() }

                        Button("Create Household") { createOrJoin() }
                            .buttonStyle(.borderedProminent)
                            .disabled(householdName.trimmingCharacters(in: .whitespaces).isEmpty
                                      || services.auth.isLoading)
                    } else {
                        TextField("Invite code", text: $inviteCode)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { createOrJoin() }

                        Button("Join Household") { createOrJoin() }
                            .buttonStyle(.borderedProminent)
                            .disabled(inviteCode.trimmingCharacters(in: .whitespaces).isEmpty
                                      || services.auth.isLoading)
                    }
                }
                .padding(.horizontal)
                .frame(maxWidth: .infinity)

                if services.auth.isLoading {
                    ProgressView()
                }

                Spacer()

                Button("Sign out", role: .destructive) { services.auth.logout() }
                    .font(.footnote)
            }
            .padding()
        }
    }

    private func createOrJoin() {
        Task {
            if mode == .create {
                await services.auth.createHousehold(name: householdName)
            } else {
                await services.auth.joinHousehold(inviteCode: inviteCode)
            }
        }
    }
}
