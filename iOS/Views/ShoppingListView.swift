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
    let voice: VoiceEntryController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

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

    // ── Reference unit price (for the subtle "expected price" hint) ────────────
    @State private var unitPricesByName: [String: (value: Double, unit: String)] = [:]


    private var store: ShoppingListStore { services.shopping }

    private var isEditingItem: Bool { editingItemID != nil }

    // Multi-item paste preview — shown when paste produces >1 item
    private var parsedAddItems: [String] {
        guard isAdding else { return [] }
        return Self.parseMultipleItems(addText)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                mainList
                if store.items.allSatisfy(\.checked) {
                    listStatus.ignoresSafeArea(.keyboard, edges: .bottom)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { addItemAccessory }
            .background(TrolleyStyle.canvas)
            .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .sheet(isPresented: $showSettings) {
                    SettingsView(household: household).environment(services)
                }
        }
        .task {
            await store.load(householdId: household.id)
        }
        .task {
            guard let products = try? await services.api.fetchProductInsights(householdId: household.id) else { return }
            var lookup: [String: (value: Double, unit: String)] = [:]
            for product in products {
                guard let value = product.avgUnitPrice, let unit = product.avgUnitPriceUnit else { continue }
                lookup[product.name.lowercased()] = (value, unit)
            }
            unitPricesByName = lookup
        }
        .onChange(of: focusedField) { old, new in handleFocusChange(old: old, new: new) }
        .onDisappear { voice.stop(discardPending: true) }
        .onChange(of: scenePhase) { _, phase in if phase == .background { voice.stop(discardPending: true) } }
        .onReceive(NotificationCenter.default.publisher(for: .shoppingListQuickAdd)) { _ in
            startAdding()
        }
        .onOpenURL { url in
            if url.host == "quick-add" { startAdding() }
        }
        .onContinueUserActivity("com.patbarlow.shoppinglist.quickAdd") { _ in
            startAdding()
        }
    }

    // MARK: - Bottom Accessory

    private var addItemAccessory: some View {
        GlassEffectContainer(spacing: 12) {
        VStack(alignment: .trailing, spacing: 6) {
            VoiceFeedbackPill(voice: voice)
                .padding(.horizontal, 12)

            // Duplicate-item toast
            if let dupe = duplicateToastName {
                Button { duplicateToastName = nil } label: {
                    Label("\(dupe) is already on your list", hugeIcon: "exclamationmark.circle")
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
                        Label("Undo", hugeIcon: "arrow.uturn.backward")
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

            // Input bar
            VStack(alignment: .leading, spacing: 0) {
                // Name row
                HStack(spacing: 12) {
                    if isEditingItem {
                        Image(hugeIcon: "pencil")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 24, height: 24)
                    } else if isAdding {
                        Image(hugeIcon: "circle")
                            .foregroundStyle(.tertiary)
                            .font(.body)
                            .frame(width: 24, height: 24)
                    } else {
                        Image(hugeIcon: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                            .onTapGesture { startAdding() }
                    }
                    if isEditingItem {
                        TextField("Item name", text: $editName)
                            .focused($focusedField, equals: .editName)
                            .submitLabel(.done)
                            .onSubmit { commitCurrentEdit() }
                        Button {
                            cancelEditing()
                        } label: {
                            Image(hugeIcon: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    } else if voice.isActive {
                        VoiceInputLabel(voice: voice)
                            .contentShape(Rectangle())
                            .onTapGesture { startAdding() }
                    } else if isAdding {
                        TextField("Items, separated by commas", text: $addText, axis: .vertical)
                            .accessibilityIdentifier("list-add-input")
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
                            .contentShape(Rectangle())
                            .onTapGesture { voice.speech.error = nil; startAdding() }
                    }
                    if !isEditingItem {
                        VoiceInputControls(voice: voice, toggle: toggleVoice)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, (isAdding || isEditingItem) ? 10 : 16)

                // Extra fields — shown while adding or editing
                if (isAdding && !voice.isActive) || isEditingItem {
                    Divider().padding(.horizontal, 16).opacity(0.2)
                    HStack(spacing: 12) {
                        Color.clear.frame(width: 24)
                        TextField(!isEditingItem && parsedAddItems.count > 1 ? "Write quantities beside each item" : "Qty", text: isEditingItem ? $editQty : $addQty)
                            .disabled(!isEditingItem && parsedAddItems.count > 1)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .focused($focusedField, equals: isEditingItem ? .editQty : .newQty)
                            .submitLabel(.next)
                            .onSubmit { focusedField = isEditingItem ? .editNotes : .newNotes }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    Divider().padding(.horizontal, 16).opacity(0.2)
                    HStack(spacing: 12) {
                        Color.clear.frame(width: 24)
                        TextField("Note", text: isEditingItem ? $editNotes : $addNotes, axis: .vertical)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .focused($focusedField, equals: isEditingItem ? .editNotes : .newNotes)
                            .lineLimit(1...2)
                            .submitLabel(.done)
                            .onSubmit { isEditingItem ? commitCurrentEdit() : commitAdd() }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .trolleyComposer()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .padding(.top, 6)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .onEnded { value in
                        // Global coordinates stay stable while the keyboard moves
                        // the composer. Local translation could flip sign and reopen it.
                        guard value.translation.height < -20,
                              abs(value.translation.height) > abs(value.translation.width),
                              focusedField == nil else { return }
                        if isAdding { focusedField = .newName }
                        else if isEditingItem { focusedField = .editName }
                        else { startAdding() }
                    }
            )
            .background(ComposerKeyboardDismissal(enabled: focusedField != nil) {
                isCommitting = false
                focusedField = nil
            })
            // Snappier and less bouncy than before — the keyboard's own rise
            // is a plain ~250ms ease, and the old spring's overshoot tail kept
            // visibly settling after the keyboard had already finished.
            .animation(.spring(response: 0.22, dampingFraction: 0.95), value: isAdding)
            .animation(.spring(response: 0.22, dampingFraction: 0.95), value: isEditingItem)
        }
        .animation(.spring(duration: 0.35), value: store.recentlyCompleted.isEmpty)
        }
    }

    // MARK: - List

    @ViewBuilder
    // Always the ScrollView, even with zero items — the empty-state graphic is
    // a separate overlay on top. Swapping this for a bare `Color.clear` when
    // the list was empty used to tear down and remount the whole subtree
    // (including its tap-to-dismiss-keyboard gesture) the moment the first
    // item landed, which is what was yanking focus off the keyboard right
    // after adding it.
    private var mainList: some View {
        Group {
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(store.groupedItems, id: \.category) { group in
                        let catKey = group.category.rawValue
                        let isCollapsed = collapsedSections.contains(catKey)

                        VStack(spacing: 8) {
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
                                        .font(.system(.body, design: .rounded, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(hugeIcon: "chevron.down")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .rotationEffect(isCollapsed ? .degrees(-90) : .zero)
                                        .animation(.easeInOut(duration: 0.2), value: isCollapsed)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("list-section-\(catKey)")

                            // ── Items ─────────────────────────────────────────
                            if !isCollapsed {
                                ForEach(group.items) { item in
                                    VStack(spacing: 0) {
                                        let offset = swipeOffsets[item.id] ?? 0
                                        let progress = min(1.0, max(0, -offset / 100))
                                        unifiedItemRow(for: item)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 14)
                                            .background(TrolleyStyle.canvas.opacity(colorScheme == .dark ? 0.6 : 0.9))
                                            .overlay { Color.red.opacity(progress) }
                                            .overlay(alignment: .trailing) {
                                                Text("Delete")
                                                    .font(.footnote.weight(.semibold))
                                                    .foregroundStyle(.white)
                                                    .padding(.trailing, 28)
                                                    .opacity(max(0, (progress - 0.3) / 0.4))
                                            }
                                            .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                                            .offset(x: offset)
                                            .frame(maxWidth: .infinity)
                                            .gesture(swipeDeleteGesture(for: item))
                                            .contextMenu {
                                                Button(role: .destructive) {
                                                    Task { await store.deleteItem(item) }
                                                } label: {
                                                    Label("Delete", hugeIcon: "trash")
                                                }
                                            }
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .background(group.category.color.opacity(colorScheme == .dark ? 0.18 : 0.13), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    }

                    Color.clear.frame(height: 16)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            // Interactive dismiss was firing on its own the moment a new item
            // animated into the list (the content-size change from an
            // inserted row/section reads to it like a user scroll), yanking
            // the keyboard down mid-add. Only worth having while actually
            // browsing the list, not while the add bar is focused.
            .scrollDismissesKeyboard(isAdding ? .never : .interactively)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .simultaneousGesture(TapGesture().onEnded {
                guard focusedField != nil else { return }
                focusedField = nil
            })
            .refreshable { await store.fetch() }
            // Skipped entirely while adding — animating a new row into a
            // scroll view that's pinned right above a focused, safeAreaInset
            // keyboard accessory is a known trigger for the accessory's
            // layout getting briefly recomputed, which reads as the keyboard
            // blinking down and back up.
            .animation(isAdding ? nil : .default, value: store.items.map { $0.id + ($0.checked ? "1" : "0") })
        }
    }

    // MARK: - Unified item row (display + edit in one persistent view)

    private func unifiedItemRow(for item: ShoppingItem) -> some View {
        let isEditing = editingItemID == item.id
        let isComplete = item.checked
        let isVisuallyComplete = isComplete || pendingCompleteIDs.contains(item.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 10) {
                Image(hugeIcon: isVisuallyComplete ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isVisuallyComplete ? TrolleyStyle.accent : Color(.systemGray3))
                    .font(.title3)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
                    .onTapGesture { triggerComplete(item) }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isComplete ? .secondary : .primary)
                    if let qty = item.quantity, !qty.isEmpty {
                        Text(qty)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let reference = unitPricesByName[item.name.lowercased()] {
                    referencePriceText(reference)
                        .padding(.leading, 8)
                }
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
        .padding(.vertical, 1)
        .padding(.horizontal, 6)
        .background(isEditing ? TrolleyStyle.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onTapGesture { if !isEditing { beginEditing(item) } }
    }

    /// A faded in-aisle reference price — the number is what matters, so it
    /// reads a shade darker than the unit label riding along after it.
    private func referencePriceText(_ reference: (value: Double, unit: String)) -> Text {
        Text(reference.value, format: .currency(code: "AUD")).font(.caption).foregroundStyle(.tertiary)
            + Text(" / \(reference.unit)").font(.caption2).foregroundStyle(.quaternary)
    }

    // MARK: - Empty state

    @ViewBuilder private var listStatus: some View {
        if !store.hasLoaded, let error = store.error {
            VStack(spacing: 16) {
                Text("Couldn't load your list").font(.title3.bold())
                Text(error).font(.subheadline).foregroundStyle(.secondary)
                Button("Try again") { Task { await store.fetch() } }
            }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.hasLoaded {
            emptyState.accessibilityIdentifier("list-empty-state")
        } else {
            ProgressView("Loading your list…")
                .accessibilityIdentifier("list-loading")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            TrolleyMascot(size: 100)
            Text("A fresh start.")
                .font(.system(.title, design: .rounded, weight: .bold))
            Text("What are we picking up?").foregroundStyle(.secondary)
        }
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button { showSettings = true } label: {
                Image(hugeIcon: "gearshape")
                    .frame(width: 22, height: 22)
            }.accessibilityLabel("Settings")
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            ReceiptImportToolbarButton(householdId: household.id)
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

    /// Safety net for `isCommitting`: it should flip back off as soon as the
    /// Return-key resign/restore round-trip (handled synchronously in
    /// `handleFocusChange`) completes, but that round-trip only happens if
    /// UIKit actually resigns first responder. If it doesn't, this timeout
    /// still clears the flag so a later, genuine focus loss isn't mistaken
    /// for one to restore.
    private func armCommittingTimeout() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            isCommitting = false
        }
    }

    private func isAddField(_ f: FocusField?) -> Bool {
        f == .newName || f == .newQty || f == .newNotes
    }

    private func isEditField(_ f: FocusField?) -> Bool {
        f == .editName || f == .editQty || f == .editNotes
    }

    // MARK: - Actions

    private func toggleVoice() {
        if voice.isActive {
            voice.stop()
        } else {
            isAdding = false
            focusedField = nil
            voice.start(store: store, api: services.api)
        }
    }

    private func startAdding() {
        guard !voice.isActive else { return }
        voice.dismissFeedback()
        if let id = editingItemID, store.items.contains(where: { $0.id == id }) {
            commitCurrentEdit()
        }
        guard !isAdding else {
            focusedField = .newName
            return
        }
        isAdding = true
        // Focus in the same transaction as the card expanding, not after, so the
        // keyboard and the card animate up together instead of the keyboard lagging.
        focusedField = .newName
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
            armCommittingTimeout()
            return
        }

        isCommitting = true
        let qty = addQty.trimmingCharacters(in: .whitespaces)
        let note = addNotes.trimmingCharacters(in: .whitespaces)

        addText = ""; addQty = ""; addNotes = ""

        if refocus {
            // Leave focusedField untouched — it's already .newName. The Return
            // key still makes UIKit resign first responder underneath us a
            // moment later, which fires handleFocusChange; while isCommitting
            // is true that handler restores focus synchronously, in the same
            // callback, so the keyboard never actually animates down. Doing it
            // here instead, a run-loop turn later via Task, was landing after
            // that dismiss had already started — a visible close/reopen blip.
            armCommittingTimeout()
        } else {
            isAdding = false
            focusedField = nil
            isCommitting = false
        }

        Task {
            let names = ShoppingInputParser.split(trimmed)
            for name in names {
                await store.addItem(
                    name: name,
                    quantity: names.count == 1 && !qty.isEmpty ? qty : nil,
                    notes: note.isEmpty ? nil : note
                )
            }
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

    private func cancelEditing() {
        focusLossTask?.cancel()
        editingItemID = nil
        focusedField = nil
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
                // Only begin a delete swipe when the drag is clearly horizontal —
                // a diagonal scroll should never start revealing delete.
                let alreadySwiping = (swipeOffsets[item.id] ?? 0) != 0
                guard alreadySwiping || abs(translation) > abs(value.translation.height) * 1.5 else { return }
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
        ShoppingInputParser.split(text)
    }
}
