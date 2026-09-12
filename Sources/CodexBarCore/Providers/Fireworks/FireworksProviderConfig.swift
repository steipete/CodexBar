import Foundation

extension ProviderConfig {
    /// Account slug that owns `apiKey`. When omitted, CodexBar discovers it from the
    /// accounts visible to the Fireworks API key.
    public var accountSlug: String? {
        get { self.extensionValue(forKey: "accountSlug") }
        set { self.setExtensionValue(newValue, forKey: "accountSlug") }
    }

    public var sanitizedAccountSlug: String? {
        Self.clean(self.accountSlug)
    }
}
