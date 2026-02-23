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

    init(
        id: String = UUID().uuidString,
        storeName: String,
        total: Double,
        currency: String,
        purchasedAt: Date,
        capturedAt: Date = Date(),
        rawText: String,
        mnexiumRecordID: String? = nil
    ) {
        self.id = id
        self.storeName = storeName
        self.total = total
        self.currency = currency
        self.purchasedAt = purchasedAt
        self.capturedAt = capturedAt
        self.rawText = rawText
        self.mnexiumRecordID = mnexiumRecordID
    }
}

struct ReceiptItemEntry: Identifiable, Codable, Sendable {
    let id: String
    let receiptID: String
    let itemName: String
    let quantity: Double?
    let unitPrice: Double?
    let lineTotal: Double?
    let category: String?
}
