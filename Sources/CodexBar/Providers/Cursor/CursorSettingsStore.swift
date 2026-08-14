import CodexBarCore
import Foundation

enum CursorUsageDataSource: String, CaseIterable, Identifiable, Sendable {
    case auto
    case app
    case web

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .auto: "Auto"
        case .app: "Cursor App Token"
        case .web: "Browser Cookies"
        }
    }
}

extension SettingsStore {
    var cursorCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .cursor)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .cursor) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .cursor, field: "cookieHeader", value: newValue)
        }
    }

    var cursorCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .cursor, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .cursor) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .cursor, field: "cookieSource", value: newValue.rawValue)
        }
    }

    var cursorUsageDataSource: CursorUsageDataSource {
        get {
            switch self.configSnapshot.providerConfig(for: .cursor)?.source {
            case .oauth: .app
            case .web, .cli: .web
            default: .auto
            }
        }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .app: .oauth
            case .web: .web
            }
            self.updateProviderConfig(provider: .cursor) { entry in
                entry.source = source
            }
            self.logProviderModeChange(provider: .cursor, field: "usageSource", value: newValue.rawValue)
        }
    }

    func ensureCursorCookieLoaded() {}
}

extension SettingsStore {
    func cursorSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .CursorProviderSettings {
        self.resolvedCookieSettings(
            provider: .cursor,
            configuredSource: self.cursorCookieSource,
            configuredHeader: self.cursorCookieHeader,
            tokenOverride: tokenOverride)
    }
}
