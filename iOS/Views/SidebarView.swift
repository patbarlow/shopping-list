import SwiftUI
import PhotosUI

struct SidebarView: View {
    let household: Household
    let historyDays: [HistoryDay]
    @Binding var selectedDate: String?
    @Binding var isOpen: Bool
    @Binding var showRecipeImport: Bool
    @Binding var showSettings: Bool
    
    @State private var selectedTab: SidebarTab = .myList

    enum SidebarTab {
        case myList, recipe
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with Glass Settings Button
            HStack(alignment: .center) {
                Text("Shopping List")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                
                Spacer()
                
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            
            // Tab Switcher
            HStack(spacing: 0) {
                tabButton(title: "My List", icon: "cart", tab: .myList)
                tabButton(title: "Add Recipe", icon: "link", tab: .recipe)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 24)

            // History List
            if !historyDays.isEmpty {
                Text("PURCHASE HISTORY")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(historyDays) { day in
                            historyRow(day: day)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func tabButton(title: String, icon: String, tab: SidebarTab) -> some View {
        let isSelected = selectedTab == tab
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedTab = tab
                if tab == .myList {
                    selectedDate = nil
                    isOpen = false
                } else if tab == .recipe {
                    showRecipeImport = true
                    isOpen = false
                }
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: isSelected ? "\(icon).fill" : icon)
                    .font(.system(size: 20))
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? Color.accentColor : Color.clear)
            .foregroundStyle(isSelected ? .white : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func historyRow(day: HistoryDay) -> some View {
        let isSelected = selectedDate == day.date
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                selectedDate = day.date
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
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}
