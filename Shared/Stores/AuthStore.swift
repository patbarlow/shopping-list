import Foundation
import Observation

@MainActor
@Observable final class AuthStore {
    enum AuthStep {
        case enterEmail
        case enterCode(email: String)
    }

    var isLoggedIn   = false
    var currentUser: User?
    var household: Household?
    var isLoading    = false
    var error: String?

    var step: AuthStep = .enterEmail

    private let api: APIService

    init(api: APIService) {
        self.api = api
        currentUser = api.currentUser
        isLoggedIn  = api.authToken != nil
        household   = UserDefaults.sharedGroup.data(forKey: "sl_household")
            .flatMap { try? JSONDecoder().decode(Household.self, from: $0) }
    }

    // MARK: - Magic link

    func sendCode(email: String) async {
        isLoading = true
        error = nil
        do {
            try await api.requestCode(email: email)
            step = .enterCode(email: email)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func verifyCode(email: String, code: String) async {
        isLoading = true
        error = nil
        do {
            let user = try await api.verifyCode(email: email, code: code)
            currentUser = user
            isLoggedIn = true
            step = .enterEmail
            await loadHousehold()
        } catch let e as APIError {
            switch e {
            case .serverError(let msg) where msg.contains("invalid_code"):
                self.error = "That code is incorrect. Please try again."
            case .serverError(let msg) where msg.contains("code_expired"):
                self.error = "That code has expired. Request a new one."
            case .serverError(let msg) where msg.contains("too_many_attempts"):
                self.error = "Too many attempts. Please request a new code."
            default:
                self.error = e.localizedDescription
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func logout() {
        api.logout()
        currentUser = nil
        household = nil
        isLoggedIn = false
        step = .enterEmail
        UserDefaults.sharedGroup.removeObject(forKey: "sl_household")
    }

    // MARK: - Household

    func loadHousehold() async {
        if let h = try? await api.fetchMyHousehold() {
            household = h
            persistHousehold(h)
        }
    }

    func createHousehold(name: String) async {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isLoading = true
        error = nil
        do {
            let h = try await api.createHousehold(name: name)
            household = h
            persistHousehold(h)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func joinHousehold(inviteCode: String) async {
        guard !inviteCode.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isLoading = true
        error = nil
        do {
            let h = try await api.joinHousehold(inviteCode: inviteCode)
            household = h
            persistHousehold(h)
        } catch let e as APIError {
            error = e == .notFound ? "Invite code not found. Check the code and try again." : e.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func persistHousehold(_ h: Household) {
        UserDefaults.sharedGroup.set(try? JSONEncoder().encode(h), forKey: "sl_household")
    }
}
