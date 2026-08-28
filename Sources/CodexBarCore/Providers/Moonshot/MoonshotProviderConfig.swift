import Foundation

extension ProviderConfig {
    /// Region that owns `apiKey`; keeping it separate prevents credentials from crossing Moonshot hosts.
    public var apiKeyRegion: String? {
        get { self.extensionValue(forKey: "apiKeyRegion") }
        set { self.setExtensionValue(newValue, forKey: "apiKeyRegion") }
    }

    public var sanitizedAPIKeyRegion: String? {
        Self.clean(self.apiKeyRegion)
    }
}
