import Foundation

public protocol ProviderCookieSettings: Sendable {
    var cookieSource: ProviderCookieSource { get }
    var manualCookieHeader: String? { get }

    init(cookieSource: ProviderCookieSource, manualCookieHeader: String?)
}

public struct CookieProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource = .auto, manualCookieHeader: String? = nil) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

extension ProviderSettingsSnapshot {
    public typealias CookieProviderSettings = CodexBarCore.CookieProviderSettings
}
