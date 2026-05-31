import Sentry
import SwiftUI

extension SentrySDK {
    static func capture(_ error: Error, service: String, operation: String, extra: [String: Any]? = nil) {
        capture(error: error) { scope in
            scope.setTag(value: service, key: "service")
            scope.setTag(value: operation, key: "operation")
            extra?.forEach { scope.setExtra(value: $1, key: $0) }
        }
    }

    static func breadcrumb(_ message: String, category: String, data: [String: Any]? = nil) {
        let crumb = Breadcrumb(level: .info, category: category)
        crumb.message = message
        if let data { crumb.data = data }
        addBreadcrumb(crumb)
    }
}

private struct SentryScreenModifier: ViewModifier {
    let screen: String
    func body(content: Content) -> some View {
        content.onAppear {
            SentrySDK.breadcrumb("Viewed \(screen)", category: "navigation", data: ["screen": screen])
        }
    }
}

extension View {
    func sentryScreen(_ name: String) -> some View {
        modifier(SentryScreenModifier(screen: name))
    }
}
