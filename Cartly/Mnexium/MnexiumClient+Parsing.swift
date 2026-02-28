import Foundation
import OSLog

extension MnexiumClient {
    func extractChatSummaries(from data: Data) throws -> [MnexiumChatSummary] {
        let rows = try extractChatSummaryRows(from: data)

        let summaries: [MnexiumChatSummary] = rows.compactMap { item in
            guard let chatID = string(from: item, key: "chat_id") ?? string(from: item, key: "id") else {
                return nil
            }

            let title = string(from: item, key: "title") ?? "Chat \(chatID.prefix(8))"
            let updatedAt = parseDate(from: item, key: "last_time") ?? parseDate(from: item, key: "updated_at")
            let createdAt = parseDate(from: item, key: "created_at")
            let messageCount = int(from: item, key: "message_count")

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

    func extractHistoryMessages(from data: Data) throws -> [MnexiumHistoryMessage] {
        let rows = try extractHistoryRows(from: data)
        let messages: [MnexiumHistoryMessage] = rows.compactMap { item in
            let payload = historyMessagePayload(from: item)
            let role = string(from: payload, key: "role") ?? "assistant"
            guard let content = extractHistoryContent(from: payload) else { return nil }

            let createdAt = parseDate(from: item, key: "event_time")
                ?? parseDate(from: payload, key: "event_time")
                ?? parseDate(from: item, key: "created_at")
                ?? parseDate(from: payload, key: "created_at")

            return MnexiumHistoryMessage(
                role: role.lowercased(),
                content: content,
                createdAt: createdAt
            )
        }

        if !rows.isEmpty, messages.isEmpty {
            if let firstRow = rows.first,
               let rowData = try? JSONSerialization.data(withJSONObject: firstRow) {
                logger.error("context=extract_history_messages_dropped rows=\(rows.count) first_row=\(self.responseSnippet(from: rowData), privacy: .public)")
            } else {
                logger.error("context=extract_history_messages_dropped rows=\(rows.count) first_row=<unserializable>")
            }
        }

        return messages
    }

    func extractReceiptRecords(from data: Data) throws -> [MnexiumReceiptRecord] {
        let rows = try extractRows(from: data)

        let parsed: [MnexiumReceiptRecord] = rows.compactMap { item in
            guard let recordID = recordID(from: item),
                  let payload = recordPayload(from: item),
                  let storeName = string(from: payload, key: "store_name"),
                  let total = double(from: payload, key: "total"),
                  let currency = string(from: payload, key: "currency") else {
                return nil
            }

            let purchasedAt = parseDate(from: payload, key: "purchased_at") ?? Date()
            let capturedAt = parseDate(from: item, key: "created_at") ?? purchasedAt
            let rawText = string(from: payload, key: "raw_text") ?? ""

            return MnexiumReceiptRecord(
                id: recordID,
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

    func extractReceiptItemRecords(from data: Data) throws -> [MnexiumReceiptItemRecord] {
        let rows = try extractRows(from: data)

        return rows.compactMap { item in
            guard let recordID = recordID(from: item),
                  let payload = recordPayload(from: item),
                  let receiptID = string(from: payload, key: "receipt_id"),
                  let itemName = string(from: payload, key: "item_name") else {
                return nil
            }

            return MnexiumReceiptItemRecord(
                id: recordID,
                receiptID: receiptID,
                itemName: itemName,
                quantity: double(from: payload, key: "quantity"),
                unitPrice: double(from: payload, key: "unit_price"),
                lineTotal: double(from: payload, key: "line_total"),
                category: string(from: payload, key: "category")
            )
        }
    }

    func extractRecordsSyncResult(from data: Data) throws -> MnexiumRecordsSyncResult {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MnexiumClientError.parse("records sync response is not a JSON object")
        }

        let recordsObject = object["records"] as? [String: Any]
        let createdFromRecords = extractRecordMutations(from: recordsObject?["created"], tableKey: "table")
        let updatedFromRecords = extractRecordMutations(from: recordsObject?["updated"], tableKey: "table")
        let actionsFromRecords = extractActions(from: recordsObject?["actions"])

        let mnxRecords = ((object["mnx"] as? [String: Any])?["records"] as? [[String: Any]]) ?? []
        let mnxMutations = extractRecordMutations(from: mnxRecords, tableKey: "type_name").map {
            MnexiumRecordMutation(id: $0.id, table: $0.table, action: $0.action ?? "upsert")
        }
        let classifiedMnx = classifyMutationsByAction(mnxMutations)

        let mergedCreated = deduplicatedMutations(createdFromRecords + classifiedMnx.created)
        let mergedUpdated = deduplicatedMutations(updatedFromRecords + classifiedMnx.updated)

        var mergedActions = deduplicatedActions(actionsFromRecords + mnxMutations.compactMap { $0.action })
        if mergedActions.isEmpty {
            mergedActions = deduplicatedActions((mergedCreated + mergedUpdated).compactMap { $0.action })
        }

        if mergedCreated.isEmpty && mergedUpdated.isEmpty {
            mergedActions = deduplicatedActions(mergedActions + ["records_sync_metadata_missing"])
            logger.error("context=records_sync_result_missing response=\(self.responseSnippet(from: data), privacy: .public)")
        }

        return MnexiumRecordsSyncResult(
            created: mergedCreated,
            updated: mergedUpdated,
            actions: mergedActions
        )
    }

    func normalizedOptionalString(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    func normalizedJSONObjectString(from text: String) throws -> String {
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

    func extractJSONObject(from text: String) -> String {
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

    private func extractRows(from data: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: data)

        if let rows = object as? [[String: Any]] {
            return rows
        }

        guard let json = object as? [String: Any] else {
            return []
        }

        if let rows = json["data"] as? [[String: Any]] {
            return rows
        }

        if let rows = json["records"] as? [[String: Any]] {
            return rows
        }

        if let rows = json["items"] as? [[String: Any]] {
            return rows
        }

        if let dataObject = json["data"] as? [String: Any] {
            if let rows = dataObject["records"] as? [[String: Any]] {
                return rows
            }
            if let rows = dataObject["items"] as? [[String: Any]] {
                return rows
            }
            if let rows = dataObject["rows"] as? [[String: Any]] {
                return rows
            }
        }

        logger.error("context=extract_rows_unrecognized response=\(self.responseSnippet(from: data), privacy: .public)")
        return []
    }

    private func extractChatSummaryRows(from data: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: data)

        if let rows = object as? [[String: Any]] {
            return rows
        }

        guard let json = object as? [String: Any] else {
            return []
        }

        if let rows = json["chats"] as? [[String: Any]] {
            return rows
        }
        if let rows = json["data"] as? [[String: Any]] {
            return rows
        }
        if let dataObject = json["data"] as? [String: Any],
           let rows = dataObject["chats"] as? [[String: Any]] {
            return rows
        }

        logger.error("context=extract_chat_summaries_unrecognized response=\(self.responseSnippet(from: data), privacy: .public)")
        return []
    }

    private func extractHistoryRows(from data: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: data)

        if let rows = object as? [[String: Any]] {
            return rows
        }

        guard let json = object as? [String: Any] else {
            return []
        }

        if let rows = json["messages"] as? [[String: Any]] {
            return rows
        }
        if let rows = json["data"] as? [[String: Any]] {
            return rows
        }
        if let dataObject = json["data"] as? [String: Any] {
            if let rows = dataObject["messages"] as? [[String: Any]] {
                return rows
            }
            if let chatObject = dataObject["chat"] as? [String: Any],
               let rows = chatObject["messages"] as? [[String: Any]] {
                return rows
            }
            if let historyObject = dataObject["history"] as? [String: Any],
               let rows = historyObject["messages"] as? [[String: Any]] {
                return rows
            }
        }
        if let chatObject = json["chat"] as? [String: Any],
           let rows = chatObject["messages"] as? [[String: Any]] {
            return rows
        }
        if let historyObject = json["history"] as? [String: Any],
           let rows = historyObject["messages"] as? [[String: Any]] {
            return rows
        }

        logger.error("context=extract_history_unrecognized response=\(self.responseSnippet(from: data), privacy: .public)")
        return []
    }

    private func extractHistoryContent(from item: [String: Any]) -> String? {
        if let message = string(from: item, key: "message") {
            return message
        }
        if let content = string(from: item, key: "content") {
            return content
        }

        if let text = string(from: item, key: "text") {
            return text
        }
        if let outputText = string(from: item, key: "output_text") {
            return outputText
        }
        if let inputText = string(from: item, key: "input_text") {
            return inputText
        }

        if let contentObject = item["content"] as? [String: Any] {
            if let text = string(from: contentObject, key: "text") {
                return text
            }
            if let text = string(from: contentObject, key: "output_text") {
                return text
            }
            if let text = string(from: contentObject, key: "input_text") {
                return text
            }
            if let parts = contentObject["parts"] as? [[String: Any]] {
                let text = parts.compactMap { string(from: $0, key: "text") }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return text
                }
            }
        }

        if let parts = item["content"] as? [[String: Any]] {
            let text = parts.compactMap { part in
                string(from: part, key: "text")
                    ?? string(from: part, key: "output_text")
                    ?? string(from: part, key: "input_text")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }

        if let parts = item["parts"] as? [[String: Any]] {
            let text = parts.compactMap { string(from: $0, key: "text") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }

        return nil
    }

    private func historyMessagePayload(from item: [String: Any]) -> [String: Any] {
        (item["message"] as? [String: Any]) ?? item
    }

    private func extractRecordMutations(from value: Any?, tableKey: String) -> [MnexiumRecordMutation] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let recordID = string(from: entry, key: "record_id") else { return nil }
            return MnexiumRecordMutation(
                id: recordID,
                table: string(from: entry, key: tableKey),
                action: string(from: entry, key: "action")
            )
        }
    }

    private func extractActions(from value: Any?) -> [String] {
        guard let actions = value as? [String] else { return [] }
        return deduplicatedActions(actions)
    }

    private func classifyMutationsByAction(_ mutations: [MnexiumRecordMutation]) -> (
        created: [MnexiumRecordMutation],
        updated: [MnexiumRecordMutation]
    ) {
        var created: [MnexiumRecordMutation] = []
        var updated: [MnexiumRecordMutation] = []

        for mutation in mutations {
            let action = (mutation.action ?? "upsert").lowercased()
            if action.contains("update") || action.contains("patch") || action.contains("modify") {
                updated.append(mutation)
            } else {
                created.append(mutation)
            }
        }

        return (created, updated)
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

    private func string(from object: [String: Any], key: String) -> String? {
        normalizedOptionalString(object[key] as? String)
    }

    private func recordID(from item: [String: Any]) -> String? {
        string(from: item, key: "record_id") ?? string(from: item, key: "id")
    }

    private func recordPayload(from item: [String: Any]) -> [String: Any]? {
        if let payload = item["data"] as? [String: Any] {
            return payload
        }
        if let payload = item["record"] as? [String: Any] {
            return payload
        }
        return item
    }

    private func int(from object: [String: Any], key: String) -> Int? {
        if let value = object[key] as? Int { return value }
        if let value = object[key] as? NSNumber { return value.intValue }
        if let value = object[key] as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func double(from object: [String: Any], key: String) -> Double? {
        if let value = object[key] as? Double { return value }
        if let value = object[key] as? NSNumber { return value.doubleValue }
        if let value = object[key] as? Int { return Double(value) }
        if let value = object[key] as? String {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func parseDate(from object: [String: Any], key: String) -> Date? {
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
        return nil
    }

    private func parseDate(_ value: String) -> Date? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if let numeric = Double(normalized), let date = parseUnixTimestamp(numeric) {
            return date
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: normalized) {
            return date
        }

        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime]
        if let date = internet.date(from: normalized) {
            return date
        }

        let sqlFractional = DateFormatter()
        sqlFractional.locale = Locale(identifier: "en_US_POSIX")
        sqlFractional.timeZone = TimeZone(secondsFromGMT: 0)
        sqlFractional.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        if let date = sqlFractional.date(from: normalized) {
            return date
        }

        let sql = DateFormatter()
        sql.locale = Locale(identifier: "en_US_POSIX")
        sql.timeZone = TimeZone(secondsFromGMT: 0)
        sql.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return sql.date(from: normalized)
    }

    private func parseUnixTimestamp(_ raw: Double) -> Date? {
        guard raw.isFinite, raw > 0 else { return nil }
        if raw > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: raw / 1_000)
        }
        return Date(timeIntervalSince1970: raw)
    }

    private func responseSnippet(from data: Data, limit: Int = 2_000) -> String {
        let raw = String(data: data, encoding: .utf8) ?? "<non_utf8_response bytes=\(data.count)>"
        let compact = raw.replacingOccurrences(of: "\n", with: " ")
        guard compact.count > limit else { return compact }
        let index = compact.index(compact.startIndex, offsetBy: limit)
        return String(compact[..<index]) + "..."
    }
}
