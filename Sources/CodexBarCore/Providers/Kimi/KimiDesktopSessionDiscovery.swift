import CoreFoundation
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(macOS) && CODEXBAR_KIMI_DESKTOP_CANDIDATE
import SweetCookieKit
#endif

/// Bounded native candidate seam, installed only in explicit paired-checkout development builds.
/// The caller supplies host-owned settings/home, never a plugin-supplied path, origin, or key.
struct KimiDesktopSessionDiscovery: Sendable {
    typealias CurrentValueReader = @Sendable (URL, Data) -> Data?

    private let readCurrentValue: CurrentValueReader
    static let origin = "https://www.kimi.com"
    static let rawKey = Data("_\(Self.origin)\0".utf8) + Data([1]) + Data("access_token".utf8)

    init(readCurrentValue: @escaping CurrentValueReader) {
        self.readCurrentValue = readCurrentValue
    }

    static func resolveNativeCandidate(
        region: KimiRegion,
        currentSession: () -> String?,
        legacyCookie: () -> String?) -> String?
    {
        // Never recover a historical China Desktop cookie after logout or an incomplete strict read.
        // International retains its existing cookie path; it gets no new Local Storage access.
        region == .china ? currentSession() : legacyCookie()
    }

    func accessToken(settings: KimiProviderSettings, homeDirectory: URL, now: Date = Date()) -> String? {
        // International Desktop has not been observed. Manual/Off must not even inspect the profile.
        guard settings.cookieSource == .auto, settings.region == .china, !Task.isCancelled else { return nil }
        guard let home = Self.physicalHome(homeDirectory) else { return nil }
        let directory = home.appendingPathComponent("Library/Application Support/kimi-desktop/Local Storage/leveldb")
        // Only the host-owned home is canonicalized. The strict reader must reject symlinks below it.
        guard let value = self.readCurrentValue(directory, Self.rawKey), !Task.isCancelled
        else { return nil }
        return Self.accessToken(rawValue: value, now: now)
    }

    func credential(
        settings: KimiProviderSettings,
        homeDirectory: URL,
        now: @escaping @Sendable () -> Date = { Date() }) -> KimiWebCredential?
    {
        guard let token = self.accessToken(settings: settings, homeDirectory: homeDirectory, now: now())
        else { return nil }
        return KimiWebCredential(desktopToken: token) {
            self.accessToken(settings: settings, homeDirectory: homeDirectory, now: now()) == token
        }
    }

    private static func physicalHome(_ directory: URL) -> URL? {
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              let physical = realpath(directory.path, nil) else { return nil }
        defer { free(physical) }
        return URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    }

    static func accessToken(rawValue: Data, now: Date) -> String? {
        // Kimi 3.2.15's observed value is a Chromium Latin-1 string, not a JSON wrapper.
        guard rawValue.first == 1, rawValue.count <= 16385,
              let token = String(data: rawValue.dropFirst(), encoding: .ascii), !token.isEmpty,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
        else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }),
              let header = Self.object(parts[0]), let algorithm = header["alg"] as? String,
              !algorithm.isEmpty, algorithm.lowercased() != "none",
              let claims = Self.object(parts[1]), claims["typ"] as? String == "access",
              let expiry = Self.numericDate(claims["exp"]), now.timeIntervalSince1970.isFinite,
              expiry > now.timeIntervalSince1970
        else { return nil }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains("kimi.com") else { return nil }
        if let notBefore = claims["nbf"] {
            guard let start = Self.numericDate(notBefore), start <= now.timeIntervalSince1970 else { return nil }
        }
        // Only structural and claim checks: the service still authenticates the signature.
        return token
    }

    private static func object(_ component: Substring) -> [String: Any]? {
        var encoded = component.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private static func numericDate(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let date = number.doubleValue
        return date.isFinite ? date : nil
    }

    #if os(macOS) && CODEXBAR_KIMI_DESKTOP_CANDIDATE
    /// Requires the proposed strict raw-key SweetCookieKit API in a paired-checkout development build.
    /// Keep behind an explicit development build flag until dependency and credential scope are approved.
    static let candidate = Self { directory, key in
        ChromiumLocalStorageReader.readCurrentValue(forRawKey: key, in: directory)
    }
    #endif
}
