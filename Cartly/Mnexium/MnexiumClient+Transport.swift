import Foundation
import OSLog

extension MnexiumClient {
    func send<T: Encodable>(path: String, method: String, payload: T) async throws -> Data {
        guard let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw MnexiumClientError.transport("Invalid Mnexium URL path: \(path)")
        }
        let bodyData = try JSONEncoder().encode(payload)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = bodyData
        request.timeoutInterval = timeoutForPath(path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-mnexium-key")
        if let openAIKey = configuration.openAIKey {
            request.setValue(openAIKey, forHTTPHeaderField: "x-openai-key")
        }

        return try await performRequest(request, path: path)
    }

    func send(path: String, method: String, queryItems: [URLQueryItem]) async throws -> Data {
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
        request.timeoutInterval = timeoutForPath(path)
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-mnexium-key")
        if let openAIKey = configuration.openAIKey {
            request.setValue(openAIKey, forHTTPHeaderField: "x-openai-key")
        }

        return try await performRequest(request, path: path)
    }

    func performRequest(_ request: URLRequest, path: String) async throws -> Data {
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

    func timeoutForPath(_ path: String) -> TimeInterval {
        if path == "/api/v1/chat/completions" {
            return 240
        }
        return 30
    }

    func timeoutForStreamingPath(_ path: String) -> TimeInterval {
        if path == "/api/v1/chat/completions" {
            return 360
        }
        return 60
    }

    func streamChat(_ payload: ChatRequest, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let path = "/api/v1/chat/completions"
        guard let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw MnexiumClientError.transport("Invalid Mnexium URL path: \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = timeoutForStreamingPath(path)
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

    func extractAssistantContent(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MnexiumClientError.parse("response is not a JSON object")
        }

        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String,
           !content.isEmpty {
            return content
        }

        throw MnexiumClientError.parse("assistant text content missing")
    }

    func extractStreamChunk(from data: Data) throws -> String? {
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
        }

        return nil
    }

    func shouldRetry(status: Int) -> Bool {
        status == 429 || (500...599).contains(status)
    }

    func backoffNanoseconds(forAttempt attempt: Int) -> UInt64 {
        let base: Double = 0.4
        let multiplier = pow(2.0, Double(attempt - 1))
        let jitter = Double.random(in: 0...0.2)
        let seconds = base * multiplier + jitter
        return UInt64(seconds * 1_000_000_000)
    }

    func nonEmpty(_ value: String, field: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw MnexiumClientError.invalidInput("\(field) is required")
        }
        return normalized
    }

    func encodedPathComponent(_ value: String, field: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty else {
            throw MnexiumClientError.invalidInput("Invalid path component for \(field)")
        }
        return encoded
    }

    var iso8601Formatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    func requestID(from response: HTTPURLResponse) -> String? {
        guard let value = response.value(forHTTPHeaderField: "x-request-id") else {
            return nil
        }
        return normalizedOptionalString(value)
    }

    func resolvedUUIDChatID(from chatID: String) throws -> String {
        let trimmed = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmed) else {
            throw MnexiumClientError.invalidInput("chat_id must be a valid UUID")
        }
        return uuid.uuidString.lowercased()
    }

    func validateReceiptPersistenceRequestShape(_ request: ChatRequest) throws {
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
        guard UUID(uuidString: chatID.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else {
            throw MnexiumClientError.invalidInput("persistence request mnx.chat_id must be a valid UUID")
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

    func logOutboundRequestBody(_ request: URLRequest, path: String) {
        guard let body = request.httpBody else {
            logger.info("Outbound request. path=\(path, privacy: .public) body=none")
            return
        }

        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let mnx = object?["mnx"] as? [String: Any]
        let records = mnx?["records"] as? [String: Any]
        let hasMnx = mnx != nil
        let hasRecordsSync = (records?["sync"] as? Bool) == true
        let tables = records?["tables"] as? [String] ?? []
        let hasReceiptTables = Set(["receipts", "receipt_items"]).isSubset(of: Set(tables))

        logger.info(
            "Outbound request. path=\(path, privacy: .public) bytes=\(body.count) has_mnx=\(hasMnx) has_records_sync=\(hasRecordsSync) has_receipt_tables=\(hasReceiptTables)"
        )
    }

}
