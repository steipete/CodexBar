import Foundation

extension ProviderConfig {
    public var antigravityAdditionalProfileHomes: [String]? {
        get { self.extensionValue(forKey: "antigravityAdditionalProfileHomes") }
        set { self.setExtensionValue(newValue, forKey: "antigravityAdditionalProfileHomes") }
    }

    public var antigravityPrioritizeExhaustedQuotas: Bool? {
        get { self.extensionValue(forKey: "antigravityPrioritizeExhaustedQuotas") }
        set { self.setExtensionValue(newValue, forKey: "antigravityPrioritizeExhaustedQuotas") }
    }

    public var antigravityPrimaryPoolPreference: String? {
        get { self.extensionValue(forKey: "antigravityPrimaryPoolPreference") }
        set { self.setExtensionValue(newValue, forKey: "antigravityPrimaryPoolPreference") }
    }

    public var resolvedAntigravityPrimaryPoolPreference: AntigravityPrimaryPoolPreference {
        self.antigravityPrimaryPoolPreference.flatMap(AntigravityPrimaryPoolPreference.init(rawValue:)) ?? .auto
    }

    public var antigravityShowCredits: Bool? {
        get { self.extensionValue(forKey: "antigravityShowCredits") }
        set { self.setExtensionValue(newValue, forKey: "antigravityShowCredits") }
    }

    public var antigravityScanDesktopEnabled: Bool? {
        get { self.extensionValue(forKey: "antigravityScanDesktopEnabled") }
        set { self.setExtensionValue(newValue, forKey: "antigravityScanDesktopEnabled") }
    }

    public var antigravityScanCLIEnabled: Bool? {
        get { self.extensionValue(forKey: "antigravityScanCLIEnabled") }
        set { self.setExtensionValue(newValue, forKey: "antigravityScanCLIEnabled") }
    }

    public var antigravityTokscaleFallbackEnabled: Bool? {
        get { self.extensionValue(forKey: "antigravityTokscaleFallbackEnabled") }
        set { self.setExtensionValue(newValue, forKey: "antigravityTokscaleFallbackEnabled") }
    }

    public var antigravityProjectGrouping: String? {
        get { self.extensionValue(forKey: "antigravityProjectGrouping") }
        set { self.setExtensionValue(newValue, forKey: "antigravityProjectGrouping") }
    }

    public var resolvedAntigravityProjectGrouping: AntigravityProjectGrouping {
        self.antigravityProjectGrouping.flatMap(AntigravityProjectGrouping.init(rawValue:)) ?? .workspace
    }

    public var resolvedAntigravityScanOptions: AntigravityLocalScanOptions {
        AntigravityLocalScanOptions(
            includeDesktopDatabases: self.antigravityScanDesktopEnabled ?? true,
            includeCLIDatabases: self.antigravityScanCLIEnabled ?? true,
            includeTokscaleFallback: self.antigravityTokscaleFallbackEnabled ?? true,
            projectGrouping: self.resolvedAntigravityProjectGrouping)
    }
}
