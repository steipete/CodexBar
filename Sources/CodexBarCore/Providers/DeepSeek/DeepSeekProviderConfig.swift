import Foundation

extension ProviderConfig {
    public var deepseekProfileID: String? {
        get { self.extensionValue(forKey: "deepseekProfileID") }
        set { self.setExtensionValue(newValue, forKey: "deepseekProfileID") }
    }

    public var deepseekProfileScope: String? {
        get { self.extensionValue(forKey: "deepseekProfileScope") }
        set { self.setExtensionValue(newValue, forKey: "deepseekProfileScope") }
    }

    public var sanitizedDeepSeekProfileID: String? {
        SettingsValue.cleaned(self.deepseekProfileID).map(DeepSeekSettingsReader.canonicalProfileID)
    }

    public var sanitizedDeepSeekProfileScope: String? {
        SettingsValue.cleaned(self.deepseekProfileScope)
    }
}
