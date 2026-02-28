import Foundation

extension MnexiumClient {
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

            let requestPayload = buildChatRequest(
                message: normalizedMessage,
                subjectID: normalizedSubjectID,
                chatID: normalizedChatID,
                stream: true
            )

            Task {
                do {
                    try await streamChat(requestPayload, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func buildChatRequest(message: String, subjectID: String, chatID: String, stream: Bool) -> ChatRequest {
        ChatRequest(
            model: configuration.model,
            messages: [
                ChatMessage(role: "user", content: message)
            ],
            temperature: 0.2,
            mnx: MnxContext(
                subject_id: subjectID,
                chat_id: chatID,
                history: true,
                learn: true,
                recall: true,
                summarize: "balanced",
                records: MnxRecordsContext(
                    learn: "auto",
                    recall: true,
                    tables: ["receipts", "receipt_items"]
                )
            ),
            stream: stream ? true : nil
        )
    }

    func listChats(subjectID: String, limit: Int = 50) async throws -> [MnexiumChatSummary] {
        let normalizedSubjectID = try nonEmpty(subjectID, field: "subject_id")
        let normalizedLimit = max(1, min(limit, 500))
        let data = try await send(
            path: "/api/v1/chat/history/list",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "subject_id", value: normalizedSubjectID),
                URLQueryItem(name: "limit", value: String(normalizedLimit))
            ]
        )
        return try extractChatSummaries(from: data)
    }

    func readChatHistory(subjectID: String, chatID: String, limit: Int = 200) async throws -> [MnexiumHistoryMessage] {
        let normalizedSubjectID = try nonEmpty(subjectID, field: "subject_id")
        let normalizedChatID = try nonEmpty(chatID, field: "chat_id")
        let normalizedLimit = max(1, min(limit, 500))
        let data = try await send(
            path: "/api/v1/chat/history/read",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "subject_id", value: normalizedSubjectID),
                URLQueryItem(name: "chat_id", value: normalizedChatID),
                URLQueryItem(name: "limit", value: String(normalizedLimit))
            ]
        )
        return try extractHistoryMessages(from: data)
    }
}
