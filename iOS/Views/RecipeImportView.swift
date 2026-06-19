import SwiftUI
import PhotosUI

struct RecipeImportView: View {
    let householdId: String
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case input
        case loading(String)     // message
        case preview
        case confirming
    }

    @State private var phase: Phase = .input
    @State private var urlText = ""
    @State private var recipeName = ""
    @State private var defaultServings = 4
    @State private var currentServings = 4
    @State private var ingredients: [EditableIngredient] = []
    @State private var sourceUrl: String? = nil
    @State private var editingIngredientId: UUID? = nil
    @State private var errorMessage: String? = nil

    // Photo picker / camera
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var showCamera = false

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .input:         inputView
                case .loading(let msg): loadingView(msg)
                case .preview:       previewView
                case .confirming:    loadingView("Adding to list…")
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if case .preview = phase {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add \(ingredients.count)") { confirmImport() }
                            .bold()
                            .disabled(ingredients.isEmpty)
                    }
                }
            }
        }
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
    }

    private var navTitle: String {
        switch phase {
        case .input:              return "Import Recipe"
        case .loading:            return "Importing…"
        case .preview, .confirming: return recipeName.isEmpty ? "Recipe" : recipeName
        }
    }

    // MARK: - Input

    private var inputView: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Paste a recipe URL", text: $urlText)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
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

            Section {
                HStack(spacing: 16) {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showCamera = true
                    } label: {
                        Label("Camera", systemImage: "camera")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Or scan a recipe")
            }

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
            ProgressView()
                .scaleEffect(1.4)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Preview

    private var servingsFactor: Double {
        Double(currentServings) / Double(max(defaultServings, 1))
    }

    private var previewView: some View {
        List {
            Section {
                HStack {
                    Text("Recipe name")
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("Name", text: $recipeName)
                        .multilineTextAlignment(.trailing)
                }

                HStack {
                    Text("Servings")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Stepper("\(currentServings)", value: $currentServings, in: 1...100)
                        .fixedSize()
                        .onChange(of: currentServings) { _, _ in
                            rescaleIngredients()
                        }
                }
            }

            Section {
                ForEach($ingredients) { $ing in
                    ingredientRow(ingredient: $ing)
                }
                .onDelete { offsets in
                    ingredients.remove(atOffsets: offsets)
                }
            } header: {
                Text("\(ingredients.count) ingredient\(ingredients.count == 1 ? "" : "s")")
            }
        }
    }

    @ViewBuilder
    private func ingredientRow(ingredient: Binding<EditableIngredient>) -> some View {
        let isEditing = editingIngredientId == ingredient.id
        if isEditing {
            VStack(spacing: 0) {
                HStack {
                    TextField("Ingredient", text: ingredient.name)
                        .bold()
                    Spacer()
                    Button("Done") { editingIngredientId = nil }
                        .font(.footnote)
                        .foregroundStyle(.accent)
                }
                Divider().padding(.vertical, 6)
                HStack {
                    Text("Qty")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                    TextField("optional", text: Binding(
                        get: { ingredient.wrappedValue.currentQuantity ?? "" },
                        set: {
                            ingredient.wrappedValue.currentQuantity = $0.isEmpty ? nil : $0
                            ingredient.wrappedValue.userEditedQty = true
                        }
                    ))
                    .multilineTextAlignment(.trailing)
                    .font(.footnote)
                }
            }
            .padding(.vertical, 4)
        } else {
            Button {
                editingIngredientId = ingredient.id
            } label: {
                HStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                    Text(ingredient.wrappedValue.name)
                        .foregroundStyle(.primary)
                    Spacer()
                    if let qty = ingredient.wrappedValue.currentQuantity, !qty.isEmpty {
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

    private func handlePhotoSelection(_ item: PhotosPickerItem) async {
        phase = .loading("Reading recipe…")
        errorMessage = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let compressed = image.compressedForUpload()
            else {
                phase = .input
                errorMessage = "Couldn't load that photo."
                return
            }
            let base64 = compressed.base64EncodedString()
            let result = try await services.api.parseRecipeFromImage(householdId: householdId, imageBase64: base64)
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
            guard let compressed = image.compressedForUpload() else {
                phase = .input; errorMessage = "Image error."; return
            }
            let base64 = compressed.base64EncodedString()
            let result = try await services.api.parseRecipeFromImage(householdId: householdId, imageBase64: base64)
            applyParsedRecipe(result)
        } catch {
            phase = .input
            errorMessage = "Couldn't read the recipe from that photo."
        }
    }

    private func applyParsedRecipe(_ result: ParsedRecipeResponse) {
        recipeName      = result.recipeName
        defaultServings = result.defaultServings ?? 4
        currentServings = defaultServings
        ingredients     = result.ingredients.map { EditableIngredient(from: $0) }
        phase           = .preview
    }

    private func rescaleIngredients() {
        let factor = servingsFactor
        for i in ingredients.indices {
            ingredients[i].applyServingsScale(factor: factor)
        }
    }

    private func confirmImport() {
        guard case .preview = phase else { return }
        phase = .confirming
        Task {
            do {
                try await services.shopping.addBulkItems(ingredients)
                // Save recipe for history (fire and forget)
                Task {
                    let ingPayload: [[String: Any]] = ingredients.map {
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

// MARK: - Camera capture wrapper

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
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
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
