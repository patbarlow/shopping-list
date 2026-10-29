import SwiftUI
import Charts

struct MacInsightsView: View {
    let householdId: String
    @Environment(AppServices.self) private var services
    @State private var products: [ProductInsight] = []
    @State private var trips: [ShoppingTrip] = []
    @State private var loading = true
    @State private var error: String?
    @State private var query = ""
    @State private var sortOrder = [KeyPathComparator(\ProductInsight.timesPurchased, order: .reverse)]
    @State private var selected: String?
    @State private var detail: ProductInsightDetail?
    @State private var detailLoading = false
    @State private var detailError: String?
    private var filtered: [ProductInsight] {
        products.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.sorted(using: sortOrder)
    }
    var body: some View {
        VStack(spacing: 0) {
            if let error { MacErrorBanner(message: error, retry: { Task { await load() } }) }
            if loading {
                ProgressView("Loading insights…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if products.isEmpty && error == nil {
                MacEmptyState(title: "A little more insight.", message: "Import your receipts to see spending, product prices and patterns over time.")
            } else {
                if !trips.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Recent shopping trips").font(.system(.headline, design: .rounded))
                            Spacer()
                            Text("\(trips.count) receipts").foregroundStyle(.secondary)
                        }
                        Chart(Array(trips.sorted { $0.date < $1.date }.suffix(12))) { trip in
                            BarMark(x: .value("Trip", trip.date), y: .value("Spend", trip.totalAmount ?? 0))
                                .foregroundStyle(Color.accentColor.gradient).cornerRadius(5)
                        }.chartXAxis {
                            AxisMarks { value in
                                AxisValueLabel { if let date = value.as(String.self) { Text(MacStyle.date(date)) } }
                            }
                        }.frame(height: 120)
                    }.macCard().padding(20)
                }
                Table(filtered, selection: $selected, sortOrder: $sortOrder) {
                    TableColumn("Product", value: \.name) { product in
                        HStack {
                            Text((ItemCategory(rawValue: product.category) ?? .other).emoji)
                            Text(product.name)
                        }
                    }.width(min: 180, ideal: 260)
                    TableColumn("Bought", value: \.timesPurchased) { Text("\($0.timesPurchased)") }.width(55)
                    TableColumn("Last price") { Text(MacStyle.money($0.lastPrice)) }.width(85)
                    TableColumn("Average") { Text(MacStyle.money($0.avgPrice)) }.width(85)
                }
                if selected != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        if detailLoading { ProgressView("Loading purchases…") }
                        else if let detailError { Text(detailError).foregroundStyle(.red) }
                        else if let detail {
                            HStack {
                                Text(detail.product.name).font(.system(.headline, design: .rounded))
                                Spacer()
                                Text("Total spent \(MacStyle.money(detail.stats.totalSpend))").foregroundStyle(.secondary)
                            }
                            ScrollView(.horizontal) {
                                HStack(spacing: 16) {
                                    ForEach(detail.purchases) { purchase in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(MacStyle.money(purchase.pricePaid)).font(.headline)
                                            Text(purchase.storeName ?? "Purchase").lineLimit(1)
                                            Text(MacStyle.date(purchase.purchasedAt)).foregroundStyle(.secondary)
                                        }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                                    }
                                }
                            }
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle("Insights")
        .searchable(text: $query, prompt: "Find a product")
        .toolbar { Button("Refresh") { Task { await load() } } }
        .task { await load() }
        .task(id: selected) {
            guard let selected else { detail = nil; return }
            detail = nil; detailError = nil; detailLoading = true
            do {
                let result = try await services.api.fetchProductInsight(householdId: householdId, productId: selected)
                guard !Task.isCancelled else { return }
                detail = result
            } catch { if !Task.isCancelled { detailError = error.localizedDescription } }
            if !Task.isCancelled { detailLoading = false }
        }
    }
    private func load() async {
        loading = true; error = nil
        do {
            products = try await services.api.fetchProductInsights(householdId: householdId)
            trips = try await services.api.fetchTrips(householdId: householdId).trips
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct MacForecastView: View {
    let householdId: String
    @Environment(AppServices.self) private var services
    @State private var forecast: PredictedListResponse?
    @State private var loading = true
    @State private var error: String?
    @State private var adding: Set<String> = []
    var body: some View {
        VStack(spacing: 0) {
            if let error { MacErrorBanner(message: error, retry: { Task { await load() } }) }
            if loading { ProgressView("Looking ahead…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let forecast, !forecast.items.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your next shop, a little easier.").font(.system(size: 28, weight: .bold, design: .rounded))
                            Text("Based on your household’s past purchases. Estimated total: \(MacStyle.money(forecast.predictedTotal)).")
                                .foregroundStyle(.secondary)
                            Text("\(MacStyle.date(forecast.range.start)) – \(MacStyle.date(forecast.range.end))").font(.caption).foregroundStyle(.secondary)
                        }.padding(.bottom, 8)
                        ForEach(forecast.items) { item in
                            let onList = services.shopping.items.contains { !$0.checked && $0.name.caseInsensitiveCompare(item.name) == .orderedSame }
                            HStack(spacing: 14) {
                                Text((ItemCategory(rawValue: item.category) ?? .other).emoji).font(.title2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name).font(.headline)
                                    Text("Usually every \(item.avgIntervalDays) days · \(item.predictedDate < forecast.range.start ? "May be due" : "Due " + MacStyle.date(item.predictedDate))").font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(MacStyle.money(item.predictedPrice)).monospacedDigit()
                                Button {
                                    adding.insert(item.id)
                                    Task {
                                        if await services.shopping.addItem(name: item.name) == nil { error = services.shopping.error }
                                        adding.remove(item.id)
                                    }
                                } label: { Label(onList ? "On list" : "Add", hugeIcon: onList ? "checkmark" : "plus") }
                                    .disabled(onList || adding.contains(item.id))
                            }.macCard(inset: 14)
                        }
                    }.padding(24).frame(maxWidth: 840).frame(maxWidth: .infinity)
                }
            } else if error == nil {
                MacEmptyState(title: "Getting to know your shop.", message: "As you shop, Trolley learns what you buy regularly and suggests what you might need next.")
            }
        }.navigationTitle("Forecast")
            .toolbar { Button("Refresh") { Task { await load() } } }
            .task { await load() }
    }
    private func load() async {
        loading = true; error = nil
        do { forecast = try await services.api.fetchPredictedList(householdId: householdId) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct MacRecipesView: View {
    let householdId: String
    @Environment(AppServices.self) private var services
    @State private var recipes: [SavedRecipe] = []
    @State private var loading = true
    @State private var importing = false
    @State private var selected: SavedRecipe?
    @State private var error: String?
    var body: some View {
        VStack {
            if let error { MacErrorBanner(message: error, retry: { Task { await load() } }) }
            if loading { ProgressView("Loading recipes…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if recipes.isEmpty && error == nil {
                VStack(spacing: 0) {
                    MacEmptyState(title: "Something good for dinner.", message: "Import a recipe from a link, review the ingredients and add just what you need to your list.").frame(maxHeight: 330)
                    Button("Import recipe…") { importing = true }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(recipes) { recipe in
                    Button { selected = recipe } label: {
                        HStack(spacing: 14) {
                            Image(hugeIcon: "fork.knife").foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recipe.name).font(.system(.headline, design: .rounded))
                                Text("\(recipe.defaultServings ?? 4) servings").font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Review ingredients").foregroundStyle(.secondary)
                        }.padding(.vertical, 10).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }.navigationTitle("Recipes")
            .toolbar { Button("Import recipe…") { importing = true } }
            .sheet(isPresented: $importing, onDismiss: { Task { await load() } }) {
                RecipeImportView(householdId: householdId).frame(width: 600, height: 620)
            }
            .sheet(item: $selected) { recipe in MacSavedRecipeView(recipe: recipe, householdId: householdId) }
            .task { await load() }
    }
    private func load() async {
        loading = true; error = nil
        do { recipes = try await services.api.fetchSavedRecipes(householdId: householdId) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

private struct MacSavedRecipeView: View {
    let recipe: SavedRecipe
    let householdId: String
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var ingredients: [EditableIngredient] = []
    @State private var loading = true
    @State private var error: String?
    @State private var servings = 4
    @State private var originalServings = 4
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(recipe.name).font(.system(.title, design: .rounded, weight: .bold))
            if let error { Text(error).foregroundStyle(.red) }
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                Stepper("Servings: \(servings)", value: $servings, in: 1...24)
                    .onChange(of: servings) { _, value in
                        for index in ingredients.indices { ingredients[index].applyServingsScale(factor: Double(value) / Double(originalServings)) }
                    }
                List($ingredients) { $item in
                    HStack {
                        Toggle(item.name, isOn: $item.isIncluded)
                        Spacer()
                        Text(item.currentQuantity ?? "").foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add \(ingredients.filter(\.isIncluded).count) ingredients") {
                    loading = true
                    Task {
                        do { try await services.shopping.addBulkItems(ingredients.filter(\.isIncluded)); dismiss() }
                        catch { self.error = error.localizedDescription; loading = false }
                    }
                }.buttonStyle(.borderedProminent).disabled(loading || !ingredients.contains(where: \.isIncluded))
            }
        }.padding(24).frame(width: 560, height: 560)
            .task {
                do {
                    let parsed = try await services.api.fetchRecipe(id: recipe.id, householdId: householdId)
                    ingredients = parsed.ingredients.map(EditableIngredient.init)
                    originalServings = max(parsed.defaultServings ?? 4, 1); servings = originalServings
                } catch { self.error = error.localizedDescription }
                loading = false
            }
    }
}
