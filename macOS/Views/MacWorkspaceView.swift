import SwiftUI

// Desktop navigation deliberately keeps text labels and standard macOS shortcuts.
enum MacDestination: String, CaseIterable, Identifiable {
    case list = "List", insights = "Insights", priceCheck = "Price check", forecast = "Forecast"
    case history = "Purchase history", recipes = "Recipes"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .list: "cart"
        case .insights: "chart.bar"
        case .priceCheck: "tag"
        case .forecast: "calendar.badge.clock"
        case .history: "clock.arrow.circlepath"
        case .recipes: "fork.knife"
        }
    }
}

struct MacWindowActions {
    var add: () -> Void
    var receipt: () -> Void
    var navigate: (MacDestination) -> Void
}
private struct MacActionsKey: FocusedValueKey { typealias Value = MacWindowActions }
extension FocusedValues {
    var trolleyActions: MacWindowActions? {
        get { self[MacActionsKey.self] }
        set { self[MacActionsKey.self] = newValue }
    }
}
struct MacCommands: Commands {
    @FocusedValue(\.trolleyActions) private var actions
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Item", action: { actions?.add() }).keyboardShortcut("n").disabled(actions == nil)
            Button("Import Receipt…", action: { actions?.receipt() }).keyboardShortcut("i").disabled(actions == nil)
        }
        CommandMenu("Go") {
            ForEach(Array(MacDestination.allCases.enumerated()), id: \.element) { index, destination in
                Button(destination.rawValue) { actions?.navigate(destination) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    .disabled(actions == nil)
            }
        }
    }
}

struct MacWorkspaceView: View {
    let household: Household
    @Environment(AppServices.self) private var services
    @State private var selection: MacDestination? = .list
    @State private var addRequest = 0
    @State private var priceDraft = MacPriceDraft()
    @State private var listDraft = MacListDraft()
    @State private var showReceipt = false
    @AppStorage("mac_always_on_top") private var alwaysOnTop = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Shopping") {
                    ForEach(Array(MacDestination.allCases.prefix(4))) { destination in
                        navigationRow(destination)
                    }
                }
                Section("Your household") {
                    navigationRow(.history)
                    navigationRow(.recipes)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Trolley")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(household.name).font(.system(.headline, design: .rounded)).lineLimit(1)
                    HStack {
                        Text("Shared shopping list").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        SettingsLink { Image(hugeIcon: "gear").resizable().frame(width: 18, height: 18) }
                            .buttonStyle(.plain).help("Settings (⌘,)")
                    }
                }.padding(16)
            }
        } detail: {
            Group {
                switch selection ?? .list {
                case .list: MacListView(household: household, draft: listDraft, addRequest: $addRequest)
                case .insights: MacInsightsView(householdId: household.id)
                case .priceCheck: MacPriceCheckView(householdId: household.id, draft: priceDraft)
                case .forecast: MacForecastView(householdId: household.id)
                case .history: MacHistoryView(householdId: household.id)
                case .recipes: MacRecipesView(householdId: household.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showReceipt = true } label: { Label("Import receipt", hugeIcon: "receipt") }
                        .help("Import a receipt (⌘I)")
                    if selection == .list {
                        Button(action: addItem) { Label("Add item", hugeIcon: "plus") }.help("Add item (⌘N)")
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 540)
        .background(WindowLevelAccessor(alwaysOnTop: alwaysOnTop))
        .focusedSceneValue(\.trolleyActions, MacWindowActions(add: addItem, receipt: { showReceipt = true }, navigate: { selection = $0 }))
        .sheet(isPresented: $showReceipt) { MacReceiptImportView(householdId: household.id) }
        .task(id: household.id) { await services.shopping.load(householdId: household.id) }
    }

    private func navigationRow(_ destination: MacDestination) -> some View {
        HStack(spacing: 10) {
            Image(hugeIcon: destination.icon).resizable().scaledToFit().frame(width: 20, height: 20)
            Text(destination.rawValue)
            if destination == .list {
                Spacer()
                Text("\(services.shopping.items.filter { !$0.checked }.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5).tag(destination)
    }

    private func addItem() {
        selection = .list
        // Wait for the destination to mount when invoked from another screen.
        Task { @MainActor in
            await Task.yield()
            addRequest += 1
        }
    }
}

enum MacStyle {
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))"
    }
    static func date(_ value: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_AU")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: String(value.prefix(10))) else { return value }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
    static func money(_ value: Double?) -> String {
        value.map { $0.formatted(.currency(code: "AUD")) } ?? "—"
    }
}

struct MacEmptyState: View {
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 16) {
            Image("TrolleyMascot").resizable().scaledToFit().frame(width: 100, height: 100).accessibilityHidden(true)
            Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MacErrorBanner: View {
    let message: String
    var retry: (() -> Void)? = nil
    var body: some View {
        HStack {
            Image(hugeIcon: "exclamationmark.circle")
            Text(message).font(.callout).textSelection(.enabled)
            Spacer()
            if let retry { Button("Retry", action: retry) }
        }.padding(12).background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
    }
}

extension View {
    func macCard(inset: CGFloat = 20) -> some View {
        padding(inset).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
}
