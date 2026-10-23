import SwiftUI

/// Shared surfaces and typography for the main iOS journeys.
enum TrolleyStyle {
    static let canvas = Color(.systemBackground)
    static let surface = Color(.secondarySystemBackground)
    static let softGreen = Color.accentColor.opacity(0.09)
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
