import SwiftUI
#if os(iOS)
import PhotosUI
#endif
private enum IngFocusField: Hashable {
    case name(UUID), qty(UUID)
}

public struct RecipeImportView: View {
    let householdId: String
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case input, loading(String), preview, confirming(String) }

    @State private var phase: Phase = .input
    @State private var urlText = ""
    @State private var recipeName = ""
    @State private var defaultServings = 4
    @State private var currentServings = 4
    @State private var ingredients: [EditableIngredient] = []
    @State private var sourceUrl: String? = nil
    @State private var errorMessage: String? = nil
    @State private var savedSnapshot: Data?
    #if os(iOS)
    @State private var mediaSource: MediaPickerSource?
    @Namespace private var mediaTransition
    #endif
    @FocusState private var focusedField: IngFocusField?

    private var store: ShoppingListStore { services.shopping }
    private var includedCount: Int { ingredients.filter(\.isIncluded).count }
    private var servingsFactor: Double { Double(currentServings) / Double(max(defaultServings, 1)) }

    public var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .input:              inputView
                case .loading(let msg):   loadingView(msg)
                case .preview:            previewView
                case .confirming(let msg): loadingView(msg)
                }
            }
            .navigationTitle(navTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarItems }
        }
        #if os(iOS)
        .sheet(item: $mediaSource) { source in
            Group {
                switch source {
                case .camera, .scan: CompactCameraPicker(scan: source == .scan) { image in Task { await handleCapturedImage(image) } }
                case .photos: CompactPhotoPicker { image in Task { await handleCapturedImage(image) } }
                }
            }
            .navigationTransition(.zoom(sourceID: source.rawValue, in: mediaTransition))
        }
        #endif
    }

    private var navTitle: String {
        switch phase {
        case .input:              return "Import Recipe"
        case .loading:            return "Importing…"
        case .preview, .confirming: return recipeName.isEmpty ? "Recipe" : recipeName
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
    }

    // MARK: - Input

    private var inputView: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 18) {
            Label("Bring a recipe to your list.", hugeIcon: "fork.knife")
                .font(.system(.title2, design: .rounded, weight: .bold))
            Text("Paste a recipe link, then review the ingredients and adjust the servings before adding them.")
                .foregroundStyle(.secondary)
            TextField("https://…", text: $urlText)
                .textFieldStyle(.roundedBorder).onSubmit { parseURL() }
            if let error = errorMessage { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Import recipe", action: parseURL).modifier(RecipePrimaryActionStyle())
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(32).frame(maxWidth: 520).frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Paste a recipe URL", text: $urlText)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { parseURL() }

                    Button(action: parseURL) {
                        Label("Import from URL", hugeIcon: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .modifier(RecipePrimaryActionStyle())
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.vertical, 4)
            }

                #if os(iOS)
                Section {
                    HStack(spacing: 16) {
                        Button { AppHaptics.tap(); mediaSource = .photos } label: {
                            Label("Photo Library", hugeIcon: "photo.on.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .matchedTransitionSource(id: "photos", in: mediaTransition)

                        Button { AppHaptics.tap(); mediaSource = .scan } label: {
                            Label("Camera", hugeIcon: "camera")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .matchedTransitionSource(id: "scan", in: mediaTransition)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Or scan a recipe")
                }
                #endif

            if let error = errorMessage {
                Section {
                    Label(error, hugeIcon: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        #endif
    }

    // MARK: - Loading

    private func loadingView(_ message: String) -> some View {
        VStack(spacing: 20) {
            ProgressView().scaleEffect(1.4)
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Preview

    private var previewView: some View {
        List {
            Section {
                LabeledContent("Recipe") {
                    TextField("Name", text: $recipeName)
                        .multilineTextAlignment(.trailing)
                }

                HStack {
                    Text("Servings")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Stepper("\(currentServings)", value: $currentServings, in: 1...100)
                        .fixedSize()
                        .onChange(of: currentServings) { _, _ in rescaleIngredients() }
                }
            }

            Section {
                ForEach($ingredients) { $ing in
                    ingredientRow(ingredient: $ing)
                        .listRowBackground(ing.isIncluded ? Color.clear : Color.secondary.opacity(0.04))
                }
                .onDelete { offsets in ingredients.remove(atOffsets: offsets) }
            } header: {
                HStack {
                    Text("\(includedCount) of \(ingredients.count) to add")
                    Spacer()
                    if ingredients.contains(where: { !$0.isIncluded }) {
                        Button("Include all") {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                for i in ingredients.indices { ingredients[i].isIncluded = true }
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            } footer: {
                Text("Water, salt and pepper are skipped by default. Include them if you're running low. The full recipe is saved for next time.")
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            confirmBar
        }
        .simultaneousGesture(
            TapGesture().onEnded { focusedField = nil }
        )
    }

    private var confirmBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button { confirmImport(addToList: true) } label: {
                Group {
                    if includedCount == 0 {
                        Text("Nothing selected")
                    } else {
                        Text("Add \(includedCount) item\(includedCount == 1 ? "" : "s") to list")
                    }
                }
                .frame(maxWidth: .infinity)
                .bold()
            }
            .modifier(RecipePrimaryActionStyle())
            .disabled(includedCount == 0)
            .padding(.horizontal)
            .padding(.top, 12)
            Button("Save recipe without adding items") { confirmImport(addToList: false) }
                .disabled(ingredients.isEmpty || recipeName.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.vertical, 12)
        }
        .background(.regularMaterial)
    }

    // MARK: - Ingredient row

    @ViewBuilder
    private func ingredientRow(ingredient: Binding<EditableIngredient>) -> some View {
        let ing = ingredient.wrappedValue
        let isEditing = focusedField == .name(ing.id) || focusedField == .qty(ing.id)

        HStack(spacing: 14) {
            // Toggle circle — same visual as shopping list checkboxes
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    ingredient.wrappedValue.isIncluded.toggle()
                }
                if !ingredient.wrappedValue.isIncluded { focusedField = nil }
            } label: {
                Image(hugeIcon: ing.isIncluded ? "circle" : "minus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(ing.isIncluded ? Color.secondary.opacity(0.4) : Color.secondary.opacity(0.35))
                    .animation(.easeInOut(duration: 0.15), value: ing.isIncluded)
            }
            .buttonStyle(.plain)

            if isEditing {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Ingredient", text: ingredient.name)
                        .focused($focusedField, equals: .name(ing.id))
                        .font(.body)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .qty(ing.id) }

                    HStack {
                        TextField("Quantity (optional)", text: Binding(
                            get: { ingredient.wrappedValue.currentQuantity ?? "" },
                            set: {
                                ingredient.wrappedValue.currentQuantity = $0.isEmpty ? nil : $0
                                ingredient.wrappedValue.userEditedQty = true
                            }
                        ))
                        .focused($focusedField, equals: .qty(ing.id))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }

                        Spacer()

                        Button("Done") { focusedField = nil }
                            .font(.footnote)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.vertical, 2)
            } else {
                Button {
                    guard ing.isIncluded else { return }
                    focusedField = .name(ing.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ing.name)
                                .foregroundStyle(ing.isIncluded ? Color.primary : Color.secondary)

                            if ing.existingItemId != nil {
                                let existingQty = ing.existingListQty ?? ""
                                HStack(spacing: 4) {
                                    Image(hugeIcon: ing.isIncluded ? "arrow.triangle.merge" : "checkmark.circle.fill")
                                    if ing.isIncluded {
                                        let merged = EditableIngredient.mergeQuantities(ing.existingListQty, ing.currentQuantity)
                                        Text(merged != nil ? "on list: \(existingQty) → \(merged!)" : "will combine with on-list qty")
                                    } else {
                                        Text(existingQty.isEmpty ? "already on your list" : "on your list: \(existingQty)")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(ing.isIncluded ? Color.orange : Color.green)
                            } else if !ing.isIncluded && RecipeStaples.contains(ing.name) {
                                Text("pantry basic — skipped")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if let qty = ing.currentQuantity, !qty.isEmpty {
                            Text(qty)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.1), in: Capsule())
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .opacity(ing.isIncluded ? 1.0 : 0.35)
        .animation(.easeInOut(duration: 0.15), value: ing.isIncluded)
        .animation(.easeInOut(duration: 0.15), value: isEditing)
    }

    // MARK: - Actions

    private func parseURL() {
        let url = urlText.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        errorMessage = nil
        phase = .loading("Fetching recipe…")
        sourceUrl = url
        Task {
            do {
                let result = try await services.api.parseRecipeFromURL(householdId: householdId, url: url)
                applyParsedRecipe(result)
            } catch {
                phase = .input
                errorMessage = "Couldn't parse that recipe. Try a different URL."
            }
        }
    }

    #if os(iOS)
    private func handleCapturedImage(_ image: UIImage) async {
        phase = .loading("Reading recipe…")
        errorMessage = nil
        do {
            guard let compressed = image.compressedForUpload()
            else { phase = .input; errorMessage = "Image error."; return }
            let result = try await services.api.parseRecipeFromImage(
                householdId: householdId, imageBase64: compressed.base64EncodedString()
            )
            applyParsedRecipe(result)
        } catch {
            phase = .input
            errorMessage = "Couldn't read the recipe from that photo."
        }
    }
    #endif

    private func applyParsedRecipe(_ result: ParsedRecipeResponse) {
        recipeName      = result.recipeName
        defaultServings = result.defaultServings ?? 4
        currentServings = defaultServings

        var merged: [EditableIngredient] = []
        var indexByKey: [String: Int] = [:]
        for ing in result.ingredients.map({ EditableIngredient(from: $0) }) {
            let key = ing.name.lowercased()
            if let idx = indexByKey[key] {
                // Same ingredient appears twice in this recipe — merge quantities
                let combined = EditableIngredient.mergeQuantities(merged[idx].currentQuantity, ing.currentQuantity)
                merged[idx].currentQuantity = combined
                merged[idx].originalQuantity = combined
            } else {
                indexByKey[key] = merged.count
                merged.append(ing)
            }
        }
        ingredients = merged
        phase = .preview
    }

    private func rescaleIngredients() {
        let factor = servingsFactor
        for i in ingredients.indices {
            ingredients[i].applyServingsScale(factor: factor)
        }
    }

    private func confirmImport(addToList: Bool) {
        guard case .preview = phase else { return }
        let toAdd = ingredients.filter(\.isIncluded)
        guard !ingredients.isEmpty, !addToList || !toAdd.isEmpty else { return }
        errorMessage = nil
        phase = .confirming("Saving recipe…")
        Task {
            do {
                // Save all ingredients, including staples and anything already
                // on the list. Quantities and serving count share the same scale.
                let ingPayload: [[String: Any]] = ingredients.map {
                    var d: [String: Any] = ["name": $0.name]
                    if let q = $0.currentQuantity { d["quantity"] = q }
                    return d
                }
                let snapshot = try JSONSerialization.data(withJSONObject: [
                    "name": recipeName, "servings": currentServings, "ingredients": ingPayload
                ], options: .sortedKeys)
                if savedSnapshot != snapshot {
                    try await services.api.saveRecipe(
                        householdId: householdId,
                        name: recipeName,
                        sourceUrl: sourceUrl,
                        defaultServings: currentServings,
                        ingredients: ingPayload
                    )
                    savedSnapshot = snapshot
                }
                if addToList {
                    phase = .confirming("Adding to list…")
                    try await store.addBulkItems(toAdd)
                }
                dismiss()
            } catch {
                phase = .preview
                errorMessage = error.localizedDescription
            }
        }
    }
}

#if os(iOS)
// MARK: - UIImage compression

extension UIImage {
    func compressedForUpload(maxDimension: CGFloat = 2048, quality: CGFloat = 0.8) -> Data? {
        let scale = min(maxDimension / max(size.width, size.height), 1.0)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in self.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: quality)
    }
}
#endif

private struct RecipePrimaryActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.buttonStyle(MacButtonStyle(.primary))
        #else
        content.buttonStyle(.borderedProminent)
        #endif
    }
}
