import SwiftUI

/// Lightweight sheet used only for Siri / quick-add entry points.
/// The main list uses inline add instead (see ShoppingListView).
struct AddItemView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var store: ShoppingListStore { services.shopping }

    private var parsedItems: [String] {
        let all = Self.parseItems(text)
        return all.count > 1 ? all : []
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("e.g. Milk, Bananas, Pasta…", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit(addItems)
                    .padding(.horizontal)
                    .onChange(of: text) { old, new in
                        guard new.count - old.count > 2,
                              let clip = UIPasteboard.general.string,
                              clip.contains("\n") else { return }
                        let items = Self.parseItems(clip)
                        guard items.count > 1 else { return }
                        text = ""
                        for name in items { Task { await store.addItem(name: name) } }
                        dismiss()
                    }

                if !parsedItems.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Adding \(parsedItems.count) items:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(parsedItems, id: \.self) { item in
                                    Text(item)
                                        .font(.subheadline)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(.green.opacity(0.12), in: Capsule())
                                        .overlay(Capsule().stroke(.green.opacity(0.3), lineWidth: 1))
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: addItems) {
                    Text(parsedItems.isEmpty ? "Add to List" : "Add \(parsedItems.count) Items")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Add Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { focused = true }
        }
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
    }

    private func addItems() {
        let items = Self.parseItems(text)
        guard !items.isEmpty else { return }
        text = ""
        for item in items {
            Task { await store.addItem(name: item) }
        }
        dismiss()
    }

    static func parseItems(_ raw: String) -> [String] {
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
        if let range = t.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            return String(t[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return t
    }
}
