import SwiftUI
import UIKit

/// Shared surfaces and typography for the main iOS journeys.
enum TrolleyStyle {
    static let canvas = Color(.systemBackground)
    static let surface = Color(.secondarySystemBackground)
    static let accent = Color("AccentColor")
    static let softGreen = accent.opacity(0.09)

    // Navigation and tab labels are UIKit-owned, so they don't inherit
    // SwiftUI's fontDesign environment from the app's root view.
    @MainActor static func configureNavigationTypography() {
        let navigationBar = UINavigationBar.appearance()
        navigationBar.titleTextAttributes = [.font: roundedFont(for: .headline, weight: .semibold)]
        navigationBar.largeTitleTextAttributes = [.font: roundedFont(for: .largeTitle, weight: .bold)]

        let tabFont = roundedFont(for: .caption2, weight: .medium)
        UITabBarItem.appearance().setTitleTextAttributes([.font: tabFont], for: .normal)
        UITabBarItem.appearance().setTitleTextAttributes([.font: tabFont], for: .selected)
    }

    private static func roundedFont(for style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        let preferred = UIFont.preferredFont(forTextStyle: style)
        let weighted = preferred.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: weighted.withDesign(.rounded) ?? weighted, size: 0)
    }
}

extension View {
    func trolleyCard() -> some View {
        background(TrolleyStyle.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    func trolleyComposer() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 18, y: 5)
    }
}

struct TrolleyMascot: View {
    var size: CGFloat = 96
    var body: some View {
        Image("TrolleyMascot")
            .resizable().scaledToFit().frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }
}
