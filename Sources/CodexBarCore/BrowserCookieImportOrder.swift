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
        Array(self.lazyCookieImportCandidates(using: detection))
    }

    /// Lazily filters browser sources so callers can stop after the first successful cookie import.
    func lazyCookieImportCandidates(using detection: BrowserDetection) -> some Sequence<Browser> {
        self.lazy.filter { browser in
            if KeychainAccessGate.isDisabled, browser.usesKeychainForCookieDecryption {
                return false
            }
            return detection.isCookieSourceAvailable(browser) && BrowserCookieAccessGate.shouldAttempt(browser)
        }
    }

    /// Filters a browser list to sources with usable profile data on disk.
    public func browsersWithProfileData(using detection: BrowserDetection) -> [Browser] {
        self.filter { detection.hasUsableProfileData($0) }
    }
}

#if os(macOS)
extension Browser {
    var usesKeychainForCookieDecryption: Bool {
        switch self {
        case .safari, .firefox, .firefoxBeta, .firefoxDeveloperEdition, .firefoxNightly, .zen:
            return false
        case .chrome, .chromeBeta, .chromeCanary,
             .arc, .arcBeta, .arcCanary,
             .chatgptAtlas,
             .chromium,
             .brave, .braveBeta, .braveNightly,
             .edge, .edgeBeta, .edgeCanary,
             .helium,
             .vivaldi,
             .dia,
             .yandex,
             .comet:
            return true
        @unknown default:
            return true
        }
    }
}
#else
extension Browser {
    var usesKeychainForCookieDecryption: Bool {
        false
    }
}
#endif
