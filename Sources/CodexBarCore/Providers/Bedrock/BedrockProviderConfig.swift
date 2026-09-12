import Foundation

extension ProviderConfig {
    public var awsProfile: String? {
        get { self.extensionValue(forKey: "awsProfile") }
        set { self.setExtensionValue(newValue, forKey: "awsProfile") }
    }

    public var awsAuthMode: String? {
        get { self.extensionValue(forKey: "awsAuthMode") }
        set { self.setExtensionValue(newValue, forKey: "awsAuthMode") }
    }

    public var sanitizedAWSProfile: String? {
        SettingsValue.cleaned(self.awsProfile)
    }

    public var sanitizedAWSAuthMode: String? {
        SettingsValue.cleaned(self.awsAuthMode)
    }
}
