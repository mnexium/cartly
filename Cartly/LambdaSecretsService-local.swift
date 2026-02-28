/**
iOS does not provide a secure way to store API keys in the application build.
A lambda function is used to provide the API Keys.
 
The endpoint is the string below
 endpointString: String = ""
 
 
 
 */
//import Foundation
//
//struct AppSecrets: Codable {
//    let mnexiumApiKey: String
//    let openaiApiKey: String
//}
//
//enum LambdaSecretsError: LocalizedError {
//    case invalidEndpoint
//    case invalidPayload
//    case missingMnexiumKey
//
//    var errorDescription: String? {
//        switch self {
//        case .invalidEndpoint:
//            return "The secrets endpoint URL is invalid."
//        case .invalidPayload:
//            return "Could not decode the secrets response."
//        case .missingMnexiumKey:
//            return "The secrets response did not include a Mnexium API key."
//        }
//    }
//}
//
//final class LambdaSecretsService {
//    private let endpoint: URL
//    private let urlSession: URLSession
//    private var inMemorySecrets: AppSecrets?
//
//    init(
//        endpointString: String = "",
//        urlSession: URLSession = .shared
//    ) throws {
//        guard let endpoint = URL(string: endpointString) else {
//            throw LambdaSecretsError.invalidEndpoint
//        }
//
//        self.endpoint = endpoint
//        self.urlSession = urlSession
//    }
//
//    func cachedSecrets() -> AppSecrets? {
//        inMemorySecrets
//    }
//
//    func fetchAndCacheSecrets() async throws -> AppSecrets {
//        var request = URLRequest(url: endpoint)
//        request.httpMethod = "GET"
//        request.timeoutInterval = 15
//
//        let (data, response) = try await urlSession.data(for: request)
//
//        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
//            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
//            throw MnexiumClientError.httpStatus(http.statusCode, body)
//        }
//
//        let decodedSecrets = try decodeSecrets(from: data)
//
//        guard !decodedSecrets.mnexiumApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
//            throw LambdaSecretsError.missingMnexiumKey
//        }
//
//        inMemorySecrets = decodedSecrets
//
//        return decodedSecrets
//    }
//
//    private func decodeSecrets(from data: Data) throws -> AppSecrets {
//        let decoder = JSONDecoder()
//
//        if let secrets = try? decoder.decode(AppSecrets.self, from: data) {
//            return secrets
//        }
//
//        let wrapped = try decoder.decode(LambdaFunctionEnvelope.self, from: data)
//        guard let payloadData = wrapped.body.data(using: .utf8),
//              let secrets = try? decoder.decode(AppSecrets.self, from: payloadData) else {
//            throw LambdaSecretsError.invalidPayload
//        }
//
//        return secrets
//    }
//}
//
//private struct LambdaFunctionEnvelope: Decodable {
//    let body: String
//}
