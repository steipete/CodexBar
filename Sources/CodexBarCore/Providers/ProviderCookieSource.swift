import Foundation

public enum ProviderCookieSource: String, CaseIterable, Identifiable, Sendable, Codable {
    case auto
    case manual
    case off

    public var id: String {
        self.rawValue
    }

    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .manual: "Manual"
        case .off: "Off"
        }
    }

    public var isEnabled: Bool {
        switch self {
        case .off: false
        case .auto, .manual: true
        }
    }
}

extension ProviderCookieSource {
    func pluginAvailability(hasResolver: Bool) -> String {
        guard hasResolver else { return "off" }
        switch self {
        case .auto: return "available"
        case .manual: return "manual"
        case .off: return "off"
        }
    }
}
