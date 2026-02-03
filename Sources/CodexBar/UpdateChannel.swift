import Foundation

enum UpdateChannel: String, CaseIterable, Codable, Sendable {
    case stable
    case beta

    static let userDefaultsKey = "updateChannel"
    static let sparkleBetaChannel = "beta"

    var displayName: String {
        switch self {
        case .stable:
            "Stable"
        case .beta:
            "Beta"
        }
    }

    var description: String {
        switch self {
        case .stable:
            "Receive only stable, production-ready releases."
        case .beta:
            "Receive stable releases plus beta previews."
        }
    }

    var allowedSparkleChannels: Set<String> {
        switch self {
        case .stable:
            [""]
        case .beta:
            ["", UpdateChannel.sparkleBetaChannel]
        }
    }

    static var current: Self {
        if let rawValue = UserDefaults.standard.string(forKey: userDefaultsKey),
           let channel = Self(rawValue: rawValue)
        {
            return channel
        }
        return defaultChannel
    }

    static var defaultChannel: Self {
        defaultChannel(for: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
    }

    static func defaultChannel(for appVersion: String) -> Self {
        if let isPrereleaseValue = Bundle.main.object(forInfoDictionaryKey: "IS_PRERELEASE_BUILD"),
           let isPrerelease = isPrereleaseValue as? Bool,
           isPrerelease
        {
            return .beta
        }

        let prereleaseKeywords = ["beta", "alpha", "rc", "pre", "dev"]
        let lowercaseVersion = appVersion.lowercased()

        for keyword in prereleaseKeywords where lowercaseVersion.contains(keyword) {
            return .beta
        }

        return .stable
    }
}

extension UpdateChannel: Identifiable {
    var id: String {
        rawValue
    }
}
