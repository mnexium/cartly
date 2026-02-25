import Foundation

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
