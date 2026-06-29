import SwiftUI

// Focus field enum: covers the bottom-accessory add row and the inline-edit row.
private enum FocusField: Hashable {
    case newName, newQty, newNotes
    case editName, editQty, editNotes
}

struct ShoppingListView: View {
    let household: Household
    @Environment(AppServices.self) private var services
    @State private var showSettings = false
    @State private var showRecipeHub = false
    @State private var showReceiptScanner = false
    @State private var showInsights = false
    @State private var selectedHistoryDate: String? = nil
    @State private var historyDays: [HistoryDay] = []

    // ── Inline add ─────────────────────────────────────────────────────────────
    @State private var isAdding  = false
    @State private var addText   = ""
    @State private var addQty    = ""
    @State private var addNotes  = ""

    // ── Inline edit ────────────────────────────────────────────────────────────
    @State private var editingItemID: String? = nil
    @State private var editName  = ""
    @State private var editQty   = ""
    @State private var editNotes = ""

    // ── Unified focus ──────────────────────────────────────────────────────────
    @FocusState private var focusedField: FocusField?
    @State private var focusLossTask: Task<Void, Never>? = nil

    // ── Collapsible sections ───────────────────────────────────────────────────
    @State private var collapsedSections: Set<String> = []

    // ── Pending complete (brief fill animation before item leaves) ─────────────
    @State private var pendingCompleteIDs: Set<String> = []

    // ── Input commit guard (prevents focus-loss cancel during enter-to-add) ───
    @State private var isCommitting = false

    // ── Duplicate-item toast ───────────────────────────────────────────────────
    @State private var duplicateToastName: String? = nil

    // ── Swipe-to-delete tracking ───────────────────────────────────────────────
    @State private var swipeOffsets: [String: CGFloat] = [:]
    @State private var swipePassedThreshold: Set<String> = []

    // ── Sidebar Interaction ───────────────────────────────────────────────────
    @State private var isSidebarOpen = false
    @State private var dragOffset: CGFloat = 0
    private let sidebarWidth: CGFloat = 280

    // Single source of truth for "how far open"
    private var currentOffset: CGFloat {
        let base = isSidebarOpen ? sidebarWidth : 0
        return min(max(base + dragOffset, 0), sidebarWidth)
    }

