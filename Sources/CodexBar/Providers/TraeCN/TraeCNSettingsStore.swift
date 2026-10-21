import CodexBarCore
import Foundation

extension SettingsStore {
    var traeCNCookieHeader: String {
        get { self[providerConfig: .traecn, field: .cookieHeader] }
        set { self[providerConfig: .traecn, field: .cookieHeader] = newValue }
    }
}
