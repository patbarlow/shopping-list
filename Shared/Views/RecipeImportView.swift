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

    private enum Phase { case input, loading(String), preview, confirming }

    @State private var phase: Phase = .input
    @State private var urlText = ""
    @State private var recipeName = ""
    @State private var defaultServings = 4
    @State private var currentServings = 4
    @State private var ingredients: [EditableIngredient] = []
    @State private var sourceUrl: String? = nil
    @State private var errorMessage: String? = nil
    @State private var selectedPhoto: PhotosPickerItem? = nil
    #if os(iOS)
    @State private var showCamera = false
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
                case .confirming:         loadingView("Adding to list…")
                }
            }
            .navigationTitle(navTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarItems }
        }
        #if os(iOS)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await handlePhotoSelection(item) }
        }
        .sheet(isPresented: $showCamera) {
            CameraCapture { image in
                showCamera = false
                Task { await handleCapturedImage(image) }
            }
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
                        Label("Import from URL", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.vertical, 4)
            }

                #if os(iOS)
                Section {
                    HStack(spacing: 16) {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("Photo Library", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button { showCamera = true } label: {
                            Label("Camera", systemImage: "camera")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Or scan a recipe")
                }
                #endif

            if let error = errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
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
            Button(action: confirmImport) {
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
            .buttonStyle(.borderedProminent)
            .disabled(includedCount == 0)
            .padding(.horizontal)
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
                Image(systemName: ing.isIncluded ? "circle" : "minus.circle.fill")
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
                                    Image(systemName: ing.isIncluded ? "arrow.triangle.merge" : "checkmark.circle.fill")
                                    if ing.isIncluded {
                                        let merged = EditableIngredient.mergeQuantities(ing.existingListQty, ing.currentQuantity)
                                        Text(merged != nil ? "on list: \(existingQty) → \(merged!)" : "will combine with on-list qty")
                                    } else {
                                        Text(existingQty.isEmpty ? "already on your list" : "on your list: \(existingQty)")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(ing.isIncluded ? Color.orange : Color.green)
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
    private func handlePhotoSelection(_ item: PhotosPickerItem) async {
        phase = .loading("Reading recipe…")
        errorMessage = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let compressed = image.compressedForUpload()
            else { phase = .input; errorMessage = "Couldn't load that photo."; return }
            let result = try await services.api.parseRecipeFromImage(
                householdId: householdId, imageBase64: compressed.base64EncodedString()
            )
            applyParsedRecipe(result)
        } catch {
            phase = .input
            errorMessage = "Couldn't read the recipe from that photo."
        }
    }

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

    private func confirmImport() {
        guard case .preview = phase else { return }
        let toAdd = ingredients.filter(\.isIncluded)
        guard !toAdd.isEmpty else { return }
        phase = .confirming
        Task {
            do {
                try await store.addBulkItems(toAdd)
                Task {
                    let ingPayload: [[String: Any]] = toAdd.map {
                        var d: [String: Any] = ["name": $0.name]
                        if let q = $0.currentQuantity { d["quantity"] = q }
                        return d
                    }
                    try? await services.api.saveRecipe(
                        householdId: householdId,
                        name: recipeName,
                        sourceUrl: sourceUrl,
                        defaultServings: defaultServings,
                        ingredients: ingPayload
                    )
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
struct CameraCapture: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate   = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        init(onCapture: @escaping (UIImage) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            if let image = info[.originalImage] as? UIImage { onCapture(image) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

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
