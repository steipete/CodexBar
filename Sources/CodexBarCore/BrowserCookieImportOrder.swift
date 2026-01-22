#if os(macOS)
import SweetCookieKit

public typealias BrowserCookieImportOrder = [Browser]
#else
public struct Browser: Sendable, Hashable {
    public init() {}
}

public typealias BrowserCookieImportOrder = [Browser]
#endif

extension [Browser] {
    /// Filters a browser list to sources worth attempting for cookie imports.
    ///
    /// This is intentionally stricter than "app installed": it aims to avoid unnecessary Keychain prompts.
    public func cookieImportCandidates(using detection: BrowserDetection) -> [Browser] {
        guard !KeychainAccessGate.isDisabled else { return [] }
        let candidates = self.filter { detection.isCookieSourceAvailable($0) }
        return candidates.filter { BrowserCookieAccessGate.shouldAttempt($0) }
    }

    public func browsersWithProfileData(using detection: BrowserDetection) -> [Browser] {
        self.filter { detection.hasUsableProfileData($0) }
    }

    public static var safariChromeFirefox: [Browser] {
        #if os(macOS)
        return [.safari, .chrome, .firefox]
        #else
        return []
        #endif
    }
}

#if os(macOS)
extension Browser {
    var usesKeychainForCookieDecryption: Bool {
        switch self {
        case .safari, .firefox, .zen:
            return false
        case .chrome, .chromeBeta, .chromeCanary,
             .arc, .arcBeta, .arcCanary,
             .chatgptAtlas,
             .chromium,
             .brave, .braveBeta, .braveNightly,
             .edge, .edgeBeta, .edgeCanary,
             .helium,
             .vivaldi,
             .dia:
            return true
        @unknown default:
            return true
        }
    }
}
#else
extension Browser {
    var usesKeychainForCookieDecryption: Bool { false }
}
#endif
