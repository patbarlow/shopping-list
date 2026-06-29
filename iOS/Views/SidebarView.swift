import SwiftUI

struct SidebarView: View {
    let household: Household
    let historyDays: [HistoryDay]
    @Binding var selectedDate: String?
    @Binding var isOpen: Bool
    @Binding var showSettings: Bool
    @Binding var showInsights: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — title only, no gear (settings is a bottom row)
            Text("Shopping List")
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .padding(.horizontal, 20)
                .padding(.top, 60)
                .padding(.bottom, 20)

            // Nav rows
            VStack(alignment: .leading, spacing: 2) {
                navRow(icon: "cart.fill", label: "My List", isActive: selectedDate == nil && !showInsights) {
                    withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                        selectedDate = nil
                        showInsights = false
                        isOpen = false
                    }
                }

                navRow(icon: "chart.bar.fill", label: "Products", isActive: showInsights) {
                    withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                        selectedDate = nil
                        showInsights = true
                        isOpen = false
                    }
                }
            }
            .padding(.horizontal, 12)

            // Purchase history
            if !historyDays.isEmpty {
                Text("PURCHASE HISTORY")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 8)

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(historyDays) { day in
                            historyRow(day: day)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            } else {
                Spacer()
            }

            Divider()
                .padding(.horizontal, 16)
                .padding(.top, 8)

            // Settings at the very bottom
            navRow(icon: "gearshape", label: "Settings", isActive: false) {
                showSettings = true
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func navRow(
        icon: String,
        label: String,
        isActive: Bool,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .frame(width: 24)
                Text(label)
                    .font(.body.weight(.medium))
                if isDisabled {
                    Text("Coming soon!")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(.systemGray5), in: Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                isActive ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .foregroundStyle(isActive ? Color.accentColor : .primary)
            .opacity(isDisabled ? 0.35 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    @ViewBuilder
    private func historyRow(day: HistoryDay) -> some View {
        let isSelected = selectedDate == day.date
        Button {
            withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                selectedDate = day.date
                showInsights = false
                isOpen = false
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(day.dayOfWeek)
                        .font(.subheadline.weight(.semibold))
                    Text(day.displayDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(day.itemCount)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color(.systemGray5), in: Circle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                isSelected ? Color.accentColor.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}
