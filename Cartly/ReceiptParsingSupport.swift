import Foundation

struct MnexiumIdentity: Sendable {
    let subjectID: String
    let chatID: String
}

final class MnexiumIdentityStore {
    private enum Keys {
        static let subjectID = "cartly.subject_id"
        static let chatID = "cartly.chat_id"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func currentIdentity() -> MnexiumIdentity {
        let subjectID: String
        if let stored = defaults.string(forKey: Keys.subjectID), !stored.isEmpty {
            subjectID = stored
        } else {
            let newValue = "ios-user-\(UUID().uuidString.lowercased())"
            defaults.set(newValue, forKey: Keys.subjectID)
            subjectID = newValue
        }

        let chatID: String
        if let stored = defaults.string(forKey: Keys.chatID), !stored.isEmpty {
            chatID = stored
        } else {
            let newValue = "cartly-thread-\(UUID().uuidString.lowercased())"
            defaults.set(newValue, forKey: Keys.chatID)
            chatID = newValue
        }

        return MnexiumIdentity(subjectID: subjectID, chatID: chatID)
    }

    func setChatID(_ chatID: String) {
        let normalized = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        defaults.set(normalized, forKey: Keys.chatID)
    }

    func startNewChatID() -> String {
        let newValue = "cartly-thread-\(UUID().uuidString.lowercased())"
        defaults.set(newValue, forKey: Keys.chatID)
        return newValue
    }
}
