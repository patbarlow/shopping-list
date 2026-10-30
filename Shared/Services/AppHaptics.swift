import Foundation
#if os(iOS)
import UIKit
#endif

/// Firm, intentional feedback for direct actions; never for background refreshes.
@MainActor enum AppHaptics {
    static func tap() { impact(.rigid, intensity: 0.9) }
    static func added() { impact(.medium, intensity: 1) }
    static func sent() { impact(.medium, intensity: 1) }
    static func selection() { impact(.medium, intensity: 0.85) }
    static func success() {
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        notification.notificationOccurred(.success)
        notification.prepare()
        #endif
    }
    static func error() {
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        notification.notificationOccurred(.error)
        notification.prepare()
        #endif
    }
    #if os(iOS)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()
    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat) {
        guard UIApplication.shared.applicationState == .active else { return }
        let generator = style == .rigid ? rigid : medium
        generator.impactOccurred(intensity: intensity)
        generator.prepare()
    }
    #else
    private enum Impact { case rigid, medium }
    private static func impact(_ style: Impact, intensity: Double) {}
    #endif
}
