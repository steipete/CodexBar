#if os(macOS)
import SweetCookieKit
#else
public struct Browser: Sendable, Hashable {
    public init() {}
}

#endif

public typealias BrowserCookieImportOrder = [Browser]

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
                #if os(macOS)
                if KeychainAccessGate.isExplicitlyDisabled {
                    BrowserCookieAccessGate.recordAccessFailure(for: browser)
                }
                #endif
                return false
            }
            let available = detection.isCookieSourceAvailable(browser)
            #if os(macOS)
            if !available, detection.cookieSourceProfileAccessIssue(browser) == .accessDenied {
                BrowserCookieAccessGate.recordAccessFailure(for: browser, profileDenied: true)
            }
            #endif
            return available && BrowserCookieAccessGate.shouldAttempt(browser)
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
        self != .safari && !self.usesGeckoProfileStore
    }
}
#else
extension Browser {
    var usesKeychainForCookieDecryption: Bool {
        false
    }
}
#endif
