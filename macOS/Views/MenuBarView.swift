import SwiftUI
import AppKit

// MARK: - Window level accessor

struct WindowLevelAccessor: NSViewRepresentable {
    let alwaysOnTop: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            view.window?.level = alwaysOnTop ? .floating : .normal
            view.window?.titlebarSeparatorStyle = .none
            view.window?.titlebarAppearsTransparent = true
        }
    }
}

// MARK: - Focus fields

private enum MacFocusField: Hashable {
    case addName, addQty
    case editName, editQty, editNotes
}

// MARK: - Root router

struct MacRootView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        Group {
            Group {
                if services.auth.isLoggedIn {
                    if let household = services.auth.household {
                        MacWorkspaceView(household: household)
                    } else {
                        MacHouseholdSetupView()
                            .navigationTitle("Trolley")
                    }
                } else {
                    MacLoginView()
                        .navigationTitle("Trolley")
                }
            }
        }
        .task {
            if services.auth.isLoggedIn && services.auth.household == nil {
                await services.auth.loadHousehold()
            }
        }
    }
}

// MARK: - Login

private struct MacLoginView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        switch services.auth.step {
        case .enterEmail: MacEmailEntryView()
        case .enterCode(let email): MacCodeEntryView(email: email)
        }
    }
}

private struct MacEmailEntryView: View {
    @Environment(AppServices.self) private var services
    @State private var email = ""

