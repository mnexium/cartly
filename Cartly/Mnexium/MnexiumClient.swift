import Foundation
import OSLog

@MainActor
final class MnexiumClient {
    let configuration: MnexiumConfiguration
    let urlSession: URLSession
    let logger = Logger(subsystem: "com.marius.Cartly", category: "Mnexium")
    var didEnsureRecordSchemas = false
    let receiptOCRSystemPromptID = "sp_4a80827f-04b1-433f-9aaa-b8d88cdf2636"
    let receiptPersistenceModel = "gpt-4.1-mini"

    init(configuration: MnexiumConfiguration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = urlSession
    }
}
