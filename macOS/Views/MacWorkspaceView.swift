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
    var settings: () -> Void
    var toggleSidebar: () -> Void
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
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { actions?.settings() }.keyboardShortcut(",").disabled(actions == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { actions?.toggleSidebar() }.keyboardShortcut("s", modifiers: [.command, .shift])
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
    @State private var showSettings = false
    @State private var sidebarVisible = true
    @AppStorage("mac_always_on_top") private var alwaysOnTop = true

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shopping").font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 10)
                    ForEach(Array(MacDestination.allCases.prefix(4))) { navigationRow($0) }
                    Text("Your household").font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 22)
                    navigationRow(.history)
                    navigationRow(.recipes)
                    Button { showReceipt = true } label: {
                        sidebarLabel("Import receipt", icon: "receipt")
                    }.buttonStyle(MacSidebarButtonStyle()).help("Import a receipt (⌘I)")
                    Spacer()
                    Text(household.name).font(.system(.headline, design: .rounded)).padding(.horizontal, 10)
                    Button { showSettings = true } label: { sidebarLabel("Settings", icon: "gear") }
                        .buttonStyle(MacSidebarButtonStyle()).help("Settings (⌘,)")
                }.padding(12).padding(.top, 42).frame(width: 210)
                    .background(Color.primary.opacity(0.025))
            }
            Group {
                switch selection ?? .list {
                case .list: MacListView(household: household, draft: listDraft, addRequest: $addRequest)
                case .insights: MacInsightsView(householdId: household.id)
                case .priceCheck: MacPriceCheckView(householdId: household.id, draft: priceDraft)
                case .forecast: MacForecastView(householdId: household.id)
                case .history: MacHistoryView(householdId: household.id)
                case .recipes: MacRecipesView(householdId: household.id)
                }
            }.padding(.top, 42).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topLeading) {
            Button { sidebarVisible.toggle() } label: {
                Image(systemName: "sidebar.left").font(.system(size: 15)).frame(width: 20, height: 20)
            }.buttonStyle(MacButtonStyle(.subtle, compact: true))
                .help("Toggle sidebar (⇧⌘S)").accessibilityLabel("Toggle sidebar")
                .padding(.leading, sidebarVisible ? 168 : 92).padding(.top, 8)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 760, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowLevelAccessor(alwaysOnTop: alwaysOnTop))
        .buttonStyle(MacButtonStyle(.secondary))
        .focusedSceneValue(\.trolleyActions, MacWindowActions(add: addItem, receipt: { showReceipt = true }, settings: { showSettings = true }, toggleSidebar: { sidebarVisible.toggle() }, navigate: { selection = $0 }))
        .sheet(isPresented: $showReceipt) { MacReceiptImportView(householdId: household.id).buttonStyle(MacButtonStyle(.secondary)) }
        .sheet(isPresented: $showSettings) { MacSettingsView(household: household).buttonStyle(MacButtonStyle(.secondary)) }
        .task(id: household.id) { await services.shopping.load(householdId: household.id) }
    }

    private func sidebarLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(hugeIcon: icon).resizable().scaledToFit().frame(width: 20, height: 20)
            Text(title)
            Spacer()
        }.padding(.horizontal, 10).padding(.vertical, 9).contentShape(RoundedRectangle(cornerRadius: 10))
    }
    private func navigationRow(_ destination: MacDestination) -> some View {
        Button { selection = destination } label: {
            HStack(spacing: 10) {
                Image(hugeIcon: destination.icon).resizable().scaledToFit().frame(width: 20, height: 20)
                Text(destination.rawValue)
                Spacer()
                if destination == .list {
                    Text("\(services.shopping.items.filter { !$0.checked }.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 10).padding(.vertical, 9).contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(MacSidebarButtonStyle(selected: selection == destination))
            .accessibilityAddTraits(selection == destination ? .isSelected : [])
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


enum MacButtonVariant { case primary, secondary, subtle }
struct MacButtonStyle: ButtonStyle {
    var variant: MacButtonVariant = .secondary
    var compact = false
    init(_ variant: MacButtonVariant = .secondary, compact: Bool = false) { self.variant = variant; self.compact = compact }
    func makeBody(configuration: Configuration) -> some View {
        MacButtonSurface(configuration: configuration, variant: variant, compact: compact)
    }
}
private struct MacButtonSurface: View {
    let configuration: ButtonStyleConfiguration
    let variant: MacButtonVariant
    let compact: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    var body: some View {
        configuration.label
            .padding(.horizontal, compact ? 6 : 13).padding(.vertical, compact ? 6 : 8)
            .foregroundStyle(variant == .primary ? Color.white : Color.primary)
            .background(background, in: RoundedRectangle(cornerRadius: compact ? 8 : 11))
            .contentShape(RoundedRectangle(cornerRadius: compact ? 8 : 11))
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
    private var background: Color {
        if variant == .primary { return Color.accentColor.opacity(configuration.isPressed ? 0.7 : hovered && enabled ? 0.85 : 1) }
        return Color.primary.opacity(configuration.isPressed ? 0.12 : hovered && enabled ? 0.07 : variant == .secondary ? 0.035 : 0)
    }
}
struct MacSidebarButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        MacSidebarSurface(configuration: configuration, selected: selected)
    }
}
private struct MacSidebarSurface: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @State private var hovered = false
    var body: some View {
        configuration.label
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(selected ? Color.accentColor.opacity(configuration.isPressed ? 0.2 : hovered ? 0.16 : 0.11) : Color.primary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 10))
            .onHover { hovered = $0 }.animation(.easeOut(duration: 0.12), value: hovered)
    }
}
struct MacRowHover: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        content.overlay(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(hovered ? 0.035 : 0)).allowsHitTesting(false))
            .onHover { hovered = $0 }.animation(.easeOut(duration: 0.12), value: hovered)
    }
}
