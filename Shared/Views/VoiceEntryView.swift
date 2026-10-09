import SwiftUI

/// Lives inside the existing add bar; no sheet, new window or review step.
struct VoiceInputControls: View {
    let voice: VoiceEntryController
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if voice.canUndo {
                Button("Undo") { Task { await voice.undo() } }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                    .accessibilityLabel("Undo last voice addition")
            }
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
}

struct VoiceInputLabel: View {
    let voice: VoiceEntryController

    var body: some View {
        Text(voice.displayText)
            .foregroundStyle(voice.speech.error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(voice.displayText)
    }
}

struct VoiceBarGlow: View {
    let active: Bool
    let level: Float
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let colors: [Color] = [.cyan, .blue, .purple, .pink]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                ForEach(colors.indices, id: \.self) { index in
                    Ellipse()
                        .fill(colors[index])
                        .frame(width: geometry.size.width * 0.42,
                               height: reduceMotion ? 9 : 10 + CGFloat(level) * CGFloat(22 + index * 5))
                        .blur(radius: 10)
                        .offset(x: CGFloat(index) * geometry.size.width * 0.22 - geometry.size.width * 0.33, y: 7)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
        }
        .opacity(active ? 0.75 : 0)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: level)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: active)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
