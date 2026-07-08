import Foundation
import Security

/// Persists the set of paired Macs (device ID + shared key) in the iOS Keychain — the keys are
/// secrets, so they must not sit in UserDefaults. Shared across the app + extensions via a Keychain
/// access group is possible later; for now the app owns it and the widget reads the last snapshot
/// from the App Group cache (it never needs the keys).
public enum PairingStore {
    private static let service = "com.steipete.codexbar.ios.pairing"
    private static let account = "paired-macs"

    private static let fallbackKey = "pairing.macs.fallback"

    public static func load() -> [PairedMac] {
        var query = self.baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let macs = try? JSONDecoder().decode([PairedMac].self, from: data)
        {
            return macs
        }
        // Fallback for builds where the Keychain is unavailable (unsigned simulator builds).
        if let data = self.fallbackDefaults?.data(forKey: self.fallbackKey),
           let macs = try? JSONDecoder().decode([PairedMac].self, from: data)
        {
            return macs
        }
        return []
    }

    @discardableResult
    public static func save(_ macs: [PairedMac]) -> Bool {
        guard let data = try? JSONEncoder().encode(macs) else { return false }
        SecItemDelete(self.baseQuery() as CFDictionary)
        var add = self.baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            // Keychain unavailable (e.g. unsigned build) — persist to the App Group so pairing survives.
            self.fallbackDefaults?.set(data, forKey: self.fallbackKey)
        }
        return status == errSecSuccess
    }

    private static var fallbackDefaults: UserDefaults? {
        UserDefaults(suiteName: MobileAppGroup.identifier)
    }

    /// Adds or updates a paired Mac (dedup by deviceID). Returns the full list.
    @discardableResult
    public static func upsert(_ mac: PairedMac) -> [PairedMac] {
        var macs = self.load().filter { $0.deviceID != mac.deviceID }
        macs.append(mac)
        self.save(macs)
        return macs
    }

    @discardableResult
    public static func remove(deviceID: String) -> [PairedMac] {
        let macs = self.load().filter { $0.deviceID != deviceID }
        self.save(macs)
        return macs
    }

    public static func isPaired(deviceID: String) -> Bool {
        self.load().contains { $0.deviceID == deviceID }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
        ]
    }
}
