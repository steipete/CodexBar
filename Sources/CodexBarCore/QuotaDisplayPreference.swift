import Foundation

public enum QuotaDisplayPreference {
    public static let key = "usageBarsShowUsed"

    public static func showUsed(in defaults: UserDefaults, defaultValue: Bool) -> Bool {
        defaults.object(forKey: self.key) as? Bool ?? defaultValue
    }
}
