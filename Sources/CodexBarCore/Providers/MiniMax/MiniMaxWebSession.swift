import Foundation

enum MiniMaxWebSessionDomain: String, CaseIterable, Hashable, Sendable {
    case global
    case chinaMainland
    case legacyChina

    static func candidates(for region: MiniMaxAPIRegion) -> [Self] {
        region == .chinaMainland ? [.chinaMainland, .legacyChina] : [.global]
    }

    var rootDomain: String {
        switch self {
        case .global: "minimax.io"
        case .chinaMainland: "minimax.cn"
        case .legacyChina: "minimaxi.com"
        }
    }

    var storageOrigins: [String] {
        ["https://platform.\(self.rootDomain)", "https://www.\(self.rootDomain)", "https://\(self.rootDomain)"]
    }

    var cacheScope: CookieHeaderCache.Scope {
        // Old unscoped entries can contain several domains and cannot be safely migrated.
        .providerVariant("minimax.web-session.v1.\(self.rawValue)")
    }

    var quotaURL: URL {
        switch self {
        case .global: MiniMaxAPIRegion.global.remainsURL
        case .chinaMainland: URL(string: "https://www.minimax.cn/backend/account/token_plan/remains_percent")!
        case .legacyChina: MiniMaxAPIRegion.chinaMainland.remainsURL
        }
    }

    func environment(_ environment: [String: String]) -> [String: String] {
        guard environment[MiniMaxSettingsReader.hostKey] == nil,
              environment[MiniMaxSettingsReader.codingPlanURLKey] == nil,
              environment[MiniMaxSettingsReader.remainsURLKey] == nil
        else { return environment }

        var result = environment
        switch self {
        case .global:
            break
        case .chinaMainland:
            result[MiniMaxSettingsReader.codingPlanURLKey] = "https://platform.minimax.cn/console/usage"
            result[MiniMaxSettingsReader.remainsURLKey] =
                "https://www.minimax.cn/backend/account/token_plan/remains_percent"
        case .legacyChina:
            result[MiniMaxSettingsReader.hostKey] = MiniMaxAPIRegion.chinaMainland.baseURLString
        }
        return result
    }
}

struct MiniMaxWebSession: Sendable {
    let cookieHeader: String
    let sourceLabel: String
    let domain: MiniMaxWebSessionDomain

    var groupID: String? {
        MiniMaxCookieHeader.override(from: self.cookieHeader)?.groupID
    }

    var usesTokenCookie: Bool {
        self.domain == .chinaMainland && CookieHeaderNormalizer.pairs(from: self.cookieHeader)
            .contains { $0.name == "_token" && !$0.value.isEmpty }
    }
}