    private var progress: CGFloat { currentOffset / sidebarWidth }
    private var deviceCornerRadius: CGFloat {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen
        return (screen?.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 44
    }

    private var store: ShoppingListStore { services.shopping }

    // Multi-item paste preview — shown when paste produces >1 item
    private var parsedAddItems: [String] {
        guard isAdding else { return [] }
        return Self.parseMultipleItems(addText)
    }

    // Suggestions shown above the text field when ≥2 chars typed
    private var suggestions: [String] {
        guard addText.count >= 2 else { return [] }
        let q = addText.lowercased()
        return store.allKnownNames
            .filter { $0.lowercased().hasPrefix(q) && $0.lowercased() != q }
            .prefix(3)
            .map { $0 }
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .leading) {
            // Background fill — sidebar color bleeds into content card corner radius gap
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            // 1. Stationary sidebar — dims to black when closed, clears as it opens
            SidebarView(
                household: household,
                historyDays: historyDays,
                selectedDate: $selectedHistoryDate,
                isOpen: $isSidebarOpen,
                showSettings: $showSettings,
                showInsights: $showInsights
            )
            .frame(width: sidebarWidth)
            .overlay(Color.black.opacity(0.4 * (1 - progress)))

            // 2. Main content card — slides right to reveal sidebar
            NavigationStack {
                Group {
                    if let date = selectedHistoryDate {
                        HistoryDayView(householdId: household.id, date: date) {
                            selectedHistoryDate = nil
                        }
                        .environment(services)
                    } else {
                        mainList
                            .overlay(alignment: .bottom) {
                                LinearGradient(
                                    colors: [.clear, Color(.systemBackground)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(height: 80)
                                .padding(.bottom, -56)
                                .allowsHitTesting(false)
                            }
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                addItemAccessory
                            }
                    }
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .sheet(isPresented: $showSettings) {
                    SettingsView(household: household).environment(services)
                }
                .sheet(isPresented: $showRecipeHub) {
                    RecipeHubView(householdId: household.id).environment(services)
                }
                .sheet(isPresented: $showReceiptScanner) {
                    ReceiptScannerView(householdId: household.id).environment(services)
                }
                .sheet(isPresented: $showInsights) {
                    ProductsListView(householdId: household.id).environment(services)
                }
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: progress > 0 ? deviceCornerRadius : 0, style: .continuous))
            .shadow(color: .black.opacity(0.25 * progress), radius: 16, x: -4, y: 0)
            .offset(x: currentOffset)
            .allowsHitTesting(!isSidebarOpen)

            // 3. Thin edge strip — opens sidebar via drag from the left edge
            if !isSidebarOpen {
                Color.clear
                    .frame(width: 20)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(openDragGesture)
            }

            // 4. Tap/drag overlay over the visible content strip — closes sidebar when open
            if isSidebarOpen {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: sidebarWidth)
                        .allowsHitTesting(false)
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .gesture(closeDragGesture)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .task {
            await store.load(householdId: household.id)
            historyDays = (try? await services.api.fetchHistoryDays(householdId: household.id)) ?? []
        }
        .onChange(of: focusedField) { old, new in handleFocusChange(old: old, new: new) }
        .onChange(of: addText) { old, new in
            // iOS TextField strips newlines on paste — detect multiline pastes via clipboard
            guard isAdding,
                  new.count - old.count > 2,
                  let clip = UIPasteboard.general.string,
                  clip.contains("\n") else { return }
            let items = Self.parseMultipleItems(clip)
            guard items.count > 1 else { return }
            addText = ""; addQty = ""; addNotes = ""
            isAdding = false; focusedField = nil
            for name in items { Task { await store.addItem(name: name) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shoppingListQuickAdd)) { _ in
            startAdding()
        }
        .onOpenURL { url in
            if url.host == "quick-add" { startAdding() }
        }
        .onChange(of: services.pendingReceiptPDF) { _, pdf in
            if pdf != nil { showReceiptScanner = true }
        }
        .onContinueUserActivity("com.patbarlow.shoppinglist.quickAdd") { _ in
            startAdding()
        }
    }

    // MARK: - Bottom Accessory

    private var addItemAccessory: some View {
        VStack(alignment: .trailing, spacing: 6) {
            // Duplicate-item toast
            if let dupe = duplicateToastName {
                Button { duplicateToastName = nil } label: {
                    Label("\(dupe) is already on your list", systemImage: "exclamationmark.circle")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                }
                .buttonStyle(.plain)
                .glassEffect(in: Capsule())
                .padding(.trailing, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Undo toast — taller, with live countdown
            if !store.recentlyCompleted.isEmpty {
                Button { store.undoLastComplete() } label: {
                    HStack(spacing: 10) {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.weight(.medium))
                        if let deadline = store.undoDeadline {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text("\(max(0, Int(deadline.timeIntervalSinceNow.rounded(.up))))")
                                    .monospacedDigit()
                                    .frame(width: 14, alignment: .center)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .buttonStyle(.plain)
                .glassEffect(in: Capsule())
                .padding(.trailing, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Suggestions — detached glass container, floats above the input bar
            if isAdding && !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element) { idx, suggestion in
                        if idx > 0 { Divider().padding(.leading, 42).opacity(0.3) }
                        Button {
                            addText = suggestion
                            focusedField = .newName
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "magnifyingglass")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(suggestion)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.left")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(in: RoundedRectangle(cornerRadius: 16))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Input bar
            VStack(alignment: .leading, spacing: 0) {
                // Name row
                HStack(spacing: 12) {
                    if isAdding {
                        Image(systemName: "circle")
                            .foregroundStyle(.tertiary)
                            .font(.body)
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 24, height: 24)
                    }
                    if isAdding {
                        TextField("Item name", text: $addText)
                            .focused($focusedField, equals: .newName)
                            .submitLabel(.done)
                            .onSubmit { commitAdd() }
                        if parsedAddItems.count > 1 {
                            Text("\(parsedAddItems.count) items")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.tint, in: Capsule())
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    } else {
                        Text("Add item…")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, isAdding ? 10 : 16)

                // Extra fields — only when actively adding
                if isAdding {
                    Divider().padding(.horizontal, 16).opacity(0.2)
                    HStack(spacing: 12) {
                        Color.clear.frame(width: 24)
                        TextField("Qty", text: $addQty)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .focused($focusedField, equals: .newQty)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .newNotes }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    Divider().padding(.horizontal, 16).opacity(0.2)
                    HStack(spacing: 12) {
                        Color.clear.frame(width: 24)
                        TextField("Note", text: $addNotes, axis: .vertical)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .focused($focusedField, equals: .newNotes)
                            .lineLimit(1...2)
                            .submitLabel(.done)
                            .onSubmit { commitAdd() }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(in: RoundedRectangle(cornerRadius: 20))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .padding(.top, 6)
            .contentShape(Rectangle())
            .onTapGesture { if !isAdding { startAdding() } }
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .local)
                    .onEnded { value in
                        let dy = value.translation.height
                        let dx = value.translation.width
                        guard abs(dy) > abs(dx) * 0.8 else { return }
                        if dy > 25 && focusedField != nil {
                            focusedField = nil
                        } else if dy < -20 && isAdding && focusedField == nil {
                            focusedField = .newName
                        } else if dy < -20 && !isAdding {
                            startAdding()
                        }
                    }
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.82), value: isAdding)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: suggestions)
        .animation(.spring(duration: 0.35), value: store.recentlyCompleted.isEmpty)
    }

    // MARK: - List

    @ViewBuilder
    private var mainList: some View {
        if store.items.isEmpty && !store.isLoading {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.groupedItems, id: \.category) { group in
                        let catKey = group.category.rawValue
                        let isCollapsed = collapsedSections.contains(catKey)

                        VStack(spacing: 0) {
                            // ── Section header ────────────────────────────────
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if isCollapsed { collapsedSections.remove(catKey) }
                                    else { collapsedSections.insert(catKey) }
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Text(group.category.emoji)
                                        .font(.title3)
                                        .frame(width: 28, alignment: .center)
                                    Text(catKey)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(group.category.color)
                                    Spacer()
                                    Image(systemName: "chevron.down")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(group.category.color.opacity(0.7))
                                        .rotationEffect(isCollapsed ? .degrees(-90) : .zero)
                                        .animation(.easeInOut(duration: 0.2), value: isCollapsed)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            // ── Items ─────────────────────────────────────────
                            if !isCollapsed {
                                Divider()
                                    .padding(.horizontal, 14)
                                    .opacity(0.25)

                                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                    VStack(spacing: 0) {
                                        if index > 0 {
                                            Divider()
                                                .padding(.leading, 52)
                                                .opacity(0.15)
                                        }
                                        let offset = swipeOffsets[item.id] ?? 0
                                        let progress = min(1.0, max(0, -offset / 100))
                                        unifiedItemRow(for: item)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 5)
                                            .background {
                                                Color(.systemBackground)
                                                group.category.color.opacity(0.10)
                                            }
                                            .overlay { Color.red.opacity(progress) }
                                            .overlay(alignment: .trailing) {
                                                Text("Delete")
                                                    .font(.footnote.weight(.semibold))
                                                    .foregroundStyle(.white)
                                                    .padding(.trailing, 28)
                                                    .opacity(max(0, (progress - 0.3) / 0.4))
                                            }
                                            .offset(x: offset)
                                            .frame(maxWidth: .infinity)
                                            .gesture(swipeDeleteGesture(for: item))
                                            .contextMenu {
                                                Button(role: .destructive) {
                                                    Task { await store.deleteItem(item) }
                                                } label: {
                                                    Label("Delete", systemImage: "trash")
                                                }
                                            }
                                    }
                                }
                                .padding(.bottom, 4)
                            }
                        }
                        .background(group.category.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    Color.clear.frame(height: 16)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded {
                guard focusedField != nil else { return }
                focusedField = nil
            })
            .refreshable { await store.fetch() }
            .animation(.default, value: store.items.map { $0.id + ($0.checked ? "1" : "0") })
        }
    }

    // MARK: - Unified item row (display + edit in one persistent view)

    private func unifiedItemRow(for item: ShoppingItem) -> some View {
        let isEditing = editingItemID == item.id
        let isComplete = item.checked
        let isVisuallyComplete = isComplete || pendingCompleteIDs.contains(item.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 10) {
                if isEditing {
                    Button {
                        triggerComplete(item)
                    } label: {
                        Image(systemName: isVisuallyComplete ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isVisuallyComplete ? .green : Color(.systemGray3))
                            .font(.title3)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: isVisuallyComplete ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isVisuallyComplete ? .green : Color(.systemGray3))
                        .font(.title3)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                        .onTapGesture { triggerComplete(item) }
                }
                if isEditing {
                    TextField("Name", text: $editName)
                        .focused($focusedField, equals: .editName)
                        .submitLabel(.done)
                        .onSubmit { commitCurrentEdit() }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.name)
                            .foregroundStyle(isComplete ? .secondary : .primary)
                        if let qty = item.quantity, !qty.isEmpty {
                            Text(qty)
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if isEditing {
                HStack(spacing: 10) {
                    Color.clear.frame(width: 28)
                    TextField("Qty", text: $editQty)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .focused($focusedField, equals: .editQty)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .editNotes }
                }
                HStack(spacing: 10) {
                    Color.clear.frame(width: 28)
                    TextField("Note", text: $editNotes, axis: .vertical)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .focused($focusedField, equals: .editNotes)
                        .lineLimit(1...3)
                        .submitLabel(.done)
                        .onSubmit { commitCurrentEdit() }
                }
            } else if let notes = item.notes, !notes.isEmpty {
                HStack(spacing: 10) {
                    Color.clear.frame(width: 24)
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture { if !isEditing { beginEditing(item) } }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "cart")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(.quaternary)
            VStack(spacing: 6) {
                Text("Your list is empty")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("Tap \"Add item\u{2026}\" below to get started")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                if !isSidebarOpen { sidebarHaptic() }
                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                    isSidebarOpen = true
                    dragOffset = 0
                }
            } label: {
                Image(systemName: "line.3.horizontal")
            }
        }
        if selectedHistoryDate == nil {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showReceiptScanner = true } label: {
                    Image(systemName: "receipt")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showRecipeHub = true } label: {
                    Image(systemName: "fork.knife")
                }
            }
        }
    }

    // MARK: - Focus change handler

    private func handleFocusChange(old: FocusField?, new: FocusField?) {
        focusLossTask?.cancel()

        if isAddField(old) && !isAddField(new) && isAdding {
            if isCommitting {
                // Restore focus synchronously so SwiftUI can keep the keyboard up
                // before UIKit fully processes the resign from the Return key press.
                focusedField = old
                return
            }
            focusLossTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, isAdding, !isAddField(focusedField) else { return }
                let trimmed = addText.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { cancelAdd() } else { commitAdd(refocus: false) }
            }
        }

        if isEditField(old) && !isEditField(new) && editingItemID != nil {
            focusLossTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, editingItemID != nil, !isEditField(focusedField) else { return }
                commitCurrentEdit()
            }
        }
    }

    private func isAddField(_ f: FocusField?) -> Bool {
        f == .newName || f == .newQty || f == .newNotes
    }

    private func isEditField(_ f: FocusField?) -> Bool {
        f == .editName || f == .editQty || f == .editNotes
    }

    // MARK: - Actions

    private func startAdding() {
        if let id = editingItemID, store.items.contains(where: { $0.id == id }) {
            commitCurrentEdit()
        }
        guard !isAdding else {
            focusedField = .newName
            return
        }
        addText = ""; addQty = ""; addNotes = ""
        isAdding = true
        // Small delay for keyboard animation sync
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focusedField = .newName
        }
    }

    private func commitAdd(refocus: Bool = true) {
        let trimmed = addText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            if !refocus { cancelAdd() }
            return
        }

        // Duplicate check — if already on the list (unchecked), show toast and skip
        let lower = trimmed.lowercased()
        if store.items.contains(where: { $0.name.lowercased() == lower && !$0.checked }) {
            showDuplicateToast(for: trimmed)
            isCommitting = true
            addText = ""; addQty = ""; addNotes = ""
            Task { @MainActor in focusedField = .newName; isCommitting = false }
            return
        }

        isCommitting = true
        let qty = addQty.trimmingCharacters(in: .whitespaces)
        let note = addNotes.trimmingCharacters(in: .whitespaces)

        addText = ""; addQty = ""; addNotes = ""

        if refocus {
            // Keep focus on name field for rapid entry
            Task { @MainActor in
                focusedField = .newName
                isCommitting = false
            }
        } else {
            isAdding = false
            focusedField = nil
            isCommitting = false
        }

        Task {
            await store.addItem(
                name: trimmed,
                quantity: qty.isEmpty ? nil : qty,
                notes: note.isEmpty ? nil : note
            )
        }
    }

    private func cancelAdd() {
        addText = ""; addQty = ""; addNotes = ""
        isAdding = false
        focusedField = nil
    }

    private func beginEditing(_ item: ShoppingItem) {
        if isAdding {
            let trimmed = addText.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { cancelAdd() } else { commitAdd(refocus: false) }
        }
        if let currentID = editingItemID, currentID != item.id {
            commitCurrentEdit()
        }

        editingItemID = item.id
        editName = item.name
        editQty = item.quantity ?? ""
        editNotes = item.notes ?? ""

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focusedField = .editName
        }
    }

