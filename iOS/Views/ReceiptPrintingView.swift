import SwiftUI

// MARK: - Paper shape

/// Receipt paper: a torn zigzag along the top (where it was cut from the
/// previous receipt) and, once the tear-off gesture starts, a zigzag working
/// its way across the bottom as the paper separates from the printer.
///
/// `tearProgress` is how far across the tear has travelled (0 = still attached,
/// 1 = fully torn); `tearInset` is how far above the paper's bottom edge the
/// tear runs, so the strip left in the slot can be hidden behind the printer.
private struct ReceiptPaperShape: Shape {
    var tearProgress: CGFloat
    var tearInset: CGFloat
    var tearsFromLeading: Bool
    var tooth: CGFloat = 9
    var depth: CGFloat = 5

    var animatableData: CGFloat {
        get { tearProgress }
        set { tearProgress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Teeth are sized off the width alone, so they stay put while the paper
        // grows — deriving them from the height would make them crawl.
        let count = max(2, Int((rect.width / tooth).rounded()))
        let step = rect.width / CGFloat(count)

        // Top edge, left to right.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + depth))
        for i in 0 ..< count {
            let x = rect.minX + CGFloat(i) * step
            path.addLine(to: CGPoint(x: x + step / 2, y: rect.minY))
            path.addLine(to: CGPoint(x: x + step, y: rect.minY + depth))
        }

        let progress = min(max(tearProgress, 0), 1)
        let tornWidth = rect.width * progress
        let tearY = rect.maxY - tearInset

        if progress <= 0 {
            // Attached: the bottom runs straight down into the printer.
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }

        // The torn stretch shows a zigzag at the tear line; the still-attached
        // stretch continues down into the slot.
        let tornTeeth = max(1, Int((tornWidth / step).rounded()))
        if tearsFromLeading {
            let tearX = rect.minX + CGFloat(tornTeeth) * step
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: tearX, y: rect.maxY))
            path.addLine(to: CGPoint(x: tearX, y: tearY))
            for i in 0 ..< tornTeeth {
                let x = tearX - CGFloat(i) * step
                path.addLine(to: CGPoint(x: x - step / 2, y: tearY + depth))
                path.addLine(to: CGPoint(x: x - step, y: tearY))
            }
        } else {
            let tearX = rect.maxX - CGFloat(tornTeeth) * step
            path.addLine(to: CGPoint(x: rect.maxX, y: tearY))
            for i in 0 ..< tornTeeth {
                let x = rect.maxX - CGFloat(i) * step
                path.addLine(to: CGPoint(x: x - step / 2, y: tearY + depth))
                path.addLine(to: CGPoint(x: x - step, y: tearY))
            }
            path.addLine(to: CGPoint(x: tearX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Printing view

/// The whole scan, as a receipt printer at the bottom of the screen.
///
/// The paper feeds up out of the slot as the scan reads the receipt: the store
/// header first, then each product as the model emits it, then the total. When
/// it's done the receipt sits there to be read through. If something's wrong,
/// Edit opens the review sheet; when it's right, a swipe across the bottom of
/// the paper tears it off, and tearing it off is what saves it.
struct ReceiptPrintingView: View {
    enum Stage: Equatable {
        /// Lines are still arriving.
        case printing
        /// Every line is on the paper; read it, edit it, or tear it off.
        case printed
        /// Torn off and being saved.
        case saving
    }

    let printer: ReceiptPrinter
    let stage: Stage
    let includedCount: Int
    let includedTotal: Double?
    let onEdit: () -> Void
    let onTearOff: () -> Void

    /// How much of the paper sits hidden inside the printer.
    private let paperOverlap: CGFloat = 26
    /// The tear runs this far above the hidden part, leaving a sliver in the slot.
    private let tearLip: CGFloat = 4
    private let printerHeight: CGFloat = 96
    private let tearZoneHeight: CGFloat = 72
    private let paperMargin: CGFloat = 24

    @State private var tearProgress: CGFloat = 0
    @State private var tearsFromLeading = true
    @State private var tornOff = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemGroupedBackground).ignoresSafeArea()

            // Bottom-anchored, so the paper grows upward out of the slot: each
            // new line lands at the bottom edge and pushes the rest up, and once
            // the receipt is taller than the screen the top scrolls away.
            ScrollView {
                paper
                    .padding(.horizontal, paperMargin)
                    .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .safeAreaPadding(.bottom, printerHeight - paperOverlap)

            if stage == .printed {
                tearZone
                    .padding(.horizontal, paperMargin)
                    .padding(.bottom, printerHeight)
            }

            printerCard
        }
        // Printer chatter: one tick as each line lands, a firmer one when it tears.
        .sensoryFeedback(.impact(weight: .light, intensity: 0.4), trigger: printer.lines.count)
        .sensoryFeedback(.impact(weight: .medium), trigger: tornOff)
        .animation(.spring(duration: 0.32), value: printer.lines.count)
        .animation(.spring(duration: 0.32), value: printer.totalPrinted)
        .animation(.easeInOut(duration: 0.25), value: printer.storeName)
        .animation(.easeInOut(duration: 0.25), value: stage)
    }

    // MARK: Paper

    private var paper: some View {
        VStack(spacing: 0) {
            header
            if !printer.lines.isEmpty {
                dashedDivider
                lineItems
            }
            if printer.totalPrinted {
                dashedDivider
                total
            }
        }
        // A blank stub of paper shows in the slot before the first line lands.
        .frame(maxWidth: .infinity, minHeight: paperOverlap + 28, alignment: .bottom)
        .background {
            Color(.secondarySystemGroupedBackground)
                .clipShape(paperShape)
                .shadow(color: .black.opacity(0.12), radius: 14, y: -2)
        }
        // The torn side lifts and tilts a touch as the tear crosses the paper.
        .offset(y: tornOff ? -1200 : -10 * tearProgress)
        .rotationEffect(
            .degrees(-1.4 * tearProgress),
            anchor: tearsFromLeading ? .bottomTrailing : .bottomLeading
        )
        .opacity(tornOff ? 0 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Tear off and save") {
            if stage == .printed { completeTear() }
        }
    }

    private var paperShape: ReceiptPaperShape {
        ReceiptPaperShape(
            tearProgress: tearProgress,
            tearInset: paperOverlap + tearLip,
            tearsFromLeading: tearsFromLeading
        )
    }

    @ViewBuilder
    private var header: some View {
        if let store = printer.storeName {
            VStack(spacing: 4) {
                Text(store)
                    .font(.system(.headline, design: .monospaced).weight(.bold))
                    .multilineTextAlignment(.center)
                if let date = printer.dateText {
                    Text(date)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 26)
            .padding(.bottom, 12)
            .padding(.horizontal, 16)
            .transition(.opacity)
        }
    }

    private var lineItems: some View {
        VStack(spacing: 0) {
            ForEach(Array(printer.lines.enumerated()), id: \.offset) { _, line in
                lineRow(line)
                    .padding(.vertical, 6)
                    // Each line arrives at the bottom edge, as if fed out of the slot.
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .padding(.horizontal, 16)
        // Room for the tear zone to sit over blank paper, not over the last line.
        .padding(.bottom, stage == .printed && !printer.totalPrinted ? tearZoneHeight : 0)
    }

    /// Before matching, the raw line as printed. After it, the product the line
    /// will be saved as, with the receipt's own wording underneath.
    @ViewBuilder
    private func lineRow(_ line: ReceiptPrintedLine) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(line.productName ?? line.description)
                        .font(.system(.footnote, design: .monospaced).weight(line.productName == nil ? .regular : .semibold))
                        .strikethrough(!line.isIncluded)
                    if line.isNew, line.productName != nil {
                        Text("NEW")
                            .font(.system(.caption2, design: .monospaced).weight(.bold))
                            .foregroundStyle(Color.accentColor)
                    }
                    if line.needsReview {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                if line.productName != nil {
                    Text(line.description)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let qty = line.quantityText {
                    Text(line.unitPrice.map { String(format: "%@ @ $%.2f", qty, $0) } ?? qty)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let price = line.totalPrice {
                Text(price, format: .currency(code: "AUD"))
                    .font(.system(.footnote, design: .monospaced))
                    .monospacedDigit()
                    .strikethrough(!line.isIncluded)
            }
        }
        .opacity(line.isIncluded ? 1 : 0.4)
    }

    private var total: some View {
        HStack {
            Text("TOTAL").font(.system(.subheadline, design: .monospaced).weight(.bold))
            Spacer()
            if let amount = printer.totalAmount {
                Text(amount, format: .currency(code: "AUD"))
                    .font(.system(.subheadline, design: .monospaced).weight(.bold))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        // Blank paper below the total: where the tear zone sits, and then the slot.
        .padding(.bottom, tearZoneHeight + paperOverlap)
        .transition(.opacity)
    }

    private var dashedDivider: some View {
        HStack(spacing: 4) {
            ForEach(0..<60, id: \.self) { _ in
                Rectangle().frame(width: 3, height: 1)
            }
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
    }

    // MARK: Tear-off

    /// The band of paper just above the slot. Swiping across it tears the
    /// receipt off; the tear follows the finger and lets go past two-thirds.
    private var tearZone: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            VStack {
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Image(systemName: "scissors")
                        .font(.caption)
                    Line()
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .frame(height: 1)
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .opacity(tearProgress > 0 ? 0 : 1)
            }
            .frame(width: width, height: tearZoneHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        if tearProgress == 0 {
                            tearsFromLeading = value.translation.width >= 0
                        }
                        let travelled = abs(value.translation.width)
                        tearProgress = min(1, travelled / (width * 0.7))
                    }
                    .onEnded { _ in
                        if tearProgress >= 0.66 {
                            completeTear()
                        } else {
                            withAnimation(.spring(duration: 0.35)) { tearProgress = 0 }
                        }
                    }
            )
        }
        .frame(height: tearZoneHeight)
        .accessibilityHidden(true)
    }

    private func completeTear() {
        guard !tornOff else { return }
        withAnimation(.easeOut(duration: 0.18)) { tearProgress = 1 }
        // Finish the tear, then the receipt lifts away and the save begins.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation(.easeIn(duration: 0.45)) { tornOff = true }
            try? await Task.sleep(for: .milliseconds(380))
            onTearOff()
        }
    }

    // MARK: Printer

    /// The printer itself, pinned to the bottom edge: a slot the paper feeds out
    /// of, what it's doing, and the way in to edit.
    private var printerCard: some View {
        VStack(spacing: 0) {
            // The slot. The paper passes behind it, so it reads as the exit.
            Capsule()
                .fill(Color.primary.opacity(0.55))
                .frame(height: 5)
                .padding(.horizontal, paperMargin - 4)
                .padding(.top, 10)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.subheadline.weight(.semibold))
                        .contentTransition(.numericText())
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)

                if stage == .printing {
                    ProgressView()
                        .controlSize(.small)
                } else if stage == .printed {
                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .frame(height: printerHeight, alignment: .top)
        .background(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous)
                .fill(Color(.systemGray5))
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: .black.opacity(0.08), radius: 12, y: -4)
        }
    }

    private var statusTitle: String {
        switch stage {
        case .printing:
            return printer.lines.isEmpty ? "Reading receipt" : "Printing… \(printer.lines.count)"
        case .printed:
            let count = "\(includedCount) " + (includedCount == 1 ? "item" : "items")
            if let total = includedTotal {
                return count + " · " + total.formatted(.currency(code: "AUD"))
            }
            return count
        case .saving:
            return "Saving…"
        }
    }

    private var statusDetail: String {
        switch stage {
        case .printing: return "Each line lands as it's read."
        case .printed:  return "Check it over. Swipe across the bottom to tear it off and save."
        case .saving:   return "Adding these to your history."
        }
    }
}

/// A horizontal line, for dashed strokes.
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