    var body: some View {
        VStack(spacing: 20) {
            Image("TrolleyMascot").resizable().scaledToFit().frame(width: 96, height: 96)
            Text("Welcome to Trolley")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("Your household’s shopping, together. Sign in with the email you use on your phone.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)

            VStack(spacing: 10) {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }

                if let error = services.auth.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                Button {
                    submit()
                } label: {
                    if services.auth.isLoading { ProgressView().frame(maxWidth: .infinity) }
                    else { Text("Send Code").frame(maxWidth: .infinity) }
                }
                .buttonStyle(MacButtonStyle(.primary))
                .disabled(services.auth.isLoading || email.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(32)
        .frame(maxWidth: 400)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit() {
        Task { await services.auth.sendCode(email: email.trimmingCharacters(in: .whitespaces)) }
    }
}

private struct MacCodeEntryView: View {
    let email: String
    @Environment(AppServices.self) private var services
    @State private var code = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(hugeIcon: "envelope.badge")
                .resizable().scaledToFit().frame(width: 40, height: 40)
                .foregroundStyle(Color.accentColor)
            Text("Check your email")
                .font(.system(.title2, design: .rounded, weight: .bold))
            Text("Code sent to **\(email)**")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                TextField("6-digit code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }

                if let error = services.auth.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                Button {
                    submit()
                } label: {
                    if services.auth.isLoading { ProgressView().frame(maxWidth: .infinity) }
                    else { Text("Sign In").frame(maxWidth: .infinity) }
                }
                .buttonStyle(MacButtonStyle(.primary))
                .disabled(services.auth.isLoading || code.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: [])

                Button("Use a different email") {
                    services.auth.step = .enterEmail
                    services.auth.error = nil
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .buttonStyle(MacButtonStyle(.subtle, compact: true))
            }
        }
        .padding(32)
        .frame(maxWidth: 400)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit() {
        Task { await services.auth.verifyCode(email: email, code: code.trimmingCharacters(in: .whitespaces)) }
    }
}

// MARK: - Household setup

private struct MacHouseholdSetupView: View {
    @Environment(AppServices.self) private var services
    @State private var name       = ""
    @State private var inviteCode = ""
    @State private var mode: Mode = .create

    enum Mode { case create, join }

    var body: some View {
        VStack(spacing: 16) {
            Image(hugeIcon: "house.fill")
                .resizable().scaledToFit().frame(width: 40, height: 40)
                .foregroundStyle(Color.accentColor)
            Text("Your Household")
                .font(.system(.title2, design: .rounded, weight: .bold))

            Picker("", selection: $mode) {
                Text("Create").tag(Mode.create)
                Text("Join").tag(Mode.join)
            }
            .pickerStyle(.segmented)

            if let error = services.auth.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            if mode == .create {
                TextField("Household name", text: $name).textFieldStyle(.roundedBorder)
                Button("Create") { Task { await services.auth.createHousehold(name: name) } }
                    .buttonStyle(MacButtonStyle(.primary))
                    .disabled(name.isEmpty || services.auth.isLoading)
            } else {
                TextField("Invite code", text: $inviteCode)
                    .textFieldStyle(.roundedBorder)
                    .textCase(.uppercase)
                Button("Join") { Task { await services.auth.joinHousehold(inviteCode: inviteCode) } }
                    .buttonStyle(MacButtonStyle(.primary))
                    .disabled(inviteCode.isEmpty || services.auth.isLoading)
            }

            if services.auth.isLoading { ProgressView() }

            Divider()
            Button("Sign Out", role: .destructive) { services.auth.logout() }
                .font(.footnote)
        }
        .padding(32)
        .frame(maxWidth: 400)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Main list

@Observable final class MacListDraft {
    var isAdding = false
    var newItem = ""
    var newQty = ""
}

struct MacListView: View {
    @State private var voice = VoiceEntryController()
    @Environment(\.scenePhase) private var scenePhase
    let household: Household
    @Environment(AppServices.self) private var services

    // ── Add ──────────────────────────────────────────────────────────────────
    @Bindable var draft: MacListDraft

    // ── Edit ─────────────────────────────────────────────────────────────────
    @State private var editingItemID: String? = nil
    @State private var editName  = ""
    @State private var editQty   = ""
    @State private var editNotes = ""

    // ── Focus ─────────────────────────────────────────────────────────────────
    @FocusState private var focusedField: MacFocusField?

    // ── UI ────────────────────────────────────────────────────────────────────
    @State private var collapsedSections: Set<String> = []
    @Binding var addRequest: Int
    @State private var filter = ""

    private var store: ShoppingListStore { services.shopping }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    if store.isLoading && !store.hasLoaded {
                        ProgressView("Loading your list…").padding(40)
                    } else if store.groupedItems.isEmpty && store.hasLoaded {
                        emptyState
                    } else if !filter.isEmpty && filteredGroups.isEmpty {
                        Text("No items match “\(filter)”.").foregroundStyle(.secondary).padding(40)
                    } else {
                        ForEach(filteredGroups, id: \.category) { group in
                            categoryCard(group: group)
                        }
                    }
                    Color.clear.frame(height: 4)
                }
                .padding(24)
                .frame(maxWidth: 840)
                .frame(maxWidth: .infinity)
            }

            if let error = store.error {
                MacErrorBanner(message: error) { Task { await store.fetch() } }
            }
            if !store.recentlyCompleted.isEmpty {
                HStack {
                    Text("Checked off \(store.recentlyCompleted.count) item(s)").foregroundStyle(.secondary)
                    Button("Undo") { store.undoLastComplete() }.keyboardShortcut("z", modifiers: .command)
                }.padding(8)
            }
            VoiceFeedbackPill(voice: voice)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 12)
                .padding(.bottom, voice.status == nil && voice.speech.error == nil ? 0 : 6)

            addBar
                .padding(.horizontal, 20)
                .padding(.bottom, 20).padding(.top, 10)
                .frame(maxWidth: 840).frame(maxWidth: .infinity)
        }
        .overlay(alignment: .bottom) {
            VoiceScreenGlow(active: voice.isActive, level: voice.speech.level)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .navigationTitle("List")

        .onChange(of: addRequest) { _, value in if value > 0 { startAdding(); addRequest = 0 } }
        .task { if addRequest > 0 { startAdding(); addRequest = 0 } }
        .onChange(of: focusedField) { old, new in handleFocusChange(old: old, new: new) }
        .onDisappear { voice.stop(discardPending: true) }
        .onChange(of: scenePhase) { _, phase in if phase == .background { voice.stop(discardPending: true) } }
        .animation(.default, value: store.groupedItems.map {
            "\($0.category.rawValue)\($0.items.map { "\($0.id)\($0.checked)" }.joined())"
        })

    }

    private var filteredGroups: [(category: ItemCategory, items: [ShoppingItem])] {
        store.groupedItems.compactMap { group in
            let items = group.items.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
            return items.isEmpty ? nil : (group.category, items)
        }
    }

    // MARK: Add bar (persistent bottom)

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(hugeIcon: draft.isAdding ? "circle" : "plus")
                    .foregroundStyle(draft.isAdding ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                    .font(draft.isAdding ? .body : .body.weight(.semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .onTapGesture { startAdding() }

                if voice.isActive {
                    VoiceInputLabel(voice: voice)
                        .contentShape(Rectangle())
                        .onTapGesture { startAdding() }
                } else if draft.isAdding {
                    TextField("Items, separated by commas", text: $draft.newItem)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .addName)
                        .onSubmit { commitAdd() }
                        .onKeyPress(.escape) { cancelAdd(); return .handled }
                } else {
                    Text("Add item…")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { voice.speech.error = nil; startAdding() }
                }
                if draft.isAdding && !draft.newItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Add", action: { commitAdd() }).buttonStyle(MacButtonStyle(.primary))
                }
                VoiceInputControls(voice: voice, toggle: toggleVoice)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, draft.isAdding ? 10 : 6)

            if draft.isAdding && !voice.isActive {
                Divider().padding(.horizontal, 12).opacity(0.25)
                HStack(spacing: 10) {
                    Color.clear.frame(width: 22)
                    TextField(ShoppingInputParser.split(draft.newItem).count > 1 ? "Write quantities beside each item" : "Qty", text: $draft.newQty)
                        .disabled(ShoppingInputParser.split(draft.newItem).count > 1)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .focused($focusedField, equals: .addQty)
                        .onSubmit { commitAdd() }
                        .onKeyPress(.escape) { cancelAdd(); return .handled }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
        .shadow(color: .black.opacity(0.045), radius: 14, y: 4)
        .contentShape(Rectangle())
        .onTapGesture { if !draft.isAdding && !voice.isActive { startAdding() } }
        .background(MacClickOutside(active: draft.isAdding, action: dismissAdd))
        .animation(.easeOut(duration: 0.18), value: draft.isAdding)
    }

    // MARK: Category card

    private func categoryCard(group: (category: ItemCategory, items: [ShoppingItem])) -> some View {
        let catKey = group.category.rawValue
        let isCollapsed = collapsedSections.contains(catKey)

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isCollapsed { collapsedSections.remove(catKey) }
                    else           { collapsedSections.insert(catKey) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(group.category.emoji).font(.subheadline)
                    Text(catKey)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(hugeIcon: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(group.category.color.opacity(0.7))
                        .rotationEffect(isCollapsed ? .degrees(-90) : .zero)
                        .animation(.easeInOut(duration: 0.2), value: isCollapsed)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(MacSidebarButtonStyle())

            if !isCollapsed {
                Divider().padding(.horizontal, 12).opacity(0.25)

                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    VStack(spacing: 0) {
                        if index > 0 {
                            Divider().padding(.leading, 44).opacity(0.15)
                        }
                        unifiedItemRow(for: item)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .contextMenu {
                                Button("Edit") { beginEditing(item) }
                                Button("Delete", role: .destructive) {
                                    Task { await store.deleteItem(item) }
                                }
                            }
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .background(group.category.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    // MARK: Unified item row

    private func unifiedItemRow(for item: ShoppingItem) -> some View {
        let isEditing = editingItemID == item.id
        let isComplete = item.checked

        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 10) {
                // The circle toggles completion; the rest of the row opens the editor.
                Button { store.pendingToggle(item) } label: {
                  Image(hugeIcon: isComplete ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isComplete ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .font(.body)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
                }.buttonStyle(MacCheckboxStyle()).help("Check off \(item.name)").accessibilityLabel("Check off \(item.name)")

                if isEditing {
                    MacRowNameField(text: $editName, focus: $focusedField,
                                    onSubmit: commitEdit, onCancel: cancelEdit)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.name)
                            .foregroundStyle(isComplete ? .secondary : .primary)
                        if let qty = item.quantity, !qty.isEmpty {
                            Text(qty).font(.subheadline).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }

            if isEditing {
                HStack(spacing: 10) {
                    Color.clear.frame(width: 22)
                    TextField("Qty", text: $editQty)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .focused($focusedField, equals: .editQty)
                        .onSubmit { focusedField = .editNotes }
                        .onKeyPress(.escape) { cancelEdit(); return .handled }
                    TextField("Notes", text: $editNotes)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .focused($focusedField, equals: .editNotes)
                        .onSubmit { commitEdit() }
                        .onKeyPress(.escape) { cancelEdit(); return .handled }
                }
            } else if let notes = item.notes, !notes.isEmpty {
                HStack(spacing: 10) {
                    Color.clear.frame(width: 22)
                    Text(notes).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(isEditing ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
        .modifier(MacRowHover())
        .contentShape(RoundedRectangle(cornerRadius: 15))
        .onTapGesture { if !isEditing { beginEditing(item) } }
        .background(MacClickOutside(active: isEditing, action: commitEdit))
    }

    // MARK: Empty state

    private var emptyState: some View {
        MacEmptyState(title: "A fresh start.", message: "What are we picking up? Add an item below, or press ⌘N.")
            .padding(.vertical, 64)
    }

    // MARK: Focus handling

    private func handleFocusChange(old: MacFocusField?, new: MacFocusField?) {
        if isEditField(old) && !isEditField(new) && editingItemID != nil {
            commitEdit()
        }
        if isAddField(old) && !isAddField(new) && draft.isAdding {
            dismissAdd()
        }
    }

    private func isAddField(_ f: MacFocusField?) -> Bool { f == .addName || f == .addQty }
    private func isEditField(_ f: MacFocusField?) -> Bool {
        f == .editName || f == .editQty || f == .editNotes
    }

    // MARK: Add actions

    private func toggleVoice() {
        if voice.isActive {
            voice.stop()
        } else {
            draft.isAdding = false
            focusedField = nil
            voice.start(store: store, api: services.api)
        }
    }

    private func startAdding() {
        guard !voice.isActive else { return }
        voice.dismissFeedback()
        commitEdit()
        guard !draft.isAdding else { focusedField = .addName; return }
        draft.isAdding = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focusedField = .addName }
    }

    private func commitAdd(refocus: Bool = true) {
        let trimmed = draft.newItem.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            if !refocus { cancelAdd() }
            return
        }
        let qty = draft.newQty.trimmingCharacters(in: .whitespaces)
        draft.newItem = ""; draft.newQty = ""
        if refocus {
            Task { @MainActor in focusedField = .addName }
        } else {
            draft.isAdding = false; focusedField = nil
        }
        Task {
            let names = ShoppingInputParser.split(trimmed)
            var failed: [String] = []
            for name in names {
                if await store.addItem(name: name, quantity: names.count == 1 && !qty.isEmpty ? qty : nil) == nil { failed.append(name) }
            }
            if !failed.isEmpty {
                let current = draft.newItem.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.newItem = ([current].filter { !$0.isEmpty } + failed).joined(separator: ", ")
                if names.count == 1 && current.isEmpty { draft.newQty = qty }
                draft.isAdding = true
            }
        }
    }

    private func dismissAdd() {
        // Collapse without submitting or losing an unfinished draft.
        draft.isAdding = false
        if isAddField(focusedField) { focusedField = nil }
    }

    private func cancelAdd() {
        draft.newItem = ""; draft.newQty = ""; draft.isAdding = false; focusedField = nil
    }

    // MARK: Edit actions

    private func beginEditing(_ item: ShoppingItem) {
        if draft.isAdding {
            draft.isAdding = false
            focusedField = nil
        }
        commitEdit()
        editingItemID = item.id
        editName  = item.name
        editQty   = item.quantity ?? ""
        editNotes = item.notes    ?? ""
        focusedField = .editName
    }

    private func commitEdit() {
        guard let id = editingItemID,
              let item = store.items.first(where: { $0.id == id })
        else { editingItemID = nil; return }
        let trimName  = editName.trimmingCharacters(in: .whitespaces)
        let trimQty   = editQty.trimmingCharacters(in: .whitespaces)
        let trimNotes = editNotes.trimmingCharacters(in: .whitespaces)
        editingItemID = nil; focusedField = nil
        guard !trimName.isEmpty else { return }
        guard trimName != item.name || trimQty != (item.quantity ?? "") || trimNotes != (item.notes ?? "") else { return }
        Task {
            await store.updateItem(
                item,
                name:     trimName,
                quantity: trimQty.isEmpty   ? nil : trimQty,
                notes:    trimNotes.isEmpty ? nil : trimNotes
            )
        }
    }

    private func cancelEdit() {
        editingItemID = nil; focusedField = nil
    }
}

// MARK: - Settings sheet

struct MacSettingsView: View {
    let household: Household
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var frequency: ShoppingFrequency
    @AppStorage("mac_always_on_top") private var alwaysOnTop = true
    @State private var confirmSignOut = false

    init(household: Household) {
        self.household = household
        _frequency = State(initialValue: household.shoppingFrequency)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Settings").font(.system(.title2, design: .rounded, weight: .bold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(MacButtonStyle(.primary))
            }

            GroupBox("Household") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Name") { Text(household.name) }
                    HStack {
                        LabeledContent("Invite Code") {
                            Text(household.inviteCode)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(household.inviteCode, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        } label: {
                            Image(hugeIcon: copied ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(copied ? .green : .accentColor)
                        }
                        .buttonStyle(MacButtonStyle(.subtle, compact: true))
                    }
                    Text("Share this code with household partners so they can join.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            GroupBox("Shopping Frequency") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("How often do you shop?", selection: $frequency) {
                        ForEach(ShoppingFrequency.allCases) { freq in
                            Text(freq.label).tag(freq)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: frequency) { _, newValue in
                        Task { await services.auth.updateShoppingFrequency(newValue) }
                    }
                    Text("Used to predict what you'll need before your next big shop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            Toggle("Keep Trolley above other windows", isOn: $alwaysOnTop)
            if let error = services.auth.error { Text(error).foregroundStyle(.red).font(.callout) }
            LabeledContent("Signed in as", value: services.auth.currentUser?.email ?? "")
            LabeledContent("Version", value: MacStyle.version)
            Spacer()
            Button("Sign Out…", role: .destructive) { confirmSignOut = true }
            .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(width: 460, height: 500)
        .confirmationDialog("Sign out of Trolley?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { services.auth.logout(); dismiss() }
        }
    }
}

// MARK: - Mac History View

struct MacHistoryView: View {
    let householdId: String
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var days: [HistoryDay] = []
    @State private var selectedDate: String? = nil
    @State private var dayItems: [HistoryItem] = []
    @State private var isLoadingDays = true
    @State private var isLoadingItems = false
    @State private var historyError: String?

    private var groupedDayItems: [(category: ItemCategory, items: [HistoryItem])] {
        let grouped = Dictionary(grouping: dayItems) { ItemCategory(rawValue: $0.category) ?? .other }
        return grouped
            .sorted { $0.key.aisleOrder < $1.key.aisleOrder }
            .map { (category: $0.key, items: $0.value.sorted { $0.productName < $1.productName }) }
    }

    var body: some View {
        HSplitView {
            // Day list (left panel)
            VStack(alignment: .leading, spacing: 0) {
                Text("History")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                Divider()
                if let historyError {
                    Text(historyError).foregroundStyle(.red).padding(12)
                    Button("Retry") { Task { await loadDays() } }.padding(.horizontal)
                }
                if isLoadingDays {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 20)
                } else if days.isEmpty {
                    Text("No history yet.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .padding(16)
                } else {
                    List(selection: $selectedDate) {
                        ForEach(days) { day in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(day.dayOfWeek)
                                    .font(.callout.weight(.medium))
                                Text(day.displayDate)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(day.itemCount) item\(day.itemCount == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(day.date)
                            .padding(.vertical, 2)
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 160, idealWidth: 180, maxWidth: 200)

            // Day detail (right panel)
            VStack(alignment: .leading, spacing: 0) {
                if let date = selectedDate {
                    let displayDate = days.first(where: { $0.date == date })?.displayDate ?? date
                    Text(displayDate)
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    Divider()
                    if isLoadingItems {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 20)
                    } else if dayItems.isEmpty {
                        Text("No items found.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                            .padding(16)
                    } else {
                        List {
                            ForEach(groupedDayItems, id: \.category) { group in
                                Section {
                                    ForEach(group.items) { item in
                                        HStack {
                                            Text(item.productName)
                                            if let qty = item.quantity, !qty.isEmpty {
                                                Text(qty).foregroundStyle(.secondary).font(.callout)
                                            }
                                            Spacer()
                                            if let price = item.pricePaid {
                                                Text(String(format: "$%.2f", price))
                                                    .foregroundStyle(.secondary)
                                                    .font(.callout)
                                            }
                                        }
                                    }
                                } header: {
                                    Label { Text(group.category.rawValue) } icon: { Text(group.category.emoji) }
                                        .foregroundStyle(group.category.color)
                                }
                            }
                        }
                    }
                } else {
                    Text("Select a day to see what you purchased.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 240, idealWidth: 300)
        }
        .navigationTitle("Purchase history")
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
        .task { await loadDays() }
        .task(id: selectedDate) {
            guard let date = selectedDate else { return }
            isLoadingItems = true; dayItems = []; historyError = nil
            do {
                let loaded = try await services.api.fetchHistoryDay(householdId: householdId, date: date)
                guard !Task.isCancelled else { return }
                dayItems = loaded
            } catch { if !Task.isCancelled { historyError = error.localizedDescription } }
            if !Task.isCancelled { isLoadingItems = false }
        }
    }
    private func loadDays() async {
        isLoadingDays = true; historyError = nil
        do {
            days = try await services.api.fetchHistoryDays(householdId: householdId)
            if selectedDate == nil { selectedDate = days.first?.date }
        } catch { historyError = error.localizedDescription }
        isLoadingDays = false
    }
}

// Observe clicks without consuming them, so the clicked control still receives
// its normal action. Geometry is the actual editor, including its padded area.
private struct MacClickOutside: NSViewRepresentable {
    let active: Bool
    let action: () -> Void
    func makeNSView(context: Context) -> OutsideClickView { OutsideClickView() }
    func updateNSView(_ view: OutsideClickView, context: Context) {
        view.action = action
        view.setActive(active)
    }
    static func dismantleNSView(_ view: OutsideClickView, coordinator: ()) { view.setActive(false) }

    final class OutsideClickView: NSView {
        var action: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func setActive(_ active: Bool) {
            if !active, let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard active, monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.action?() }
                return event
            }
        }
    }
}

private struct MacCheckboxStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Surface(configuration: configuration) }
    private struct Surface: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(Circle().fill(Color.accentColor.opacity(configuration.isPressed ? 0.24 : hovered ? 0.12 : 0)))
                .contentShape(Circle())
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.12), value: hovered)
        }
    }
}

// Native text field avoids SwiftUI's automatic select-all when a row enters edit
// mode. Subsequent clicks still position the insertion point normally.
private struct MacRowNameField: NSViewRepresentable {
    @Binding var text: String
    var focus: FocusState<MacFocusField?>.Binding
    let onSubmit: () -> Void
    let onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NameField {
        let field = NameField()
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = "Name"
        field.setAccessibilityLabel("Name")
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NameField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        guard !context.coordinator.didFocus else { return }
        context.coordinator.didFocus = true
        DispatchQueue.main.async {
            guard field.window != nil else { return }
            field.selectText(nil)
        }
    }
    final class NameField: NSTextField {
        override func selectText(_ sender: Any?) {
            super.selectText(sender)
            if let editor = currentEditor() as? NSTextView {
                editor.setSelectedRange(NSRange(location: stringValue.utf16.count, length: 0))
                editor.isAutomaticTextCompletionEnabled = false
                editor.isAutomaticSpellingCorrectionEnabled = false
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MacRowNameField
        var didFocus = false
        init(_ parent: MacRowNameField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.focus.wrappedValue = .editName }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            if command == #selector(NSResponder.insertNewline(_:)) { parent.onSubmit(); return true }
            if command == #selector(NSResponder.cancelOperation(_:)) { parent.onCancel(); return true }
            return false
        }
    }
}
