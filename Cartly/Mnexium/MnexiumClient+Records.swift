import Foundation
import OSLog

extension MnexiumClient {
    func listReceiptRecords(subjectID: String, limit: Int = 100) async throws -> [MnexiumReceiptRecord] {
        let normalizedSubjectID = try nonEmpty(subjectID, field: "subject_id")
        let normalizedLimit = max(1, min(limit, 250))
        let data = try await send(
            path: "/api/v1/records/receipts",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "subject_id", value: normalizedSubjectID),
                URLQueryItem(name: "limit", value: String(normalizedLimit))
            ]
        )
        return try extractReceiptRecords(from: data)
    }

    func createReceiptRecord(
        subjectID: String,
        chatID: String,
        storeName: String,
        total: Double,
        currency: String,
        purchasedAt: Date,
        rawText: String
    ) async throws {
        let normalizedSubjectID = try nonEmpty(subjectID, field: "subject_id")
        let normalizedChatID = try nonEmpty(chatID, field: "chat_id")
        let normalizedStoreName = try nonEmpty(storeName, field: "store_name")
        let normalizedCurrency = try nonEmpty(currency, field: "currency")

        let payload = CreateReceiptRecordRequest(
            subject_id: normalizedSubjectID,
            data: CreateReceiptData(
                store_name: normalizedStoreName,
                total: total,
                currency: normalizedCurrency,
                purchased_at: iso8601Formatter.string(from: purchasedAt),
                raw_text: rawText
            ),
            mnx: MnxContext(
                subject_id: normalizedSubjectID,
                chat_id: normalizedChatID,
                history: false,
                learn: false,
                recall: false,
                summarize: nil
            )
        )

        _ = try await send(path: "/api/v1/records/receipts", method: "POST", payload: payload)
    }

    func createReceiptItemRecord(
        subjectID: String,
        chatID: String,
        receiptID: String,
        itemName: String,
        quantity: Double?,
        unitPrice: Double?,
        lineTotal: Double?,
        category: String?
    ) async throws {
        let normalizedSubjectID = try nonEmpty(subjectID, field: "subject_id")
        let normalizedChatID = try nonEmpty(chatID, field: "chat_id")
        let normalizedReceiptID = try nonEmpty(receiptID, field: "receipt_id")
        let normalizedItemName = try nonEmpty(itemName, field: "item_name")
        let normalizedCategory = normalizedOptionalString(category)

        let payload = CreateReceiptItemRecordRequest(
            subject_id: normalizedSubjectID,
            data: CreateReceiptItemData(
                receipt_id: normalizedReceiptID,
                item_name: normalizedItemName,
                quantity: quantity,
                unit_price: unitPrice,
                line_total: lineTotal,
                category: normalizedCategory
            ),
            mnx: MnxContext(
                subject_id: normalizedSubjectID,
                chat_id: normalizedChatID,
                history: false,
                learn: false,
                recall: false,
                summarize: nil
            )
        )

        _ = try await send(path: "/api/v1/records/receipt_items", method: "POST", payload: payload)
    }

    func deleteReceiptRecord(subjectID: String, recordID: String) async throws {
        let normalizedSubjectID = try nonEmpty(subjectID, field: "subject_id")
        let normalizedRecordID = try nonEmpty(recordID, field: "record_id")
        let encodedRecordID = try encodedPathComponent(normalizedRecordID, field: "record_id")

        _ = try await send(
            path: "/api/v1/records/receipts/\(encodedRecordID)",
            method: "DELETE",
            queryItems: [URLQueryItem(name: "subject_id", value: normalizedSubjectID)]
        )
    }

    func deleteReceiptItemRecord(subjectID: String, recordID: String) async throws {
        let normalizedSubjectID = try nonEmpty(subjectID, field: "subject_id")
        let normalizedRecordID = try nonEmpty(recordID, field: "record_id")
        let encodedRecordID = try encodedPathComponent(normalizedRecordID, field: "record_id")

        _ = try await send(
            path: "/api/v1/records/receipt_items/\(encodedRecordID)",
            method: "DELETE",
            queryItems: [URLQueryItem(name: "subject_id", value: normalizedSubjectID)]
        )
    }

    func queryReceiptItems(subjectID: String, receiptID: String, limit: Int = 200) async throws -> [MnexiumReceiptItemRecord] {
        _ = try nonEmpty(subjectID, field: "subject_id")
        let normalizedReceiptID = try nonEmpty(receiptID, field: "receipt_id")
        let normalizedLimit = max(1, min(limit, 500))

        let request = RecordsQueryRequest(
            where: ["receipt_id": normalizedReceiptID],
            order_by: "item_name",
            limit: normalizedLimit,
            offset: nil
        )
        let data = try await send(path: "/api/v1/records/receipt_items/query", method: "POST", payload: request)
        return try extractReceiptItemRecords(from: data)
    }

    func captureReceiptToRecords(imageJPEGData: Data, subjectID: String, chatID: String) async throws -> MnexiumRecordsSyncResult {
        let normalizedSubjectID = try nonEmpty(subjectID, field: "subject_id")
        let normalizedChatID = try nonEmpty(chatID, field: "chat_id")
        let persistenceChatID = try resolvedUUIDChatID(from: normalizedChatID)

        try await ensureRecordSchemas(subjectID: normalizedSubjectID, chatID: normalizedChatID)

        let ocrChatID = "OCR-\(UUID().uuidString)"
        let imageDataURL = "data:image/jpeg;base64,\(imageJPEGData.base64EncodedString())"

        let ocrRequest = VisionChatRequest(
            model: configuration.model,
            messages: [
                VisionChatMessage(
                    role: "user",
                    content: [
                        .imageURL(imageDataURL)
                    ]
                )
            ],
            temperature: 0,
            mnx: MnxContext(
                subject_id: normalizedSubjectID,
                chat_id: ocrChatID,
                history: false,
                learn: false,
                recall: false,
                summarize: nil,
                system_prompt: receiptOCRSystemPromptID
            ),
            stream: nil
        )

        logger.info("context=receipt_ocr_request chat_id=\(ocrChatID, privacy: .public) history=false")
        let ocrData = try await send(path: "/api/v1/chat/completions", method: "POST", payload: ocrRequest)
        let ocrContent = try extractAssistantContent(from: ocrData)
        logger.info("context=receipt_ocr_ai_message message=\(ocrContent, privacy: .public)")

        let parsedReceiptJSON = try normalizedJSONObjectString(from: ocrContent)
        let persistenceMessage = """
        Persist this parsed receipt into Mnexium Records. Only create or update rows in tables receipts and receipt_items.
        Receipts schema fields are: total, currency, raw_text, store_name, purchased_at (do not include receipt_id on receipts).
        Receipt_items schema fields are: category, quantity, item_name, line_total, receipt_id, unit_price.
        Link each receipt_items.receipt_id to the parent receipts record_id.

        \(parsedReceiptJSON)
        """

        let persistenceRequest = ChatRequest(
            model: receiptPersistenceModel,
            messages: [ChatMessage(role: "user", content: persistenceMessage)],
            temperature: 0,
            mnx: MnxContext(
                subject_id: normalizedSubjectID,
                chat_id: persistenceChatID,
                history: false,
                learn: false,
                recall: false,
                summarize: nil,
                records: MnxRecordsContext(
                    learn: "force",
                    recall: false,
                    tables: ["receipts", "receipt_items"],
                    sync: true
                )
            ),
            stream: false
        )
        try validateReceiptPersistenceRequestShape(persistenceRequest)

        let persistenceData: Data
        do {
            persistenceData = try await send(path: "/api/v1/chat/completions", method: "POST", payload: persistenceRequest)
        } catch let error as MnexiumClientError {
            if case .httpStatus(let status, let body) = error,
               status == 422 {
                let normalizedBody = body.lowercased()
                if normalizedBody.contains("records_sync_write_failed") {
                    throw MnexiumClientError.parse("Mnexium records sync failed (records_sync_write_failed). Check receipts and receipt_items schema requirements.")
                }
            }
            throw error
        }

        let result = try extractRecordsSyncResult(from: persistenceData)
        logger.info("context=receipt_records_synced_via_chat created=\(result.created.count) updated=\(result.updated.count) actions=\(result.actions.joined(separator: ","), privacy: .public)")
        return result
    }

    func ensureRecordSchemas(subjectID: String, chatID: String) async throws {
        guard !didEnsureRecordSchemas else { return }

        let receiptsSchema = ReceiptSchema(
            fields: [
                "store_name": SchemaField(type: "string", required: true),
                "total": SchemaField(type: "number", required: true),
                "currency": SchemaField(type: "string", required: true),
                "purchased_at": SchemaField(type: "datetime", required: false),
                "raw_text": SchemaField(type: "string", required: false)
            ]
        )

        let receiptItemsSchema = ReceiptSchema(
            fields: [
                "receipt_id": SchemaField(type: "ref:receipts", required: true),
                "item_name": SchemaField(type: "string", required: true),
                "quantity": SchemaField(type: "number", required: false),
                "unit_price": SchemaField(type: "number", required: false),
                "line_total": SchemaField(type: "number", required: false),
                "category": SchemaField(type: "string", required: false)
            ]
        )

        try await ensureRecordSchema(type: "receipts", schema: receiptsSchema, subjectID: subjectID, chatID: chatID)
        try await ensureRecordSchema(type: "receipt_items", schema: receiptItemsSchema, subjectID: subjectID, chatID: chatID)
        didEnsureRecordSchemas = true
    }

    func ensureRecordSchema(type: String, schema: ReceiptSchema, subjectID: String, chatID: String) async throws {
        let normalizedType = try nonEmpty(type, field: "type_name")
        let normalizedSubjectID = try nonEmpty(subjectID, field: "subject_id")
        let normalizedChatID = try nonEmpty(chatID, field: "chat_id")

        let preferredRequest = RecordsSchemaSchemaRequest(
            type_name: normalizedType,
            schema: schema,
            subject_id: normalizedSubjectID,
            mnx: MnxContext(subject_id: normalizedSubjectID, chat_id: normalizedChatID, history: false, learn: false, recall: false, summarize: nil)
        )

        do {
            _ = try await send(path: "/api/v1/records/schemas", method: "POST", payload: preferredRequest)
        } catch let error as MnexiumClientError {
            if case .httpStatus(let status, _) = error, status == 409 {
                return
            }
            throw error
        }
    }
}
