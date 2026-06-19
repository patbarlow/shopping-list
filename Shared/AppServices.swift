import Foundation
import Observation

@MainActor
@Observable final class AppServices {
    let api: APIService
    let realtime: RealtimeService
    let auth: AuthStore
    let shopping: ShoppingListStore

    // Set when the OS delivers a shared PDF; ShoppingListView observes this to auto-open the scanner.
    var pendingReceiptPDF: Data? = nil

    init() {
        let api      = APIService()
        let realtime = RealtimeService(api: api)
        let auth     = AuthStore(api: api)
        let shopping = ShoppingListStore(api: api, realtime: realtime)

        self.api      = api
        self.realtime = realtime
        self.auth     = auth
        self.shopping = shopping
    }
}
