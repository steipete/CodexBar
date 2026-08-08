import Foundation

extension ProviderConfig {
    /// Account slug (the segment after `/accounts/` in console URLs) that owns `apiKey`.
    /// Fireworks does not expose a whoami endpoint, so the slug cannot be derived from the key.
    public var accountSlug: String? {
        get { self.extensionValue(forKey: "accountSlug") }
        set { self.setExtensionValue(newValue, forKey: "accountSlug") }
    }

    public var sanitizedAccountSlug: String? {
        Self.clean(self.accountSlug)
    }
}
