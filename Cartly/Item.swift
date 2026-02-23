import Foundation

struct ReceiptEntry: Identifiable, Codable, Sendable {
    let id: String
    let storeName: String
    let total: Double
    let currency: String
    let purchasedAt: Date
    let capturedAt: Date
    let rawText: String
    let mnexiumRecordID: String?
    let imageData: Data?

    init(
        id: String = UUID().uuidString,
        storeName: String,
        total: Double,
        currency: String,
        purchasedAt: Date,
        capturedAt: Date = Date(),
        rawText: String,
        mnexiumRecordID: String? = nil,
        imageData: Data? = nil
    ) {
        self.id = id
        self.storeName = storeName
        self.total = total
        self.currency = currency
        self.purchasedAt = purchasedAt
        self.capturedAt = capturedAt
        self.rawText = rawText
        self.mnexiumRecordID = mnexiumRecordID
        self.imageData = imageData
    }
}

struct ParsedReceipt: Sendable {
    let receiptID: String
    let storeName: String
    let total: Double
    let currency: String
    let purchaseDate: Date?
    let items: [ParsedReceiptItem]
}

struct ParsedReceiptItem: Sendable {
    let itemName: String
    let quantity: Double?
    let unitPrice: Double?
    let lineTotal: Double?
    let category: String?
}

struct StoreSpendSummary: Identifiable {
    let storeName: String
    let total: Double

    var id: String { storeName }
}
