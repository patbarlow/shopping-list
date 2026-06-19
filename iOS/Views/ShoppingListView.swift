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
    @State private var showRecipeImport = false
    @State private var showReceiptScanner = false

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
        NavigationStack {
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
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .sheet(isPresented: $showSettings) {
                    SettingsView(household: household).environment(services)
                }
                .sheet(isPresented: $showRecipeImport) {
                    RecipeImportView(householdId: household.id).environment(services)
                }
                .sheet(isPresented: $showReceiptScanner) {
                    ReceiptScannerView(householdId: household.id).environment(services)
                }
        }
        .task {
            await store.load(householdId: household.id)
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
                                        .font(.body)
                                        .frame(width: 24, alignment: .center)
                                    Text(catKey)
                                        .font(.callout.weight(.semibold))
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
                                                .padding(.leading, 46)
                                                .opacity(0.15)
                                        }
                                        unifiedItemRow(for: item)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 5)
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            Task { await store.deleteItem(item) }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
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
                            .font(.body)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: isVisuallyComplete ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isVisuallyComplete ? .green : Color(.systemGray3))
                        .font(.body)
                        .frame(width: 24, height: 24)
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
                    Color.clear.frame(width: 24)
                    TextField("Qty", text: $editQty)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .focused($focusedField, equals: .editQty)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .editNotes }
                }
                HStack(spacing: 10) {
                    Color.clear.frame(width: 24)
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
            Button { showSettings = true } label: { Image(systemName: "gear") }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button { showRecipeImport = true } label: {
                    Label("Import Recipe (URL)", systemImage: "link")
                }
                Button { showReceiptScanner = true } label: {
                    Label("Scan Receipt", systemImage: "receipt")
                }
            } label: {
                Image(systemName: "plus.circle")
            }
        }
    }

    // MARK: - Focus change handler

    private func handleFocusChange(old: FocusField?, new: FocusField?) {
        focusLossTask?.cancel()

        if isAddField(old) && !isAddField(new) && isAdding {
            guard !isCommitting else { return }
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

    // MARK: - Add actions

    private func startAdding() {
        commitCurrentEdit()
        if isAdding { focusedField = .newName; return }
        addText = ""; addQty = ""; addNotes = ""
        isAdding = true
        Task { @MainActor in focusedField = .newName }
    }

    private func commitAdd(refocus: Bool = true) {
        let trimmed = addText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { cancelAdd(); return }
        let items = Self.parseMultipleItems(trimmed)
        addText = ""; addQty = ""; addNotes = ""
        if items.count > 1 {
            for name in items {
                Task { await store.addItem(name: name) }
            }
        } else {
            let (parsedName, parsedQty) = parseQtyName(trimmed)
            let finalQty   = !addQty.trimmingCharacters(in: .whitespaces).isEmpty
                                ? addQty.trimmingCharacters(in: .whitespaces)
                                : parsedQty
            let finalNotes = addNotes.trimmingCharacters(in: .whitespaces)
            Task {
                await store.addItem(
                    name:     parsedName,
                    quantity: finalQty.flatMap  { $0.isEmpty ? nil : $0 },
                    notes:    finalNotes.isEmpty ? nil : finalNotes
                )
            }
        }
        if refocus {
            isCommitting = true
            focusLossTask?.cancel()
            Task { @MainActor in
                focusedField = .newName
                isCommitting = false
            }
        } else {
            isAdding = false
        }
    }

    private func cancelAdd() {
        focusLossTask?.cancel()
        addText = ""; addQty = ""; addNotes = ""
        isAdding = false
        focusedField = nil
    }

    private func triggerComplete(_ item: ShoppingItem) {
        guard !item.checked else { store.pendingToggle(item); return }
        withAnimation(.easeIn(duration: 0.12)) { pendingCompleteIDs.insert(item.id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            pendingCompleteIDs.remove(item.id)
            store.pendingToggle(item)
        }
    }

    // MARK: - Edit actions

    private func beginEditing(_ item: ShoppingItem) {
        focusLossTask?.cancel()
        let addTrimmed = addText.trimmingCharacters(in: .whitespaces)
        if isAdding {
            if addTrimmed.isEmpty { cancelAdd() } else { commitAdd(refocus: false) }
        }
        commitCurrentEdit()
        editingItemID = item.id
        editName  = item.name
        editQty   = item.quantity ?? ""
        editNotes = item.notes    ?? ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focusedField = .editName
        }
    }

    private func commitCurrentEdit() {
        guard let id = editingItemID,
              let item = store.items.first(where: { $0.id == id })
        else { editingItemID = nil; return }
        focusLossTask?.cancel()
        let trimName  = editName.trimmingCharacters(in: .whitespaces)
        let trimQty   = editQty.trimmingCharacters(in: .whitespaces)
        let trimNotes = editNotes.trimmingCharacters(in: .whitespaces)
        editingItemID = nil
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

    // MARK: - Parsing helpers

    /// Splits pasted text on newlines (preferred) or commas into individual item names.
    /// Strips leading bullet characters and numbered-list prefixes from each line.
    static func parseMultipleItems(_ raw: String) -> [String] {
        let newlineItems = raw.components(separatedBy: .newlines)
            .map { stripBulletPrefix($0) }
            .filter { !$0.isEmpty }
        if newlineItems.count > 1 { return newlineItems }
        return raw
            .replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " & ", with: ",")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func stripBulletPrefix(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        let bullets = ["• ", "•", "- ", "* ", "– ", "— ", "◦ ", "▪ ", "▸ ", "► "]
        for b in bullets where t.hasPrefix(b) {
            return String(t.dropFirst(b.count)).trimmingCharacters(in: .whitespaces)
        }
        // Numbered list: "1. " or "1) "
        if let range = t.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            return String(t[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    /// "250ml olive oil" → (name: "Olive Oil", qty: "250ml")
    private func parseQtyName(_ input: String) -> (name: String, qty: String?) {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let pattern = #"^(\d+(?:[.,]\d+)?\s*(?:ml|g|kg|l|L|oz|lb|lbs|cups?|tbsp|tsp|x|packs?|bags?|tins?|bottles?|cans?|jars?|bunches?|heads?|loaves?|slices?|pieces?|dozen|half|litres?|liters?))\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              match.numberOfRanges == 3,
              let qr = Range(match.range(at: 1), in: trimmed),
              let nr = Range(match.range(at: 2), in: trimmed)
        else { return (name: trimmed, qty: nil) }
        let qty  = String(trimmed[qr]).trimmingCharacters(in: .whitespaces)
        let name = String(trimmed[nr]).trimmingCharacters(in: .whitespaces)
        return (name: name.prefix(1).uppercased() + name.dropFirst(), qty: qty)
    }
}

// MARK: - Item Row (kept for any future external use)

struct ItemRow: View {
    let item: ShoppingItem
    let isVisuallyComplete: Bool
    let onCircleTap: () -> Void
    let onRowTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isVisuallyComplete ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isVisuallyComplete ? .green : Color(.systemGray3))
                    .font(.body)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
                    .onTapGesture(perform: onCircleTap)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.name)
                        .foregroundStyle(isVisuallyComplete ? .secondary : .primary)
                    if let qty = item.quantity, !qty.isEmpty {
                        Text(qty)
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let notes = item.notes, !notes.isEmpty {
                HStack(spacing: 10) {
                    Color.clear.frame(width: 24)
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onRowTap)
        .padding(.vertical, 1)
    }
}
