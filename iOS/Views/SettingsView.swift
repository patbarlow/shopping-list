import SwiftUI

struct SettingsView: View {
    let household: Household
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                // ── Invite code ────────────────────────────────────────────
                Section {
                    LabeledContent("Household") { Text(household.name) }
                    HStack {
                        LabeledContent("Invite Code") {
                            Text(household.inviteCode)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            UIPasteboard.general.string = household.inviteCode
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(copied ? .green : .accentColor)
                        }
                        .buttonStyle(.borderless)
                    }
                    Text("Share this code with your household partner so they can join.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Household")
                }

                // ── Sign out ───────────────────────────────────────────────
                Section {
                    Button("Sign Out", role: .destructive) {
                        services.auth.logout()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
