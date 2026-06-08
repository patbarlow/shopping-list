import SwiftUI
import AppKit

// MARK: - Window level accessor

private struct WindowLevelAccessor: NSViewRepresentable {
    let alwaysOnTop: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            view.window?.level = alwaysOnTop ? .floating : .normal
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
        NavigationStack {
            Group {
                if services.auth.isLoggedIn {
                    if let household = services.auth.household {
                        MacListView(household: household)
                    } else {
                        MacHouseholdSetupView()
                            .navigationTitle("Shopping List")
                    }
                } else {
                    MacLoginView()
                        .navigationTitle("Shopping List")
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
            Image(systemName: "cart.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Shopping List")
                .font(.title2.bold())

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
                .buttonStyle(.borderedProminent)
                .disabled(services.auth.isLoading || email.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(24)
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
            Image(systemName: "envelope.badge")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Check your email")
                .font(.title2.bold())
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
                .buttonStyle(.borderedProminent)
                .disabled(services.auth.isLoading || code.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: [])

                Button("Use a different email") {
                    services.auth.step = .enterEmail
                    services.auth.error = nil
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
        .padding(24)
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
            Image(systemName: "house.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Your Household")
                .font(.title2.bold())

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
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || services.auth.isLoading)
            } else {
                TextField("Invite code", text: $inviteCode)
                    .textFieldStyle(.roundedBorder)
                    .textCase(.uppercase)
                Button("Join") { Task { await services.auth.joinHousehold(inviteCode: inviteCode) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(inviteCode.isEmpty || services.auth.isLoading)
            }

            if services.auth.isLoading { ProgressView() }

            Divider()
            Button("Sign Out", role: .destructive) { services.auth.logout() }
                .font(.footnote)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Main list

private struct MacListView: View {
    let household: Household
    @Environment(AppServices.self) private var services

    // ── Add ──────────────────────────────────────────────────────────────────
    @State private var isAdding = false
    @State private var newItem  = ""
    @State private var newQty   = ""

    // ── Edit ─────────────────────────────────────────────────────────────────
    @State private var editingItemID: String? = nil
    @State private var editName  = ""
    @State private var editQty   = ""
    @State private var editNotes = ""

    // ── Focus ─────────────────────────────────────────────────────────────────
    @FocusState private var focusedField: MacFocusField?

    // ── UI ────────────────────────────────────────────────────────────────────
    @State private var collapsedSections: Set<String> = []
    @State private var showSettings = false
    @AppStorage("mac_always_on_top") private var alwaysOnTop = true

    private var store: ShoppingListStore { services.shopping }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    if store.items.isEmpty && !store.isLoading {
                        emptyState
                    } else {
                        ForEach(store.groupedItems, id: \.category) { group in
                            categoryCard(group: group)
                        }
                    }
                    Color.clear.frame(height: 4)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            Divider().opacity(0.4)
            addBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .navigationTitle("Shopping List")
        .toolbar { toolbarItems }
        .toolbarBackground(Color(.windowBackgroundColor), for: .windowToolbar)
        .sheet(isPresented: $showSettings) {
            MacSettingsView(household: household)
                .environment(services)
        }
        .task { await store.load(householdId: household.id) }
        .onChange(of: focusedField) { old, new in handleFocusChange(old: old, new: new) }
        .animation(.default, value: store.groupedItems.map {
            "\($0.category.rawValue)\($0.items.map { "\($0.id)\($0.checked)" }.joined())"
        })
        .background(WindowLevelAccessor(alwaysOnTop: alwaysOnTop))
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gear")
                }
                Divider()
                Button {
                    withAnimation { store.showCompleted.toggle() }
                } label: {
                    Label(
                        store.showCompleted ? "Hide Completed" : "Show Completed",
                        systemImage: store.showCompleted ? "eye.slash" : "eye"
                    )
                }
                if store.checkedCount > 0 {
                    Button(role: .destructive) {
                        Task { await store.clearChecked() }
                    } label: {
                        Label("Clear Completed", systemImage: "trash")
                    }
                }
                Divider()
                Toggle(isOn: $alwaysOnTop) {
                    Label("Always on Top", systemImage: "pin")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
        }
    }

    // MARK: Add bar (persistent bottom)

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: isAdding ? "circle" : "plus")
                    .foregroundStyle(isAdding ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.green))
                    .font(isAdding ? .body : .body.weight(.semibold))
                    .frame(width: 22, height: 22)

                if isAdding {
                    TextField("Item name", text: $newItem)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .addName)
                        .onSubmit { commitAdd() }
                        .onKeyPress(.escape) { cancelAdd(); return .handled }
                } else {
                    Text("Add item…")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, isAdding ? 10 : 12)

            if isAdding {
                Divider().padding(.horizontal, 12).opacity(0.25)
                HStack(spacing: 10) {
                    Color.clear.frame(width: 22)
                    TextField("Qty", text: $newQty)
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
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { if !isAdding { startAdding() } }
        .animation(.easeOut(duration: 0.18), value: isAdding)
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(group.category.color)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(group.category.color.opacity(0.7))
                        .rotationEffect(isCollapsed ? .degrees(-90) : .zero)
                        .animation(.easeInOut(duration: 0.2), value: isCollapsed)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                Divider().padding(.horizontal, 12).opacity(0.25)

                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    VStack(spacing: 0) {
                        if index > 0 {
                            Divider().padding(.leading, 44).opacity(0.15)
                        }
                        unifiedItemRow(for: item)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    Task { await store.deleteItem(item) }
                                }
                            }
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .background(group.category.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Unified item row

    private func unifiedItemRow(for item: ShoppingItem) -> some View {
        let isEditing = editingItemID == item.id
        let isComplete = item.checked

        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 10) {
                // Circle toggles complete; tapping row text enters edit mode
                Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isComplete ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                    .font(.body)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
                    .onTapGesture { Task { await store.toggleItem(item) } }

                if isEditing {
                    TextField("Name", text: $editName)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .editName)
                        .onSubmit { commitEdit() }
                        .onKeyPress(.escape) { cancelEdit(); return .handled }
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
                    .onTapGesture { beginEditing(item) }
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
        .padding(.vertical, 6)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "cart")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(.quaternary)
            Text("Your list is empty")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: Focus handling

    private func handleFocusChange(old: MacFocusField?, new: MacFocusField?) {
        if isEditField(old) && !isEditField(new) && editingItemID != nil {
            commitEdit()
        }
        if isAddField(old) && !isAddField(new) && isAdding {
            let trimmed = newItem.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { cancelAdd() } else { commitAdd(refocus: false) }
        }
    }

    private func isAddField(_ f: MacFocusField?) -> Bool { f == .addName || f == .addQty }
    private func isEditField(_ f: MacFocusField?) -> Bool {
        f == .editName || f == .editQty || f == .editNotes
    }

    // MARK: Add actions

    private func startAdding() {
        commitEdit()
        guard !isAdding else { focusedField = .addName; return }
        newItem = ""; newQty = ""
        isAdding = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focusedField = .addName }
    }

    private func commitAdd(refocus: Bool = true) {
        let trimmed = newItem.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            if !refocus { cancelAdd() }
            return
        }
        let qty = newQty.trimmingCharacters(in: .whitespaces)
        newItem = ""; newQty = ""
        if refocus {
            Task { @MainActor in focusedField = .addName }
        } else {
            isAdding = false; focusedField = nil
        }
        Task { await store.addItem(name: trimmed, quantity: qty.isEmpty ? nil : qty) }
    }

    private func cancelAdd() {
        newItem = ""; newQty = ""; isAdding = false; focusedField = nil
    }

    // MARK: Edit actions

    private func beginEditing(_ item: ShoppingItem) {
        if isAdding {
            let t = newItem.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { cancelAdd() } else { commitAdd() }
        }
        commitEdit()
        editingItemID = item.id
        editName  = item.name
        editQty   = item.quantity ?? ""
        editNotes = item.notes    ?? ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focusedField = .editName }
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

private struct MacSettingsView: View {
    let household: Household
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Settings").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
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
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(copied ? .green : .accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Share this code with household partners so they can join.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            Spacer()

            Button("Sign Out", role: .destructive) {
                services.auth.logout()
                dismiss()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(width: 340, height: 280)
    }
}
