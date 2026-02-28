import Combine
import Foundation
import OSLog
import UIKit

struct AppServiceError: Sendable {
    let code: String
    let statusCode: Int?
    let retryable: Bool
    let userMessage: String
}

enum ReceiptOCRError: LocalizedError {
    case noImageData

    var errorDescription: String? {
        switch self {
        case .noImageData:
            return "Could not read image data for OCR."
        }
    }
}

@MainActor
final class ReceiptCaptureViewModel: ObservableObject {
    @Published var isProcessing = false
    @Published var errorMessage = ""
    @Published var showingError = false
    @Published var receipts: [ReceiptEntry] = []
    @Published var isLoadingReceipts = false
    @Published var receiptsLoadMessage: String?
    @Published var receiptItemsByReceiptID: [String: [ReceiptItemEntry]] = [:]
    @Published var loadingReceiptItemIDs: Set<String> = []
    @Published var receiptItemsLoadMessages: [String: String] = [:]
    @Published var customMnexiumAPIKey = ""
    @Published var customOpenAIAPIKey = ""

    private let identityStore: MnexiumIdentityStore
    private let apiKeysStore: MnexiumAPIKeysStore
    private let secretsService: LambdaSecretsService?
    private var mnexiumClient: MnexiumClient?
    private let logger = Logger(subsystem: "com.marius.Cartly", category: "AppErrors")

    init(
        identityStore: MnexiumIdentityStore? = nil,
        apiKeysStore: MnexiumAPIKeysStore? = nil,
        secretsService: LambdaSecretsService? = nil
    ) {
        self.identityStore = identityStore ?? MnexiumIdentityStore()
        self.apiKeysStore = apiKeysStore ?? MnexiumAPIKeysStore()
        self.secretsService = secretsService ?? (try? LambdaSecretsService())
        let persistedKeys = self.apiKeysStore.currentKeys()
        self.customMnexiumAPIKey = persistedKeys.mnexiumAPIKey
        self.customOpenAIAPIKey = persistedKeys.openAIAPIKey

        if configureClientFromCustomKeysIfPresent() {
            Task {
                await refreshReceipts(force: true)
            }
            return
        }

        if let cachedSecrets = self.secretsService?.cachedSecrets(),
           let configuration = MnexiumConfiguration.fromRemoteKeys(
                mnexiumApiKey: cachedSecrets.mnexiumApiKey,
                openAIKey: cachedSecrets.openaiApiKey
           ) {
            self.mnexiumClient = MnexiumClient(configuration: configuration)
        }

        Task {
            await refreshSecretsFromRemote()
        }
    }

    private func refreshSecretsFromRemote() async {
        if configureClientFromCustomKeysIfPresent() {
            await refreshReceipts(force: true)
            return
        }

        if let secretsService {
            do {
                let secrets = try await secretsService.fetchAndCacheSecrets()
                guard let configuration = MnexiumConfiguration.fromRemoteKeys(
                    mnexiumApiKey: secrets.mnexiumApiKey,
                    openAIKey: secrets.openaiApiKey
                ) else {
                    throw LambdaSecretsError.missingMnexiumKey
                }

                self.mnexiumClient = MnexiumClient(configuration: configuration)
                await refreshReceipts(force: true)
                return
            } catch {
                logError(error, context: "secrets_refresh")
                if mnexiumClient != nil {
                    return
                }
            }
        }

        if let configuration = MnexiumConfiguration.fromEnvironment() {
            self.mnexiumClient = MnexiumClient(configuration: configuration)
            await refreshReceipts(force: true)
        } else {
            self.mnexiumClient = nil
        }
    }

