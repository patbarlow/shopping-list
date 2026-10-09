import SwiftUI

/// Lives inside the existing add bar; no sheet, new window or review step.
struct VoiceInputControls: View {
    let voice: VoiceEntryController
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: voice.isActive ? "stop.circle.fill" : "mic.fill")
                .font(.body.weight(.medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityLabel(voice.isActive ? "Stop voice input" : "Add items by voice")
        .help(voice.isActive ? "Stop voice input" : "Add items by voice")
    }
}

struct VoiceInputLabel: View {
    let voice: VoiceEntryController

    var body: some View {
        Text(voice.displayText)
            .foregroundStyle(.primary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(voice.displayText)
    }
}

struct VoiceFeedbackPill: View {
    let voice: VoiceEntryController

    var body: some View {
        if let message = voice.speech.error ?? voice.status {
            HStack(spacing: 12) {
                Text(message)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if voice.canUndo {
                    Button("Undo") { Task { await voice.undo() } }
                        .fontWeight(.semibold)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Undo last voice addition")
                }
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: voice.feedbackID.uuidString + (voice.speech.error ?? "")) {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                withAnimation { voice.dismissFeedback() }
            }
        }
    }
}

struct VoiceScreenGlow: View {
    let active: Bool
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let colors: [Color] = [.cyan, .blue, .purple, .pink]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                ForEach(colors.indices, id: \.self) { index in
                    Ellipse()
                        .fill(colors[index])
                        .frame(width: geometry.size.width * 0.65,
                               height: reduceMotion ? 70 : 70 + CGFloat(level) * CGFloat(18 + index * 4))
                        .blur(radius: 24)
                        .offset(x: CGFloat(index) * geometry.size.width * 0.28 - geometry.size.width * 0.42, y: 55)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
        }
        .frame(height: 110)
        .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .bottom))
        .opacity(active ? 0.4 : 0)
        .clipped()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: level)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: active)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
