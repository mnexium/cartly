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
        if let stored = defaults.string(forKey: Keys.chatID),
           let normalizedStoredUUID = normalizedUUIDString(from: stored) {
            chatID = normalizedStoredUUID
            if stored != normalizedStoredUUID {
                defaults.set(normalizedStoredUUID, forKey: Keys.chatID)
            }
        } else {
            let newValue = UUID().uuidString.lowercased()
            defaults.set(newValue, forKey: Keys.chatID)
            chatID = newValue
        }

        return MnexiumIdentity(subjectID: subjectID, chatID: chatID)
    }

    func setChatID(_ chatID: String) {
        guard let normalized = normalizedUUIDString(from: chatID) else { return }
        defaults.set(normalized, forKey: Keys.chatID)
    }

    func startNewChatID() -> String {
        let newValue = UUID().uuidString.lowercased()
        defaults.set(newValue, forKey: Keys.chatID)
        return newValue
    }

    private func normalizedUUIDString(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmed) else { return nil }
        return uuid.uuidString.lowercased()
    }
}