    var usingCustomAPIKeys: Bool {
        !customMnexiumAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func saveAPIKeys(mnexiumAPIKey: String, openAIAPIKey: String) async {
        let normalizedMnexium = mnexiumAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOpenAI = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        apiKeysStore.save(mnexiumAPIKey: normalizedMnexium, openAIAPIKey: normalizedOpenAI)
        customMnexiumAPIKey = normalizedMnexium
        customOpenAIAPIKey = normalizedOpenAI

        if configureClientFromCustomKeysIfPresent() {
            await refreshReceipts(force: true)
            return
        }

        await refreshSecretsFromRemote()
    }

    func captureReceipt(from image: UIImage) async {
        guard !isProcessing else { return }

        isProcessing = true
        defer { isProcessing = false }

        do {
            guard let mnexiumClient else {
                throw MnexiumClientError.transport("Mnexium is not connected yet.")
            }

            let identity = identityStore.currentIdentity()
            guard let compressedImageData = optimizedJPEGDataForMnexiumOCR(from: image) else {
                throw ReceiptOCRError.noImageData
            }
            logger.info("context=receipt_ocr_image_prepared bytes=\(compressedImageData.count)")

            let syncResult = try await mnexiumClient.captureReceiptToRecords(
                imageJPEGData: compressedImageData,
                subjectID: identity.subjectID,
                chatID: identity.chatID
            )
            logger.info(
                "context=receipt_capture_synced record_id=\(syncResult.primaryRecordID ?? "none", privacy: .public) created=\(syncResult.created.count) updated=\(syncResult.updated.count)"
            )
            await refreshReceipts(force: true)
        } catch {
            reportUserSafeError(
                error,
                context: "capture_receipt",
                userMessage: "Couldn’t save receipt to Mnexium right now. Please try again."
            )
        }
    }

    func streamChatMessage(_ message: String) -> AsyncThrowingStream<String, Error> {
        guard let mnexiumClient else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: MnexiumClientError.transport("Mnexium is not connected yet."))
            }
        }

        let identity = identityStore.currentIdentity()
        return mnexiumClient.streamChatMessage(
            message,
            subjectID: identity.subjectID,
            chatID: identity.chatID
        )
    }

    func listChats() async throws -> [MnexiumChatSummary] {
        guard let mnexiumClient else {
            throw MnexiumClientError.transport("Mnexium is not connected yet.")
        }

        let identity = identityStore.currentIdentity()
        return try await mnexiumClient.listChats(subjectID: identity.subjectID)
    }

    func readChatHistory(chatID: String) async throws -> [MnexiumHistoryMessage] {
        guard let mnexiumClient else {
            throw MnexiumClientError.transport("Mnexium is not connected yet.")
        }

        let identity = identityStore.currentIdentity()
        return try await mnexiumClient.readChatHistory(subjectID: identity.subjectID, chatID: chatID)
    }

    func refreshReceipts(force: Bool) async {
        guard let mnexiumClient else {
            receipts = []
            receiptsLoadMessage = "Mnexium is not connected yet."
            return
        }
        if isLoadingReceipts { return }
        if !force && !receipts.isEmpty { return }

        isLoadingReceipts = true
        receiptsLoadMessage = nil
        defer { isLoadingReceipts = false }

        do {
            let identity = identityStore.currentIdentity()
            let remoteReceipts = try await mnexiumClient.listReceiptRecords(subjectID: identity.subjectID)
            receipts = remoteReceipts.map { record in
                ReceiptEntry(
                    id: record.id,
                    storeName: record.storeName,
                    total: record.total,
                    currency: record.currency,
                    purchasedAt: record.purchasedAt,
                    capturedAt: record.capturedAt,
                    rawText: record.rawText,
                    mnexiumRecordID: record.id
                )
            }
            let validIDs = Set(receipts.map(\.id))
            receiptItemsByReceiptID = receiptItemsByReceiptID.filter { validIDs.contains($0.key) }
            receiptItemsLoadMessages = receiptItemsLoadMessages.filter { validIDs.contains($0.key) }
            if receipts.isEmpty {
                receiptsLoadMessage = "No receipts synced yet."
            }
        } catch {
            receipts = []
            receiptsLoadMessage = "Couldn’t load receipts. Pull to refresh."
            logError(error, context: "list_receipts")
        }
    }

    func deleteReceipts(at offsets: IndexSet) async {
        guard let mnexiumClient else {
            presentError("Mnexium is not connected yet.")
            return
        }
        guard !offsets.isEmpty else { return }

        let identity = identityStore.currentIdentity()
        let sortedOffsets = offsets.sorted(by: >)

        do {
            for offset in sortedOffsets {
                guard receipts.indices.contains(offset) else { continue }
                let receipt = receipts[offset]
                let recordID = receipt.mnexiumRecordID ?? receipt.id

                let relatedItems = try await mnexiumClient.queryReceiptItems(
                    subjectID: identity.subjectID,
                    receiptID: receipt.id
                )
                for item in relatedItems {
                    do {
                        try await mnexiumClient.deleteReceiptItemRecord(
                            subjectID: identity.subjectID,
                            recordID: item.id
                        )
                    } catch {
                        logError(error, context: "delete_receipt_item")
                    }
                }

                try await mnexiumClient.deleteReceiptRecord(
                    subjectID: identity.subjectID,
                    recordID: recordID
                )

                receipts.remove(at: offset)
                receiptItemsByReceiptID[receipt.id] = nil
                receiptItemsLoadMessages[receipt.id] = nil
            }

            if receipts.isEmpty {
                receiptsLoadMessage = "No receipts synced yet."
            }
        } catch {
            reportUserSafeError(
                error,
                context: "delete_receipt",
                userMessage: "Couldn’t delete receipt from Mnexium right now. Please try again."
            )
        }
    }

    func createManualReceipt(
        storeName: String,
        total: Double,
        currency: String,
        purchasedAt: Date,
        rawText: String
    ) async -> Bool {
        guard let mnexiumClient else {
            presentError("Mnexium is not connected yet.")
            return false
        }

        let trimmedStoreName = storeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStoreName.isEmpty else {
            presentError("Store name is required.")
            return false
        }
        guard total.isFinite else {
            presentError("Total amount is invalid.")
            return false
        }

        let normalizedCurrency = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let finalCurrency = normalizedCurrency.isEmpty ? "USD" : normalizedCurrency

        do {
            let identity = identityStore.currentIdentity()
            try await mnexiumClient.createReceiptRecord(
                subjectID: identity.subjectID,
                chatID: identity.chatID,
                storeName: trimmedStoreName,
                total: total,
                currency: finalCurrency,
                purchasedAt: purchasedAt,
                rawText: rawText
            )
            await refreshReceipts(force: true)
            return true
        } catch {
            reportUserSafeError(
                error,
                context: "create_manual_receipt",
                userMessage: "Couldn’t add receipt to Mnexium right now. Please try again."
            )
            return false
        }
    }

    func createManualReceiptItem(
        receiptID: String,
        itemName: String,
        quantity: Double?,
        unitPrice: Double?,
        lineTotal: Double?,
        category: String?
    ) async -> Bool {
        guard let mnexiumClient else {
            presentError("Mnexium is not connected yet.")
            return false
        }

        let normalizedReceiptID = receiptID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedItemName = itemName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedReceiptID.isEmpty else {
            presentError("Receipt ID is missing.")
            return false
        }
        guard !normalizedItemName.isEmpty else {
            presentError("Item name is required.")
            return false
        }
        if let quantity, (!quantity.isFinite || quantity < 0) {
            presentError("Quantity must be a valid number.")
            return false
        }
        if let unitPrice, (!unitPrice.isFinite || unitPrice < 0) {
            presentError("Unit price must be a valid number.")
            return false
        }
        if let lineTotal, (!lineTotal.isFinite || lineTotal < 0) {
            presentError("Line total must be a valid number.")
            return false
        }

        do {
            let identity = identityStore.currentIdentity()
            try await mnexiumClient.createReceiptItemRecord(
                subjectID: identity.subjectID,
                chatID: identity.chatID,
                receiptID: normalizedReceiptID,
                itemName: normalizedItemName,
                quantity: quantity,
                unitPrice: unitPrice,
                lineTotal: lineTotal,
                category: category
            )
            await loadReceiptItems(receiptID: normalizedReceiptID, force: true)
            return true
        } catch {
            reportUserSafeError(
                error,
                context: "create_manual_receipt_item",
                userMessage: "Couldn’t add receipt item to Mnexium right now. Please try again."
            )
            return false
        }
    }

    func deleteReceiptItems(receiptID: String, at offsets: IndexSet) async {
        guard let mnexiumClient else {
            presentError("Mnexium is not connected yet.")
            return
        }
        guard !offsets.isEmpty else { return }
        guard var items = receiptItemsByReceiptID[receiptID], !items.isEmpty else { return }

        let identity = identityStore.currentIdentity()
        let sortedOffsets = offsets.sorted(by: >)

        do {
            for offset in sortedOffsets {
                guard items.indices.contains(offset) else { continue }
                let item = items[offset]
                try await mnexiumClient.deleteReceiptItemRecord(
                    subjectID: identity.subjectID,
                    recordID: item.id
                )
                items.remove(at: offset)
            }

            receiptItemsByReceiptID[receiptID] = items
            if items.isEmpty {
                receiptItemsLoadMessages[receiptID] = "No items found for this receipt."
            }
        } catch {
            reportUserSafeError(
                error,
                context: "delete_receipt_items",
                userMessage: "Couldn’t delete receipt item right now. Please try again."
            )
        }
    }

    func loadReceiptItems(receiptID: String, force: Bool = false) async {
        guard let mnexiumClient else {
            receiptItemsLoadMessages[receiptID] = "Mnexium is not connected yet."
            return
        }
        if loadingReceiptItemIDs.contains(receiptID) { return }
        if !force, receiptItemsByReceiptID[receiptID] != nil { return }

        loadingReceiptItemIDs.insert(receiptID)
        receiptItemsLoadMessages[receiptID] = nil
        defer { loadingReceiptItemIDs.remove(receiptID) }

        do {
            let identity = identityStore.currentIdentity()
            let items = try await mnexiumClient.queryReceiptItems(
                subjectID: identity.subjectID,
                receiptID: receiptID
            )
            receiptItemsByReceiptID[receiptID] = items.map { item in
                ReceiptItemEntry(
                    id: item.id,
                    receiptID: item.receiptID,
                    itemName: item.itemName,
                    quantity: item.quantity,
                    unitPrice: item.unitPrice,
                    lineTotal: item.lineTotal,
                    category: item.category
                )
            }
            if receiptItemsByReceiptID[receiptID]?.isEmpty == true {
                receiptItemsLoadMessages[receiptID] = "No items found for this receipt."
            }
        } catch {
            receiptItemsByReceiptID[receiptID] = []
            receiptItemsLoadMessages[receiptID] = "Couldn’t load receipt items."
            logError(error, context: "list_receipt_items")
        }
    }

    func activeChatID() -> String {
        identityStore.currentIdentity().chatID
    }

    func activateChat(chatID: String) {
        identityStore.setChatID(chatID)
    }

    func startNewChatSession() -> String {
        identityStore.startNewChatID()
    }

    private func optimizedJPEGDataForMnexiumOCR(from image: UIImage, maxBytes: Int = 900_000) -> Data? {
        let maxDimensions: [CGFloat] = [1800, 1536, 1280, 1024, 900, 768, 640]
        let compressionQualities: [CGFloat] = [0.82, 0.72, 0.62, 0.52, 0.42, 0.32]
        var smallestData: Data?

        for maxDimension in maxDimensions {
            let resizedImage = resizedImageForOCR(image, maxDimension: maxDimension)

            for quality in compressionQualities {
                guard let data = resizedImage.jpegData(compressionQuality: quality) else { continue }

                if let currentSmallest = smallestData {
                    if data.count < currentSmallest.count {
                        smallestData = data
                    }
                } else {
                    smallestData = data
                }

                if data.count <= maxBytes {
                    return data
                }
            }
        }

        return smallestData
    }

    private func resizedImageForOCR(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let sourceSize = image.size
        let longestSide = max(sourceSize.width, sourceSize.height)
        guard longestSide > maxDimension, longestSide > 0 else { return image }

        let scale = maxDimension / longestSide
        let targetSize = CGSize(
            width: max(1, sourceSize.width * scale),
            height: max(1, sourceSize.height * scale)
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showingError = true
    }

    func logError(_ error: Error, context: String) {
        logger.error("context=\(context, privacy: .public) error=\(String(describing: error), privacy: .public)")
    }

    func chatFailureMessage(for error: Error) -> String {
        normalizedError(error, fallbackMessage: "I hit a temporary issue. Please try again.").userMessage
    }

    private func reportUserSafeError(_ error: Error, context: String, userMessage: String) {
        let normalized = normalizedError(error, fallbackMessage: userMessage)
        logger.error(
            "context=\(context, privacy: .public) code=\(normalized.code, privacy: .public) status=\(normalized.statusCode ?? -1) retryable=\(normalized.retryable) error=\(String(describing: error), privacy: .public)"
        )
        presentError(normalized.userMessage)
    }

    private func normalizedError(_ error: Error, fallbackMessage: String) -> AppServiceError {
        if let mnexiumError = error as? MnexiumClientError {
            switch mnexiumError {
            case .invalidInput:
                return AppServiceError(
                    code: "mnexium_invalid_input",
                    statusCode: nil,
                    retryable: false,
                    userMessage: "Please check the input and try again."
                )
            case .invalidResponse:
                return AppServiceError(
                    code: "mnexium_invalid_response",
                    statusCode: nil,
                    retryable: true,
                    userMessage: "Mnexium returned an invalid response. Please try again."
                )
            case .httpStatus(let status, _):
                let retryable = status == 429 || (500...599).contains(status)
                let userMessage: String
                if retryable {
                    userMessage = "Mnexium is temporarily unavailable. Please try again."
                } else if status == 401 || status == 403 {
                    userMessage = "Authentication to Mnexium failed. Please reconnect and try again."
                } else {
                    userMessage = fallbackMessage
                }
                return AppServiceError(
                    code: "mnexium_http_\(status)",
                    statusCode: status,
                    retryable: retryable,
                    userMessage: userMessage
                )
            case .transport:
                return AppServiceError(
                    code: "mnexium_transport",
                    statusCode: nil,
                    retryable: true,
                    userMessage: "Network issue while contacting Mnexium. Please try again."
                )
            case .parse:
                return AppServiceError(
                    code: "mnexium_parse",
                    statusCode: nil,
                    retryable: false,
                    userMessage: fallbackMessage
                )
            }
        }

        return AppServiceError(
            code: "unknown",
            statusCode: nil,
            retryable: false,
            userMessage: fallbackMessage
        )
    }

    private func configureClientFromCustomKeysIfPresent() -> Bool {
        let normalizedMnexium = customMnexiumAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMnexium.isEmpty,
              let configuration = MnexiumConfiguration.fromRemoteKeys(
                mnexiumApiKey: normalizedMnexium,
                openAIKey: customOpenAIAPIKey
              ) else {
            return false
        }

        mnexiumClient = MnexiumClient(configuration: configuration)
        return true
    }
}
