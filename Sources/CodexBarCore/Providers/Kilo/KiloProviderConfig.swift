import Foundation

extension ProviderConfig {
    public var kiloKnownOrganizations: [KiloOrganization]? {
        get { self.extensionValue(forKey: "kiloKnownOrganizations") }
        set { self.setExtensionValue(newValue, forKey: "kiloKnownOrganizations") }
    }

    public var kiloEnabledOrganizationIDs: [String]? {
        get { self.extensionValue(forKey: "kiloEnabledOrganizationIDs") }
        set { self.setExtensionValue(newValue, forKey: "kiloEnabledOrganizationIDs") }
    }
}
