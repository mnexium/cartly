import Foundation

struct MnexiumChatSummary: Identifiable, Sendable {
    let chatID: String
    let title: String
    let updatedAt: Date?
    let createdAt: Date?
    let messageCount: Int?

    var id: String { chatID }
}

struct MnexiumHistoryMessage: Sendable {
    let role: String
    let content: String
    let createdAt: Date?
}

struct MnexiumReceiptRecord: Sendable, Identifiable {
    let id: String
    let storeName: String
    let total: Double
    let currency: String
    let purchasedAt: Date
    let capturedAt: Date
    let rawText: String
}

struct MnexiumReceiptItemRecord: Sendable, Identifiable {
    let id: String
    let receiptID: String
    let itemName: String
    let quantity: Double?
    let unitPrice: Double?
    let lineTotal: Double?
    let category: String?
}

struct MnexiumRecordMutation: Sendable {
    let id: String?
    let table: String?
    let action: String?
}

struct MnexiumRecordsSyncResult: Sendable {
    let created: [MnexiumRecordMutation]
    let updated: [MnexiumRecordMutation]
    let actions: [String]

    var allRecordIDs: [String] {
        (created + updated).compactMap { $0.id }
    }

    var primaryRecordID: String? {
        if let receiptsID = (created + updated).first(where: {
            ($0.table ?? "").lowercased() == "receipts" && $0.id != nil
        })?.id {
            return receiptsID
        }
        return allRecordIDs.first
    }
}

enum MnexiumClientError: LocalizedError {
    case invalidResponse
    case invalidInput(String)
    case httpStatus(Int, String)
    case transport(String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Mnexium returned an invalid response."
        case .invalidInput(let message):
            return "Invalid request input: \(message)"
        case .httpStatus(let status, let body):
            return "Mnexium request failed with status \(status): \(body)"
        case .transport(let message):
            return "Network error while contacting Mnexium: \(message)"
        case .parse(let message):
            return "Could not parse Mnexium response: \(message)"
        }
    }
}
