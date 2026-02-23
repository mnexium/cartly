import Foundation

struct MnexiumIdentity: Sendable {
    let subjectID: String
    let chatID: String
}

final class MnexiumIdentityStore {
    private enum Keys {
        static let subjectID = "cartly.subject_id"
        static let chatID = "cartly.chat_id"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func currentIdentity() -> MnexiumIdentity {
        let subjectID: String
        if let stored = defaults.string(forKey: Keys.subjectID), !stored.isEmpty {
            subjectID = stored
        } else {
            let newValue = "ios-user-\(UUID().uuidString.lowercased())"
            defaults.set(newValue, forKey: Keys.subjectID)
            subjectID = newValue
        }

        let chatID: String
        if let stored = defaults.string(forKey: Keys.chatID), !stored.isEmpty {
            chatID = stored
        } else {
            let newValue = "cartly-thread-\(UUID().uuidString.lowercased())"
            defaults.set(newValue, forKey: Keys.chatID)
            chatID = newValue
        }

        return MnexiumIdentity(subjectID: subjectID, chatID: chatID)
    }

    func setChatID(_ chatID: String) {
        let normalized = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        defaults.set(normalized, forKey: Keys.chatID)
    }

    func startNewChatID() -> String {
        let newValue = "cartly-thread-\(UUID().uuidString.lowercased())"
        defaults.set(newValue, forKey: Keys.chatID)
        return newValue
    }
}

enum ReceiptHeuristicParser {
    nonisolated static func parse(rawText: String) -> ParsedReceipt {
        let normalized = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let storeName = detectStoreName(from: normalized)
        let total = detectTotal(from: normalized)
        let currency = detectCurrency(from: normalized)
        let purchaseDate = detectDate(from: normalized)

        return ParsedReceipt(
            receiptID: "receipt-\(UUID().uuidString.lowercased())",
            storeName: storeName,
            total: total,
            currency: currency,
            purchaseDate: purchaseDate,
            items: []
        )
    }

    nonisolated private static func detectStoreName(from text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let first = lines.first else { return "Unknown Store" }

        if first.count > 2 {
            return first
        }

        return lines.dropFirst().first ?? "Unknown Store"
    }

    nonisolated private static func detectTotal(from text: String) -> Double {
        let lowercased = text.lowercased()

        let totalPatterns = [
            #"total\s*[:$]?\s*(\d+[\.,]\d{2})"#,
            #"amount\s*[:$]?\s*(\d+[\.,]\d{2})"#,
            #"balance\s*[:$]?\s*(\d+[\.,]\d{2})"#
        ]

        for pattern in totalPatterns {
            if let value = firstMatch(in: lowercased, pattern: pattern), let parsed = toDouble(value) {
                return parsed
            }
        }

        let allAmounts = allMatches(in: lowercased, pattern: #"(\d+[\.,]\d{2})"#)
            .compactMap(toDouble)
            .sorted(by: >)

        return allAmounts.first ?? 0
    }

    nonisolated private static func detectCurrency(from text: String) -> String {
        if text.contains("$") { return "USD" }
        if text.contains("€") { return "EUR" }
        if text.contains("£") { return "GBP" }
        return "USD"
    }

    nonisolated private static func detectDate(from text: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }

        let range = NSRange(location: 0, length: text.utf16.count)
        return detector.matches(in: text, options: [], range: range).first?.date
    }

    nonisolated private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let range = NSRange(location: 0, length: text.utf16.count)
        guard let result = regex.firstMatch(in: text, options: [], range: range),
              result.numberOfRanges > 1,
              let captureRange = Range(result.range(at: 1), in: text) else {
            return nil
        }

        return String(text[captureRange])
    }

    nonisolated private static func allMatches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.matches(in: text, options: [], range: range).compactMap { result in
            guard result.numberOfRanges > 1,
                  let captureRange = Range(result.range(at: 1), in: text) else {
                return nil
            }
            return String(text[captureRange])
        }
    }

    nonisolated private static func toDouble(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }
}
