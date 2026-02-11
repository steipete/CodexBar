import CodexBarCore
import Foundation

extension SettingsStore {
    var cliproxyapiManagementURL: String {
        get { self.configSnapshot.providerConfig(for: .cliproxyapi)?.sanitizedManagementURL ?? "" }
        set {
            self.updateProviderConfig(provider: .cliproxyapi) { entry in
                entry.managementURL = self.normalizedConfigValue(newValue)
            }
        }
    }

    var cliproxyapiManagementKey: String {
        get { self.configSnapshot.providerConfig(for: .cliproxyapi)?.sanitizedManagementKey ?? "" }
        set {
            self.updateProviderConfig(provider: .cliproxyapi) { entry in
                entry.managementKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .cliproxyapi, field: "managementKey", value: newValue)
        }
    }

    func ensureCLIProxyAPIManagementKeyLoaded() {}
}
