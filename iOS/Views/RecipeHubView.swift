import SwiftUI

struct RecipeHubView: View {
    let householdId: String
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var recipes: [SavedRecipe] = []
    @State private var isLoading = true
    @State private var showImport = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showImport = true
                    } label: {
                        Label("Import new recipe", systemImage: "arrow.down.circle")
                            .foregroundStyle(.tint)
                    }
                }

                if isLoading {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                } else if recipes.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No saved recipes",
                            systemImage: "fork.knife",
                            description: Text("Recipes you import will appear here.")
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section("Saved recipes") {
                        ForEach(recipes) { recipe in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(recipe.name)
                                    .font(.body)
                                if let url = recipe.sourceUrl {
                                    Text(url)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Recipes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showImport) {
                RecipeImportView(householdId: householdId)
                    .environment(services)
                    .onDisappear {
                        Task {
                            recipes = (try? await services.api.fetchSavedRecipes(householdId: householdId)) ?? []
                        }
                    }
            }
            .task {
                recipes = (try? await services.api.fetchSavedRecipes(householdId: householdId)) ?? []
                isLoading = false
            }
        }
    }
}
