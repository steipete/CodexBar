import Foundation

protocol ClaudeOAuthPendingCacheClearStore: Sendable {
    var isPending: Bool { get }

    func setPending(_ pending: Bool)
}

final class ClaudeOAuthPendingCacheClearUserDefaultsStore: ClaudeOAuthPendingCacheClearStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key: String

    init(userDefaults: UserDefaults, key: String) {
        self.userDefaults = userDefaults
        self.key = key
    }

    var isPending: Bool {
        self.userDefaults.bool(forKey: self.key)
    }

    func setPending(_ pending: Bool) {
        if pending {
            self.userDefaults.set(true, forKey: self.key)
        } else {
            self.userDefaults.removeObject(forKey: self.key)
        }
    }
}
