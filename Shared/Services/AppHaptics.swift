import Foundation
#if os(iOS)
import UIKit
#endif

/// Small, intentional feedback for direct actions; never for background refreshes.
@MainActor enum AppHaptics {
    static func tap() { impact(.soft, intensity: 0.5) }
    static func added() { impact(.light, intensity: 0.7) }
    static func sent() { impact(.light, intensity: 0.55) }
    static func selection() {
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
    static func success() {
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
    static func error() {
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }
    #if os(iOS)
    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat) {
        guard UIApplication.shared.applicationState == .active else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred(intensity: intensity)
    }
    #else
    private enum Impact { case soft, light }
    private static func impact(_ style: Impact, intensity: Double) {}
    #endif
}
