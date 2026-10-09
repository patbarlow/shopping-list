import Foundation

/// The same deterministic parser is used by typed, pasted and spoken entry.
enum ShoppingInputParser {
    struct Item: Equatable, Sendable {
        var name: String
        var quantity: String?
    }

    static func split(_ raw: String) -> [String] {
        // Keep common product names intact while accepting natural list conjunctions.
        var text = raw
        let compounds = ["mac and cheese", "salt and pepper", "sweet and sour", "fruit and nut", "head and shoulders", "half and half"]
        for compound in compounds {
            text = text.replacingOccurrences(of: compound, with: compound.replacingOccurrences(of: " and ", with: " § "), options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: #"\s+(?:and|&)\s+"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        // A decimal comma between digits is part of a quantity.
        text = text.replacingOccurrences(of: #"(?<!\d),|,(?!\d)|;|\r"#, with: "\n", options: .regularExpression)
        return text.components(separatedBy: .newlines).compactMap { line in
            var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            value = value.replacingOccurrences(of: #"^(?:[•*–—◦▪▸►-]\s*|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            value = value.replacingOccurrences(of: #"^and\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            value = value.replacingOccurrences(of: " § ", with: " and ").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    static func parse(_ raw: String) -> Item {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("half and half") { return Item(name: text, quantity: nil) }
        let numbers = ["one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "half": "1/2"]
        if let first = text.split(separator: " ").first, let number = numbers[first.lowercased()] {
            text = number + text.dropFirst(first.count)
        }
        let number = #"(?:\d+\s+\d+/\d+|\d+(?:[.,/]\d+)?|[½¼¾])"#
        let unit = #"(?:kilograms?|grams?|kg|g|millilitres?|milliliters?|litres?|liters?|ml|l|ounces?|oz|pounds?|lbs?|tablespoons?|tbsp|teaspoons?|tsp|cups?|pieces?|pcs?|packs?|packets?|bunch(?:es)?|bottles?|cans?|tins?|x|×)"#
        let patterns = [
            "^(\(number)(?:\\s*\(unit))?)\\s+(?:of\\s+)?(.+)$",
            "^(.+?)\\s+(\(number)\\s*\(unit))$",
            "^(.+?)\\s+[x×]\\s*(\(number))$"
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text) else { continue }
            let name = String(text[index == 0 ? b : a])
            var quantity = String(text[index == 0 ? a : b])
            if index == 2 { quantity += "x" }
            return Item(name: name, quantity: quantity)
        }
        return Item(name: text, quantity: nil)
    }

    static func voiceContent(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"^(?:please\s+)?(?:(?:can|could|would) you\s+)?(?:add|get|buy|we need|i need|i want to buy)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"\s+(?:to (?:my|the|our) (?:shopping )?list|please)[.!?]*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// This gate also runs before the language model: mentioning food in a
    /// conversation must not be mistaken for a request to buy it.
    static func isConversationalSpeech(_ raw: String) -> Bool {
        raw.range(of: #"\b(?:don['’]?t|do not|not|no|had|ate|was|were|is|are|did|how|why|when|said|says|talk|talking|think|maybe|if|ignore|instead|actually|i|you|he|she|we|they|my|your|our|love|hate|tastes?|costs?|expensive|delicious|yesterday|tomorrow)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Auto-add requires the *whole* phrase to be a shopping request. A model
    /// can't cherry-pick “apples” from a conversation containing that word.
    static func validatedVoiceItems(_ phrases: [String], in raw: String) -> [Item] {
        let content = voiceContent(raw)
        guard !isConversationalSpeech(content), !phrases.isEmpty, phrases.count <= 40 else { return [] }
        var remainder = content
        var items: [Item] = []
        for phrase in phrases {
            let value = phrase.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !value.isEmpty, value.split(separator: " ").count <= 10,
                  !isConversationalSpeech(value),
                  value.rangeOfCharacter(from: .letters) != nil,
                  let range = remainder.range(of: value, options: .caseInsensitive) else { return [] }
            remainder.replaceSubrange(range, with: " ")
            items.append(parse(value))
        }
        remainder = remainder.replacingOccurrences(of: #"\b(?:and|please)\b"#, with: "", options: [.regularExpression, .caseInsensitive])
        guard remainder.rangeOfCharacter(from: .alphanumerics) == nil else { return [] }
        return items
    }

    /// Conservative offline fallback when Apple Intelligence isn't available.
    /// Unknown or sentence-like input stays out of automatic additions.
    static func conservativeVoiceItems(_ raw: String) -> [Item] {
        let content = voiceContent(raw)
        guard !isConversationalSpeech(content) else { return [] }
        let products = Set("apple apples banana bananas milk butter egg eggs bread flour sugar chicken beef pork fish rice pasta cheese yoghurt yogurt cream chocolate coffee tea potato potatoes onion onions tomato tomatoes carrot carrots broccoli lettuce cucumber salt pepper soap shampoo toothpaste detergent nappies tissues toilet paper juice cereal oats nuts strawberries blueberries wraps oil beans lentils lemon lemons lime limes avocado avocados mushroom mushrooms spinach garlic ginger".split(separator: " ").map(String.init))
        let phrases = split(content)
        let items: [Item] = phrases.compactMap { phrase in
            let item = parse(phrase.trimmingCharacters(in: CharacterSet(charactersIn: ".!? ")))
            let words = item.name.lowercased().split(separator: " ").map(String.init)
            let modifiers = Set(["red", "green", "fresh", "frozen", "small", "large", "unsalted", "salted", "plain", "brown", "white", "dark", "thickened", "greek", "whole", "skim", "organic", "ground", "breast", "thigh", "olive", "extra", "virgin", "rolls", "and"])
            guard !words.isEmpty, words.count <= 5, words.contains(where: products.contains), words.allSatisfy({ products.contains($0) || modifiers.contains($0) }) else { return nil }
            return item
        }
        return items.count == phrases.count ? items : []
    }
}
