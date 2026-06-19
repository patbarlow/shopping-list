import SwiftUI

struct SidebarView: View {
    let household: Household
    let historyDays: [HistoryDay]
    @Binding var selectedDate: String?
    @Binding var isOpen: Bool
    @Binding var showRecipeImport: Bool
    @Binding var showSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .center) {
                Text("Shopping List")
                    .font(.title3.bold())
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isOpen = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(.systemGray5), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)
            .padding(.bottom, 20)

            List {
                Section("Tools") {
                    sidebarButton(title: "Settings", icon: "gear") {
                        closeThen { showSettings = true }
                    }
                    sidebarButton(title: "Import Recipe", icon: "link") {
                        closeThen { showRecipeImport = true }
                    }
                }

                if !historyDays.isEmpty {
                    Section("Purchase History") {
                        ForEach(historyDays) { day in
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    selectedDate = day.date
                                    isOpen = false
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(day.dayOfWeek)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    HStack(spacing: 4) {
                                        Text(day.displayDate)
                                        Text("·")
                                        Text("\(day.itemCount) item\(day.itemCount == 1 ? "" : "s")")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    @ViewBuilder
    private func sidebarButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .foregroundStyle(.primary)
        }
    }

    private func closeThen(_ action: @escaping () -> Void) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isOpen = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { action() }
    }
}