    private func commitCurrentEdit() {
        guard let id = editingItemID,
              let item = store.items.first(where: { $0.id == id })
        else {
            editingItemID = nil
            return
        }

        let name = editName.trimmingCharacters(in: .whitespaces)
        let qty = editQty.trimmingCharacters(in: .whitespaces)
        let note = editNotes.trimmingCharacters(in: .whitespaces)

        editingItemID = nil
        focusedField = nil

        guard !name.isEmpty else { return }

        Task {
            await store.updateItem(
                item,
                name: name,
                quantity: qty.isEmpty ? nil : qty,
                notes: note.isEmpty ? nil : note
            )
        }
    }

    private func triggerComplete(_ item: ShoppingItem) {
        withAnimation(.easeInOut(duration: 0.2)) {
            _ = pendingCompleteIDs.insert(item.id)
        }
        // Wait for a beat so the user sees the 'fill' before it moves
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            store.pendingToggle(item)
            pendingCompleteIDs.remove(item.id)
        }
    }

    private func swipeDeleteGesture(for item: ShoppingItem) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                let translation = value.translation.width
                if translation < 0 {
                    swipeOffsets[item.id] = translation
                    if translation < -100 {
                        swipePassedThreshold.insert(item.id)
                    } else {
                        swipePassedThreshold.remove(item.id)
                    }
                }
            }
            .onEnded { value in
                if value.translation.width < -100 {
                    withAnimation(.spring()) {
                        swipeOffsets[item.id] = -500
                    }
                    Task {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        await store.deleteItem(item)
                        swipeOffsets.removeValue(forKey: item.id)
                    }
                } else {
                    withAnimation(.spring()) {
                        swipeOffsets[item.id] = 0
                    }
                }
                swipePassedThreshold.remove(item.id)
            }
    }

    // MARK: - Sidebar gesture helpers

    private var openDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in dragOffset = max(0, value.translation.width) }
            .onEnded { value in settle(value) }
    }

    private var closeDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in dragOffset = min(0, value.translation.width) }
            .onEnded { value in settle(value) }
    }

    private func settle(_ value: DragGesture.Value) {
        let projected = currentOffset + (value.predictedEndTranslation.width - value.translation.width)
        let willOpen = projected > sidebarWidth / 2
        if willOpen != isSidebarOpen { sidebarHaptic() }
        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
            isSidebarOpen = willOpen
            dragOffset = 0
        }
    }

    private func close() {
        sidebarHaptic()
        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
            isSidebarOpen = false
            dragOffset = 0
        }
    }

    private func sidebarHaptic() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func showDuplicateToast(for name: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            duplicateToastName = name
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if duplicateToastName == name {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    duplicateToastName = nil
                }
            }
        }
    }

    // MARK: - Helpers

    static func parseMultipleItems(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
