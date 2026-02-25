import Foundation

struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let mnx: MnxContext
    let stream: Bool?
}

struct ChatMessage: Encodable {
    let role: String
    let content: String
}

struct VisionChatRequest: Encodable {
    let model: String
    let messages: [VisionChatMessage]
    let temperature: Double
    let mnx: MnxContext
    let stream: Bool?
}

struct VisionChatMessage: Encodable {
    let role: String
    let content: [VisionContentPart]
}

enum VisionContentPart: Encodable {
    case text(String)
    case imageURL(String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case .imageURL(let value):
            try container.encode("image_url", forKey: .type)
            try container.encode(VisionImageURL(url: value), forKey: .image_url)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case image_url
    }
}

struct VisionImageURL: Encodable {
    let url: String
}

struct MnxContext: Encodable {
    let subject_id: String
    let chat_id: String
    let history: Bool
    let learn: Bool
    let recall: Bool
    let summarize: String?
    let system_prompt: String?
    let records: MnxRecordsContext?
    let log: Bool

    init(
        subject_id: String,
        chat_id: String,
        history: Bool,
        learn: Bool,
        recall: Bool,
        summarize: String?,
        system_prompt: String? = nil,
        records: MnxRecordsContext? = nil
    ) {
        self.subject_id = subject_id
        self.chat_id = chat_id
        self.history = history
        self.learn = learn
        self.recall = recall
        self.summarize = summarize
        self.system_prompt = system_prompt
        self.records = records
        self.log = true
    }
}

struct MnxRecordsContext: Encodable {
    let learn: String?
    let recall: Bool?
    let tables: [String]?
    let sync: Bool?

    init(learn: String? = nil, recall: Bool? = nil, tables: [String]? = nil, sync: Bool? = nil) {
        self.learn = learn
        self.recall = recall
        self.tables = tables
        self.sync = sync
    }
}

struct RecordsSchemaSchemaRequest: Encodable {
    let type_name: String
    let schema: ReceiptSchema
    let subject_id: String
    let mnx: MnxContext
}

struct RecordsQueryRequest: Encodable {
    let `where`: [String: String]
    let order_by: String?
    let limit: Int?
    let offset: Int?
}

struct CreateReceiptRecordRequest: Encodable {
    let subject_id: String
    let data: CreateReceiptData
    let mnx: MnxContext
}

struct CreateReceiptData: Encodable {
    let store_name: String
    let total: Double
    let currency: String
    let purchased_at: String
    let raw_text: String
}

struct CreateReceiptItemRecordRequest: Encodable {
    let subject_id: String
    let data: CreateReceiptItemData
    let mnx: MnxContext
}

struct CreateReceiptItemData: Encodable {
    let receipt_id: String
    let item_name: String
    let quantity: Double?
    let unit_price: Double?
    let line_total: Double?
    let category: String?
}

struct ReceiptSchema: Encodable {
    let fields: [String: SchemaField]
}

struct SchemaField: Encodable {
    let type: String
    let required: Bool
}
