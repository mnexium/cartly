import Foundation
import OSLog

struct MnexiumConfiguration: Sendable {
    let baseURL: URL
    let apiKey: String
    let openAIKey: String?
    let model: String

    static func fromEnvironment() -> MnexiumConfiguration? {
        let env = ProcessInfo.processInfo.environment
        let rawKey = env["MNEXIUM_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawKey.isEmpty else { return nil }
        let rawOpenAIKey = env["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        return MnexiumConfiguration(
            baseURL: resolvedBaseURL(from: env),
            apiKey: rawKey,
            openAIKey: normalizedOptional(rawOpenAIKey),
            model: resolvedModel(from: env)
        )
    }

    static func fromRemoteKey(_ apiKey: String) -> MnexiumConfiguration? {
        fromRemoteKeys(mnexiumApiKey: apiKey, openAIKey: nil)
    }

    static func fromRemoteKeys(mnexiumApiKey: String, openAIKey: String?) -> MnexiumConfiguration? {
        let normalized = mnexiumApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let env = ProcessInfo.processInfo.environment
        return MnexiumConfiguration(
            baseURL: resolvedBaseURL(from: env),
            apiKey: normalized,
            openAIKey: normalizedOptional(openAIKey) ?? normalizedOptional(env["OPENAI_API_KEY"]),
            model: resolvedModel(from: env)
        )
    }

    private static func resolvedBaseURL(from env: [String: String]) -> URL {
        let baseURLString = env["MNEXIUM_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: baseURLString ?? "https://www.mnexium.com") ?? URL(string: "https://www.mnexium.com")!
    }

    private static func resolvedModel(from env: [String: String]) -> String {
        let modelCandidate = env["MNEXIUM_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let modelCandidate, !modelCandidate.isEmpty {
            return modelCandidate
        }
        return "gpt-4.1-mini"
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }
}

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
    let receiptID: String
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

@MainActor
final class MnexiumClient {
    private let configuration: MnexiumConfiguration
    private let urlSession: URLSession
    private let logger = Logger(subsystem: "com.marius.Cartly", category: "Mnexium")
    private var didEnsureRecordSchemas = false
    private let receiptOCRSystemPromptID = "sp_4a80827f-04b1-433f-9aaa-b8d88cdf2636"
    private let receiptPersistenceModel = "gpt-4.1-mini"

    init(configuration: MnexiumConfiguration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    func sendChatMessage(_ message: String, subjectID: String, chatID: String) async throws -> String {
        let normalizedMessage = try nonEmpty(message, field: "message")
        let normalizedSubjectID = try nonEmpty(subjectID, field: "subject_id")
        let normalizedChatID = try nonEmpty(chatID, field: "chat_id")

        let request = ChatRequest(
            model: configuration.model,
            messages: [
                ChatMessage(role: "user", content: normalizedMessage)
            ],
            temperature: 0.2,
            mnx: MnxContext(
                subject_id: normalizedSubjectID,
                chat_id: normalizedChatID,
                history: true,
                learn: true,
                recall: true,
                summarize: "balanced",
                records: MnxRecordsContext(
                    recall: true,
                    tables: ["receipts", "receipt_items"]
                )
            ),
            stream: nil
        )

        let data = try await send(path: "/api/v1/chat/completions", method: "POST", payload: request)
        return try extractAssistantContent(from: data).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func streamChatMessage(_ message: String, subjectID: String, chatID: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let normalizedMessage: String
            let normalizedSubjectID: String
            let normalizedChatID: String

            do {
                normalizedMessage = try nonEmpty(message, field: "message")
                normalizedSubjectID = try nonEmpty(subjectID, field: "subject_id")
                normalizedChatID = try nonEmpty(chatID, field: "chat_id")
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let requestPayload = ChatRequest(
                model: configuration.model,
                messages: [
                    ChatMessage(role: "user", content: normalizedMessage)
                ],
                temperature: 0.2,
                mnx: MnxContext(
                    subject_id: normalizedSubjectID,
                    chat_id: normalizedChatID,
                    history: true,
                    learn: true,
                    recall: true,
                    summarize: "balanced",
                    records: MnxRecordsContext(
                        recall: true,
                        tables: ["receipts", "receipt_items"]
                    )
                ),
                stream: true
            )

            Task {
                do {
                    try await streamChat(requestPayload, continuation: continuation)
                } catch let error as MnexiumClientError {
                    if shouldFallbackFromStreaming(error) {
                        do {
                            let response = try await sendChatMessage(
                                normalizedMessage,
                                subjectID: normalizedSubjectID,
                                chatID: normalizedChatID
                            )
                            if !response.isEmpty {
                                continuation.yield(response)
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                        return
                    }
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func listChats(subjectID: String) async throws -> [MnexiumChatSummary] {
        let normalizedSubjectID = try nonEmpty(subjectID, field: "subject_id")
        let data = try await send(
            path: "/api/v1/chat/history/list",
            method: "GET",
            queryItems: [URLQueryItem(name: "subject_id", value: normalizedSubjectID)]
        )
        return try extractChatSummaries(from: data)
    }

    func readChatHistory(subjectID: String, chatID: String) async throws -> [MnexiumHistoryMessage] {
        let normalizedSubjectID = try nonEmpty(subjectID, field: "subject_id")
        let normalizedChatID = try nonEmpty(chatID, field: "chat_id")
        let data = try await send(
            path: "/api/v1/chat/history/read",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "subject_id", value: normalizedSubjectID),
                URLQueryItem(name: "chat_id", value: normalizedChatID)
            ]
        )
        return try extractHistoryMessages(from: data)
    }

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
        let persistenceChatID = resolvedUUIDChatID(from: normalizedChatID)

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
        Persist this parsed receipt into Mnexium Records. Only create or update rows in tables receipts and receipt_items. Use receipt.receipt_id to link items.

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

    private func ensureRecordSchemas(subjectID: String, chatID: String) async throws {
        guard !didEnsureRecordSchemas else { return }

        let receiptsSchema = ReceiptSchema(
            fields: [
                "receipt_id": SchemaField(type: "string", required: true),
                "store_name": SchemaField(type: "string", required: true),
                "total": SchemaField(type: "number", required: true),
                "currency": SchemaField(type: "string", required: true),
                "purchased_at": SchemaField(type: "string", required: false),
                "raw_text": SchemaField(type: "string", required: false)
            ]
        )

        let receiptItemsSchema = ReceiptSchema(
            fields: [
                "receipt_id": SchemaField(type: "string", required: true),
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

    private func ensureRecordSchema(type: String, schema: ReceiptSchema, subjectID: String, chatID: String) async throws {
        let normalizedType = try nonEmpty(type, field: "type_name")
        let normalizedSubjectID = try nonEmpty(subjectID, field: "subject_id")
        let normalizedChatID = try nonEmpty(chatID, field: "chat_id")

        let preferredRequest = RecordsSchemaSchemaRequest(
            type_name: normalizedType,
            schema: schema,
            subject_id: normalizedSubjectID,
            mnx: MnxContext(subject_id: normalizedSubjectID, chat_id: normalizedChatID, history: false, learn: false, recall: false, summarize: nil)
        )
        let fallbackRequest = RecordsSchemaLegacyRequest(
            type_name: normalizedType,
            fields: schema.fields,
            subject_id: normalizedSubjectID,
            mnx: MnxContext(subject_id: normalizedSubjectID, chat_id: normalizedChatID, history: false, learn: false, recall: false, summarize: nil)
        )

        do {
            _ = try await send(path: "/api/v1/records/schemas", method: "POST", payload: preferredRequest)
        } catch let error as MnexiumClientError {
            if case .httpStatus(let status, _) = error, status == 409 {
                return
            }
            if case .httpStatus(let status, _) = error,
               status == 400 || status == 422 {
                do {
                    _ = try await send(path: "/api/v1/records/schemas", method: "POST", payload: fallbackRequest)
                    return
                } catch let fallbackError as MnexiumClientError {
                    if case .httpStatus(let fallbackStatus, _) = fallbackError, fallbackStatus == 409 {
                        return
                    }
                    throw fallbackError
                }
            }
            throw error
        }
    }

    private func send<T: Encodable>(path: String, method: String, payload: T) async throws -> Data {
        guard let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw MnexiumClientError.transport("Invalid Mnexium URL path: \(path)")
        }
        let bodyData = try JSONEncoder().encode(payload)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = bodyData
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-mnexium-key")
        if let openAIKey = configuration.openAIKey {
            request.setValue(openAIKey, forHTTPHeaderField: "x-openai-key")
        }

        return try await performRequest(request, path: path)
    }

    private func send(path: String, method: String, queryItems: [URLQueryItem]) async throws -> Data {
        guard let baseURL = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MnexiumClientError.transport("Invalid Mnexium URL path: \(path)")
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw MnexiumClientError.transport("Could not create Mnexium URL for \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-mnexium-key")
        if let openAIKey = configuration.openAIKey {
            request.setValue(openAIKey, forHTTPHeaderField: "x-openai-key")
        }

        return try await performRequest(request, path: path)
    }

    private func performRequest(_ request: URLRequest, path: String) async throws -> Data {
        let maxAttempts = 3

        for attempt in 1...maxAttempts {
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                if attempt == 1 {
                    logOutboundRequestBody(request, path: path)
                }
                let (data, response) = try await urlSession.data(for: request)
                let latency = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

                guard let http = response as? HTTPURLResponse else {
                    logger.error("Invalid response. path=\(path, privacy: .public) latency_ms=\(latency, privacy: .public)")
                    throw MnexiumClientError.invalidResponse
                }

                let requestID = requestID(from: http) ?? "none"
                logger.info(
                    "Request complete. path=\(path, privacy: .public) status=\(http.statusCode) latency_ms=\(latency, privacy: .public) attempt=\(attempt) request_id=\(requestID, privacy: .public)"
                )

                if (200...299).contains(http.statusCode) {
                    return data
                }

                logger.warning(
                    "Request failed. path=\(path, privacy: .public) status=\(http.statusCode) attempt=\(attempt) request_id=\(requestID, privacy: .public)"
                )

                if shouldRetry(status: http.statusCode), attempt < maxAttempts {
                    try await Task.sleep(nanoseconds: backoffNanoseconds(forAttempt: attempt))
                    continue
                }

                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown server response"
                throw MnexiumClientError.httpStatus(http.statusCode, errorBody)
            } catch let error as MnexiumClientError {
                if case .httpStatus(let status, _) = error,
                   shouldRetry(status: status),
                   attempt < maxAttempts {
                    try await Task.sleep(nanoseconds: backoffNanoseconds(forAttempt: attempt))
                    continue
                }
                throw error
            } catch {
                if attempt < maxAttempts {
                    try await Task.sleep(nanoseconds: backoffNanoseconds(forAttempt: attempt))
                    continue
                }
                throw MnexiumClientError.transport(error.localizedDescription)
            }
        }

        throw MnexiumClientError.transport("Exhausted retry attempts")
    }

    private func streamChat(_ payload: ChatRequest, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        guard let url = URL(string: "/api/v1/chat/completions", relativeTo: configuration.baseURL)?.absoluteURL else {
            throw MnexiumClientError.transport("Invalid Mnexium URL path: /api/v1/chat/completions")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-mnexium-key")
        if let openAIKey = configuration.openAIKey {
            request.setValue(openAIKey, forHTTPHeaderField: "x-openai-key")
        }

        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MnexiumClientError.invalidResponse
        }
        logger.info("Stream request complete. path=/api/v1/chat/completions status=\(http.statusCode)")

        guard (200...299).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line
            }
            throw MnexiumClientError.httpStatus(http.statusCode, body.isEmpty ? "Unknown server response" : body)
        }

        var chunkCount = 0
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("event:") {
                continue
            }

            let payloadString: String
            if line.hasPrefix("data:") {
                payloadString = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                payloadString = line
            }

            if payloadString == "[DONE]" {
                break
            }

            guard let data = payloadString.data(using: .utf8),
                  let chunk = try extractStreamChunk(from: data) else {
                continue
            }
            chunkCount += 1
            continuation.yield(chunk)
        }

        logger.info("Stream ended. path=/api/v1/chat/completions chunks=\(chunkCount)")
        continuation.finish()
    }

    private func extractAssistantContent(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MnexiumClientError.parse("response is not a JSON object")
        }

        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String,
           !content.isEmpty {
            return content
        }

        if let output = json["output"] as? [[String: Any]],
           let first = output.first,
           let content = first["content"] as? [[String: Any]],
           let text = content.first?["text"] as? String,
           !text.isEmpty {
            return text
        }

        throw MnexiumClientError.parse("assistant text content missing")
    }

    private func extractStreamChunk(from data: Data) throws -> String? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first {
            if let delta = first["delta"] as? [String: Any] {
                if let content = delta["content"] as? String, !content.isEmpty {
                    return content
                }

                if let contentItems = delta["content"] as? [[String: Any]] {
                    let text = contentItems.compactMap { item in
                        item["text"] as? String
                    }.joined()
                    return text.isEmpty ? nil : text
                }
            }

            if let message = first["message"] as? [String: Any],
               let content = message["content"] as? String,
               !content.isEmpty {
                return content
            }

            if let text = first["text"] as? String, !text.isEmpty {
                return text
            }
        }

        if let outputText = json["output_text"] as? String, !outputText.isEmpty {
            return outputText
        }

        if let output = json["output"] as? [[String: Any]],
           let first = output.first,
           let content = first["content"] as? [[String: Any]] {
            let text = content.compactMap { item in
                item["text"] as? String
            }.joined()
            return text.isEmpty ? nil : text
        }

        return nil
    }

    private func extractChatSummaries(from data: Data) throws -> [MnexiumChatSummary] {
        let object = try JSONSerialization.jsonObject(with: data)
        let sourceArray = findChatArray(in: object)

        let summaries: [MnexiumChatSummary] = sourceArray.compactMap { item in
            guard let chatID = firstNonEmptyString(
                from: item,
                keys: ["chat_id", "chatID", "id"]
            ) else {
                return nil
            }

            let rawTitle = firstNonEmptyString(
                from: item,
                keys: ["title", "name", "summary", "last_message"]
            )
            let title = rawTitle ?? "Chat \(chatID.prefix(8))"

            let updatedAt = parseFlexibleDate(
                from: item,
                keys: ["updated_at", "updatedAt", "last_updated", "lastUpdated", "last_message_at", "lastMessageAt", "timestamp", "time", "at"]
            )
            let createdAt = parseFlexibleDate(
                from: item,
                keys: ["created_at", "createdAt", "created", "timestamp", "time", "at"]
            )
            let messageCount = firstInt(from: item, keys: ["message_count", "messageCount", "count"])

            return MnexiumChatSummary(
                chatID: chatID,
                title: title,
                updatedAt: updatedAt,
                createdAt: createdAt,
                messageCount: messageCount
            )
        }

        return summaries.sorted { lhs, rhs in
            let lhsDate = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
            let rhsDate = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    private func extractHistoryMessages(from data: Data) throws -> [MnexiumHistoryMessage] {
        let object = try JSONSerialization.jsonObject(with: data)
        let sourceArray = findMessageArray(in: object)

        return sourceArray.compactMap { item in
            let role = firstNonEmptyString(
                from: item,
                keys: ["role", "speaker", "type"]
            ) ?? "assistant"
            let content = extractMessageContent(from: item)
            guard !content.isEmpty else { return nil }

            let createdAt = parseFlexibleDate(
                from: item,
                keys: ["created_at", "createdAt", "timestamp", "time", "at"]
            )

            return MnexiumHistoryMessage(
                role: role.lowercased(),
                content: content,
                createdAt: createdAt
            )
        }
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String,
               let normalized = normalizedOptionalString(value) {
                return normalized
            }
        }
        return nil
    }

    private func normalizedOptionalString(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private func parseDate(_ value: String) -> Date? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if let numeric = Double(normalized), let date = parseUnixTimestamp(numeric) {
            return date
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: normalized) {
            return date
        }

        let secondISOFormatter = ISO8601DateFormatter()
        secondISOFormatter.formatOptions = [.withInternetDateTime]
        if let date = secondISOFormatter.date(from: normalized) {
            return date
        }

        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd"
        ]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: normalized) {
                return date
            }
        }

        return nil
    }

    private func findChatArray(in object: Any) -> [[String: Any]] {
        if let array = object as? [[String: Any]] {
            return array
        }

        guard let json = object as? [String: Any] else {
            return []
        }

        let keys = ["chats", "items", "data", "history"]
        for key in keys {
            if let array = json[key] as? [[String: Any]] {
                return array
            }
        }

        if let dataObject = json["data"] as? [String: Any] {
            for key in keys {
                if let array = dataObject[key] as? [[String: Any]] {
                    return array
                }
            }
        }

        return []
    }

    private func findMessageArray(in object: Any) -> [[String: Any]] {
        if let array = object as? [[String: Any]] {
            return array
        }

        guard let json = object as? [String: Any] else {
            return []
        }

        let keys = ["messages", "history", "items", "data", "conversation"]
        for key in keys {
            if let array = json[key] as? [[String: Any]] {
                return array
            }
        }

        if let historyObject = json["history"] as? [String: Any] {
            for key in keys {
                if let array = historyObject[key] as? [[String: Any]] {
                    return array
                }
            }
        }

        if let dataObject = json["data"] as? [String: Any] {
            for key in keys {
                if let array = dataObject[key] as? [[String: Any]] {
                    return array
                }
            }
        }

        return []
    }

    private func findRecordArray(in object: Any) -> [[String: Any]] {
        if let array = object as? [[String: Any]] {
            return array
        }

        guard let json = object as? [String: Any] else {
            return []
        }

        let keys = ["records", "items", "data", "results", "rows"]
        for key in keys {
            if let array = json[key] as? [[String: Any]] {
                return array
            }
        }

        if let dataObject = json["data"] as? [String: Any] {
            for key in keys {
                if let array = dataObject[key] as? [[String: Any]] {
                    return array
                }
            }
        }

        if let recordsObject = json["records"] as? [String: Any],
           let array = recordsObject["items"] as? [[String: Any]] {
            return array
        }

        return []
    }

    private func firstNonEmptyString(from object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    return normalized
                }
            }
        }
        return nil
    }

    private func firstInt(from object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? Int {
                return value
            }
            if let value = object[key] as? NSNumber {
                return value.intValue
            }
            if let value = object[key] as? String, let intValue = Int(value) {
                return intValue
            }
        }
        return nil
    }

    private func firstDouble(from object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = object[key] as? Double {
                return value
            }
            if let value = object[key] as? NSNumber {
                return value.doubleValue
            }
            if let value = object[key] as? Int {
                return Double(value)
            }
            if let value = object[key] as? String,
               let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }

    private func parseFlexibleDate(from object: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let value = object[key] as? String, let parsed = parseDate(value) {
                return parsed
            }
            if let value = object[key] as? NSNumber, let parsed = parseUnixTimestamp(value.doubleValue) {
                return parsed
            }
            if let value = object[key] as? Double, let parsed = parseUnixTimestamp(value) {
                return parsed
            }
            if let value = object[key] as? Int, let parsed = parseUnixTimestamp(Double(value)) {
                return parsed
            }
        }
        return nil
    }

    private func parseUnixTimestamp(_ raw: Double) -> Date? {
        guard raw.isFinite, raw > 0 else { return nil }

        if raw > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: raw / 1_000)
        }
        return Date(timeIntervalSince1970: raw)
    }

    private func shouldFallbackFromStreaming(_ error: MnexiumClientError) -> Bool {
        guard case .httpStatus(let status, let body) = error else {
            return false
        }
        if status == 404 || status == 405 {
            return true
        }
        if status == 400 {
            let lower = body.lowercased()
            return lower.contains("stream") || lower.contains("sse")
        }
        return false
    }

    private func extractMessageContent(from object: [String: Any]) -> String {
        if let direct = firstNonEmptyString(from: object, keys: ["content", "text", "message", "value"]) {
            return direct
        }

        if let contentItems = object["content"] as? [[String: Any]] {
            let text = contentItems.compactMap { item in
                firstNonEmptyString(from: item, keys: ["text", "content", "value"])
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }

        if let contentItems = object["content"] as? [String] {
            let text = contentItems.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }

        if let messageObject = object["message"] as? [String: Any] {
            if let direct = firstNonEmptyString(from: messageObject, keys: ["content", "text", "value"]) {
                return direct
            }
            if let parts = messageObject["content"] as? [[String: Any]] {
                let text = parts.compactMap { item in
                    firstNonEmptyString(from: item, keys: ["text", "content", "value"])
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }

        return ""
    }

    private func extractReceiptRecords(from data: Data) throws -> [MnexiumReceiptRecord] {
        let object = try JSONSerialization.jsonObject(with: data)
        let sourceArray = findRecordArray(in: object)

        let parsed: [MnexiumReceiptRecord] = sourceArray.compactMap { item in
            let recordID = firstNonEmptyString(from: item, keys: ["id", "record_id", "recordId"])
            let payload = firstObject(in: item, keys: ["data", "record", "value"]) ?? item

            let receiptID = firstNonEmptyString(from: payload, keys: ["receipt_id", "receiptId"])
                ?? firstNonEmptyString(from: item, keys: ["receipt_id", "receiptId"])
                ?? recordID
                ?? UUID().uuidString.lowercased()

            let storeName = firstNonEmptyString(from: payload, keys: ["store_name", "storeName", "merchant", "name"]) ?? "Unknown Store"
            let total = firstDouble(from: payload, keys: ["total", "amount", "grand_total", "sum"]) ?? 0
            let currency = firstNonEmptyString(from: payload, keys: ["currency", "currency_code"]) ?? "USD"

            let purchasedAt = parseFlexibleDate(
                from: payload,
                keys: ["purchased_at", "purchasedAt", "date", "transaction_date", "transactionDate"]
            ) ?? parseFlexibleDate(
                from: item,
                keys: ["purchased_at", "purchasedAt", "created_at", "createdAt", "timestamp", "time", "at"]
            ) ?? Date()

            let capturedAt = parseFlexibleDate(
                from: item,
                keys: ["created_at", "createdAt", "timestamp", "time", "at"]
            ) ?? parseFlexibleDate(
                from: payload,
                keys: ["created_at", "createdAt"]
            ) ?? purchasedAt

            let rawText = firstNonEmptyString(from: payload, keys: ["raw_text", "rawText", "ocr_text", "ocrText"]) ?? ""

            return MnexiumReceiptRecord(
                id: recordID ?? receiptID,
                receiptID: receiptID,
                storeName: storeName,
                total: total,
                currency: currency,
                purchasedAt: purchasedAt,
                capturedAt: capturedAt,
                rawText: rawText
            )
        }

        return parsed.sorted { lhs, rhs in
            lhs.purchasedAt > rhs.purchasedAt
        }
    }

    private func extractReceiptItemRecords(from data: Data) throws -> [MnexiumReceiptItemRecord] {
        let object = try JSONSerialization.jsonObject(with: data)
        let sourceArray = findRecordArray(in: object)

        return sourceArray.compactMap { item in
            let recordID = firstNonEmptyString(from: item, keys: ["id", "record_id", "recordId"])
            let payload = firstObject(in: item, keys: ["data", "record", "value"]) ?? item

            let receiptID = firstNonEmptyString(from: payload, keys: ["receipt_id", "receiptId"])
                ?? firstNonEmptyString(from: item, keys: ["receipt_id", "receiptId"])
                ?? ""
            guard !receiptID.isEmpty else { return nil }

            let itemName = firstNonEmptyString(from: payload, keys: ["item_name", "itemName", "name"]) ?? "Unnamed Item"
            let quantity = firstDouble(from: payload, keys: ["quantity", "qty"])
            let unitPrice = firstDouble(from: payload, keys: ["unit_price", "unitPrice", "price"])
            let lineTotal = firstDouble(from: payload, keys: ["line_total", "lineTotal", "total", "amount"])
            let category = firstNonEmptyString(from: payload, keys: ["category"])

            return MnexiumReceiptItemRecord(
                id: recordID ?? "\(receiptID)-\(itemName)-\(UUID().uuidString.lowercased())",
                receiptID: receiptID,
                itemName: itemName,
                quantity: quantity,
                unitPrice: unitPrice,
                lineTotal: lineTotal,
                category: category
            )
        }
    }

    private func extractRecordsSyncResult(from data: Data) throws -> MnexiumRecordsSyncResult {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MnexiumClientError.parse("records sync response is not a JSON object")
        }

        let outcomeResult: MnexiumRecordsSyncResult
        if let recordsObject = findRecordsOutcomeObject(in: object, depth: 0) {
            let created = extractRecordMutations(
                from: recordsObject,
                keys: ["created", "inserted", "upserted", "writes"]
            )
            let updated = extractRecordMutations(
                from: recordsObject,
                keys: ["updated", "modified"]
            )
            let actions = extractActions(from: recordsObject, created: created, updated: updated)
            outcomeResult = MnexiumRecordsSyncResult(created: created, updated: updated, actions: actions)
        } else {
            outcomeResult = MnexiumRecordsSyncResult(
                created: [],
                updated: [],
                actions: ["records_sync_metadata_missing"]
            )
        }

        let mnxRecordsEntries = findMnxRecordsEntries(in: object, depth: 0)
        let mnxMutations = extractMnxRecordMutations(from: mnxRecordsEntries)
        if !mnxMutations.isEmpty {
            let classification = classifyMutationsFromMnxRecords(mnxMutations)
            let mergedCreated = deduplicatedMutations(outcomeResult.created + classification.created)
            let mergedUpdated = deduplicatedMutations(outcomeResult.updated + classification.updated)
            let mergedActions = deduplicatedActions(outcomeResult.actions + classification.actions)

            if mergedCreated.count != outcomeResult.created.count || mergedUpdated.count != outcomeResult.updated.count {
                logger.info(
                    "context=records_sync_augmented_with_mnx_records created=\(mergedCreated.count) updated=\(mergedUpdated.count)"
                )
            }

            return MnexiumRecordsSyncResult(
                created: mergedCreated,
                updated: mergedUpdated,
                actions: mergedActions
            )
        }

        if outcomeResult.actions.contains("records_sync_metadata_missing") {
            logger.error("context=records_sync_result_missing response=\(self.responseSnippet(from: data), privacy: .public)")
        }

        return outcomeResult
    }

    private func findRecordsOutcomeObject(in value: Any, depth: Int) -> [String: Any]? {
        guard depth <= 6 else { return nil }

        if let object = value as? [String: Any] {
            if isRecordsOutcomeObject(object) {
                return object
            }

            if let nestedRecords = firstObject(in: object, keys: ["records", "record_sync", "records_sync"]),
               isRecordsOutcomeObject(nestedRecords) {
                return nestedRecords
            }

            for key in ["mnx", "data", "response", "result", "meta", "metadata"] {
                if let nested = object[key],
                   let found = findRecordsOutcomeObject(in: nested, depth: depth + 1) {
                    return found
                }
            }

            for nested in object.values {
                if let found = findRecordsOutcomeObject(in: nested, depth: depth + 1) {
                    return found
                }
            }
        }

        if let array = value as? [Any] {
            for entry in array {
                if let found = findRecordsOutcomeObject(in: entry, depth: depth + 1) {
                    return found
                }
            }
        }

        return nil
    }

    private func isRecordsOutcomeObject(_ object: [String: Any]) -> Bool {
        let outcomeKeys = ["created", "updated", "inserted", "upserted", "writes", "modified", "actions"]
        return outcomeKeys.contains { object[$0] != nil }
    }

    private func extractRecordMutations(from object: [String: Any], keys: [String]) -> [MnexiumRecordMutation] {
        var result: [MnexiumRecordMutation] = []

        for key in keys {
            if let entries = object[key] as? [Any] {
                for entry in entries {
                    if let entryString = entry as? String {
                        result.append(MnexiumRecordMutation(id: normalizedOptionalString(entryString), table: nil, action: key))
                        continue
                    }

                    guard let entryObject = entry as? [String: Any] else { continue }

                    let id = firstString(in: entryObject, keys: ["id", "record_id", "recordID"])
                    let table = firstString(in: entryObject, keys: ["table", "type", "type_name", "record_type"])
                    let action = firstString(in: entryObject, keys: ["action", "operation", "op"]) ?? key
                    result.append(MnexiumRecordMutation(id: id, table: table, action: action))
                }
                continue
            }

            if let entryObject = object[key] as? [String: Any] {
                let id = firstString(in: entryObject, keys: ["id", "record_id", "recordID"])
                let table = firstString(in: entryObject, keys: ["table", "type", "type_name", "record_type"])
                let action = firstString(in: entryObject, keys: ["action", "operation", "op"]) ?? key
                result.append(MnexiumRecordMutation(id: id, table: table, action: action))
                continue
            }

            if let entryString = object[key] as? String {
                result.append(MnexiumRecordMutation(id: normalizedOptionalString(entryString), table: nil, action: key))
                continue
            }

            if let entriesByTable = object[key] as? [String: Any] {
                for (tableName, tableEntries) in entriesByTable {
                    guard let tableEntryArray = tableEntries as? [Any] else { continue }
                    for tableEntry in tableEntryArray {
                        if let tableEntryObject = tableEntry as? [String: Any] {
                            let id = firstString(in: tableEntryObject, keys: ["id", "record_id", "recordID"])
                            let action = firstString(in: tableEntryObject, keys: ["action", "operation", "op"]) ?? key
                            result.append(MnexiumRecordMutation(id: id, table: tableName, action: action))
                        } else if let tableEntryID = tableEntry as? String {
                            result.append(MnexiumRecordMutation(id: normalizedOptionalString(tableEntryID), table: tableName, action: key))
                        }
                    }
                }
            }
        }

        return result
    }

    private func responseSnippet(from data: Data, limit: Int = 2_000) -> String {
        let raw = String(data: data, encoding: .utf8) ?? "<non_utf8_response bytes=\(data.count)>"
        let compact = raw.replacingOccurrences(of: "\n", with: " ")
        guard compact.count > limit else { return compact }
        let index = compact.index(compact.startIndex, offsetBy: limit)
        return String(compact[..<index]) + "..."
    }

    private func extractActions(
        from recordsObject: [String: Any],
        created: [MnexiumRecordMutation],
        updated: [MnexiumRecordMutation]
    ) -> [String] {
        if let explicitActions = recordsObject["actions"] as? [Any] {
            let actions = explicitActions.compactMap { actionValue -> String? in
                if let actionString = actionValue as? String {
                    return normalizedOptionalString(actionString)
                }
                if let actionObject = actionValue as? [String: Any] {
                    return firstString(in: actionObject, keys: ["action", "operation", "op"])
                }
                return nil
            }
            if !actions.isEmpty {
                return actions
            }
        }

        return (created + updated).compactMap { $0.action }
    }

    private func findMnxRecordsEntries(in value: Any, depth: Int) -> [[String: Any]] {
        guard depth <= 6 else { return [] }

        if let object = value as? [String: Any] {
            if let mnx = object["mnx"] as? [String: Any],
               let records = mnx["records"] as? [[String: Any]],
               !records.isEmpty {
                return records
            }

            for nested in object.values {
                let discovered = findMnxRecordsEntries(in: nested, depth: depth + 1)
                if !discovered.isEmpty {
                    return discovered
                }
            }
        }

        if let array = value as? [Any] {
            for nested in array {
                let discovered = findMnxRecordsEntries(in: nested, depth: depth + 1)
                if !discovered.isEmpty {
                    return discovered
                }
            }
        }

        return []
    }

    private func extractMnxRecordMutations(from entries: [[String: Any]]) -> [MnexiumRecordMutation] {
        entries.map { entry in
            let id = firstString(in: entry, keys: ["recordId", "record_id", "recordID", "id"])
            let table = firstString(in: entry, keys: ["typeName", "type_name", "record_type", "table", "type"])
            let action = firstString(in: entry, keys: ["action", "operation", "op", "mode"]) ?? "upsert"
            return MnexiumRecordMutation(id: id, table: table, action: action)
        }
    }

    private func classifyMutationsFromMnxRecords(_ mutations: [MnexiumRecordMutation]) -> (created: [MnexiumRecordMutation], updated: [MnexiumRecordMutation], actions: [String]) {
        var created: [MnexiumRecordMutation] = []
        var updated: [MnexiumRecordMutation] = []

        for mutation in mutations {
            let action = (mutation.action ?? "upsert").lowercased()
            if action.contains("update") || action.contains("modify") || action.contains("patch") {
                updated.append(mutation)
            } else {
                created.append(mutation)
            }
        }

        let actions = mutations.compactMap { $0.action }
        return (created, updated, deduplicatedActions(actions))
    }

    private func deduplicatedMutations(_ mutations: [MnexiumRecordMutation]) -> [MnexiumRecordMutation] {
        var seen = Set<String>()
        var result: [MnexiumRecordMutation] = []

        for mutation in mutations {
            let key = "\(mutation.id ?? "nil")|\(mutation.table ?? "nil")|\(mutation.action ?? "nil")"
            if seen.insert(key).inserted {
                result.append(mutation)
            }
        }

        return result
    }

    private func deduplicatedActions(_ actions: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for action in actions {
            guard let normalized = normalizedOptionalString(action) else { continue }
            if seen.insert(normalized).inserted {
                result.append(normalized)
            }
        }

        return result
    }

    private func firstObject(in object: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = object[key] as? [String: Any] {
                return value
            }
        }
        return nil
    }

    private func normalizedJSONObjectString(from text: String) throws -> String {
        let candidate = extractJSONObject(from: text)
        guard let data = candidate.data(using: .utf8) else {
            throw MnexiumClientError.parse("assistant output is not UTF-8")
        }
        let object = try JSONSerialization.jsonObject(with: data)
        let normalizedData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard let normalizedString = String(data: normalizedData, encoding: .utf8) else {
            throw MnexiumClientError.parse("assistant output JSON could not be re-encoded")
        }
        return normalizedString
    }

    private func extractJSONObject(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("```") {
            return trimmed
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            return trimmed
        }

        return String(trimmed[start...end])
    }

    private func shouldRetry(status: Int) -> Bool {
        status == 429 || (500...599).contains(status)
    }

    private func backoffNanoseconds(forAttempt attempt: Int) -> UInt64 {
        let base: Double = 0.4
        let multiplier = pow(2.0, Double(attempt - 1))
        let jitter = Double.random(in: 0...0.2)
        let seconds = base * multiplier + jitter
        return UInt64(seconds * 1_000_000_000)
    }

    private func nonEmpty(_ value: String, field: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw MnexiumClientError.invalidInput("\(field) is required")
        }
        return normalized
    }

    private func requestID(from response: HTTPURLResponse) -> String? {
        for candidate in ["x-request-id", "x-correlation-id", "x-amzn-requestid"] {
            if let value = response.value(forHTTPHeaderField: candidate),
               let normalized = normalizedOptionalString(value) {
                return normalized
            }
        }
        return nil
    }

    private func resolvedUUIDChatID(from chatID: String) -> String {
        if let uuid = UUID(uuidString: chatID.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return uuid.uuidString.lowercased()
        }

        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: chatID, range: NSRange(location: 0, length: chatID.utf16.count)),
           let range = Range(match.range, in: chatID),
           let uuid = UUID(uuidString: String(chatID[range])) {
            return uuid.uuidString.lowercased()
        }

        return UUID().uuidString.lowercased()
    }

    private func validateReceiptPersistenceRequestShape(_ request: ChatRequest) throws {
        let data = try JSONEncoder().encode(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MnexiumClientError.invalidInput("persistence request is not a JSON object")
        }

        guard let mnx = object["mnx"] as? [String: Any] else {
            throw MnexiumClientError.invalidInput("persistence request missing mnx object")
        }

        guard let subjectID = mnx["subject_id"] as? String, !subjectID.isEmpty else {
            throw MnexiumClientError.invalidInput("persistence request missing mnx.subject_id")
        }
        guard let chatID = mnx["chat_id"] as? String, !chatID.isEmpty else {
            throw MnexiumClientError.invalidInput("persistence request missing mnx.chat_id")
        }

        guard let records = mnx["records"] as? [String: Any] else {
            throw MnexiumClientError.invalidInput("persistence request missing mnx.records")
        }
        guard let sync = records["sync"] as? Bool, sync else {
            throw MnexiumClientError.invalidInput("persistence request missing mnx.records.sync=true")
        }
        guard let tables = records["tables"] as? [String],
              Set(["receipts", "receipt_items"]).isSubset(of: Set(tables)) else {
            throw MnexiumClientError.invalidInput("persistence request missing required mnx.records.tables values")
        }
    }

    private func logOutboundRequestBody(_ request: URLRequest, path: String) {
        guard let body = request.httpBody else {
            logger.info("Outbound request. path=\(path, privacy: .public) body=none")
            return
        }

        guard let bodyString = String(data: body, encoding: .utf8) else {
            logger.info("Outbound request. path=\(path, privacy: .public) body_utf8=false bytes=\(body.count)")
            return
        }

        let hasMnx = bodyString.contains(#""mnx":{"#)
        let hasRecordsSync = bodyString.contains(#""records":{"#) && bodyString.contains(#""sync":true"#)
        let hasReceiptTables = bodyString.contains(#""tables":["receipts","receipt_items"]"#)
        let snippet = responseSnippet(from: body, limit: 2_500)

        logger.info(
            "Outbound request. path=\(path, privacy: .public) has_mnx=\(hasMnx) has_records_sync=\(hasRecordsSync) has_receipt_tables=\(hasReceiptTables) body=\(snippet, privacy: .public)"
        )
    }

}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let mnx: MnxContext
    let stream: Bool?
}

private struct ChatMessage: Encodable {
    let role: String
    let content: String
}

private struct VisionChatRequest: Encodable {
    let model: String
    let messages: [VisionChatMessage]
    let temperature: Double
    let mnx: MnxContext
    let stream: Bool?
}

private struct VisionChatMessage: Encodable {
    let role: String
    let content: [VisionContentPart]
}

private enum VisionContentPart: Encodable {
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

private struct VisionImageURL: Encodable {
    let url: String
}

private struct MnxContext: Encodable {
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

private struct MnxRecordsContext: Encodable {
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

private struct RecordsSchemaSchemaRequest: Encodable {
    let type_name: String
    let schema: ReceiptSchema
    let subject_id: String
    let mnx: MnxContext
}

private struct RecordsSchemaLegacyRequest: Encodable {
    let type_name: String
    let fields: [String: SchemaField]
    let subject_id: String
    let mnx: MnxContext
}

private struct RecordsQueryRequest: Encodable {
    let `where`: [String: String]
    let order_by: String?
    let limit: Int?
    let offset: Int?
}

private struct ReceiptSchema: Encodable {
    let fields: [String: SchemaField]
}

private struct SchemaField: Encodable {
    let type: String
    let required: Bool
}
