import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Testing
@testable import CodexBarCore

struct KimiDesktopSessionDiscoveryTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let home: URL = {
        let path = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }()

    @Test(arguments: [ProviderCookieSource.manual, .off], KimiRegion.allCases)
    func `Manual and Off never inspect Desktop storage`(source: ProviderCookieSource, region: KimiRegion) {
        let discovery = KimiDesktopSessionDiscovery { _, _ in
            Issue.record("Disabled discovery must not read")
            return nil
        }
        #expect(discovery.accessToken(
            settings: .init(cookieSource: source, manualCookieHeader: nil, region: region),
            homeDirectory: Self.home,
            now: Self.now) == nil)
    }

    @Test
    func `unobserved International Desktop fails before reading`() {
        let discovery = KimiDesktopSessionDiscovery { _, _ in
            Issue.record("International Desktop has no approved observed scope")
            return nil
        }
        #expect(discovery.accessToken(
            settings: .init(cookieSource: .auto, manualCookieHeader: nil, region: .international),
            homeDirectory: Self.home,
            now: Self.now) == nil)
    }

    @Test
    func `host requests only the observed primary profile and exact raw access key`() throws {
        let token = try Self.token()
        let discovery = KimiDesktopSessionDiscovery { directory, key in
            #expect(directory.path == Self.home.path +
                "/Library/Application Support/kimi-desktop/Local Storage/leveldb")
            #expect(key == Data("_https://www.kimi.com\0".utf8) + Data([1]) + Data("access_token".utf8))
            return Data([1]) + Data(token.utf8)
        }
        #expect(discovery.accessToken(
            settings: .init(cookieSource: .auto, manualCookieHeader: nil),
            homeDirectory: Self.home,
            now: Self.now) == token)
    }

    @Test(arguments: [
        "refresh", "missing-type", "expired", "expiry-boundary", "missing-expiry", "boolean-expiry", "string-expiry",
        "wrong-audience", "lookalike-audience", "url-audience", "missing-audience", "mixed-audience-types",
        "future-not-before", "boolean-not-before", "unsigned", "empty-signature", "malformed", "json-wrapper",
        "quoted-string", "wrong-encoding", "oversized",
    ])
    func `unusable Desktop values are rejected`(kind: String) throws {
        let raw = try Self.invalidValue(kind: kind)
        let discovery = KimiDesktopSessionDiscovery { _, _ in raw }
        #expect(discovery.accessToken(
            settings: .init(cookieSource: .auto, manualCookieHeader: nil),
            homeDirectory: Self.home,
            now: Self.now) == nil)
    }

    @Test
    func `cancelled discovery performs no reads`() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let discovery = KimiDesktopSessionDiscovery { _, _ in
                Issue.record("Cancelled discovery must not read")
                return nil
            }
            return discovery.accessToken(
                settings: .init(cookieSource: .auto, manualCookieHeader: nil),
                homeDirectory: Self.home,
                now: Self.now)
        }
        #expect(await task.value == nil)
    }

    private static func invalidToken(kind: String) throws -> String {
        var claims = Self.claims
        var algorithm = "HS256"
        switch kind {
        case "refresh": claims["typ"] = "refresh"
        case "missing-type": claims.removeValue(forKey: "typ")
        case "expired": claims["exp"] = Self.now.timeIntervalSince1970 - 1
        case "expiry-boundary": claims["exp"] = Self.now.timeIntervalSince1970
        case "missing-expiry": claims.removeValue(forKey: "exp")
        case "boolean-expiry": claims["exp"] = true
        case "string-expiry": claims["exp"] = "1800003600"
        case "wrong-audience": claims["aud"] = "kimi.ai"
        case "lookalike-audience": claims["aud"] = "kimi.com.attacker.invalid"
        case "url-audience": claims["aud"] = "https://www.kimi.com"
        case "missing-audience": claims.removeValue(forKey: "aud")
        case "mixed-audience-types": claims["aud"] = ["kimi.com", 1]
        case "future-not-before": claims["nbf"] = Self.now.timeIntervalSince1970 + 1
        case "boolean-not-before": claims["nbf"] = false
        case "unsigned": algorithm = "none"
        default: break
        }
        return try Self.token(claims: claims, algorithm: algorithm)
    }

    private static func invalidValue(kind: String) throws -> Data {
        let token = try Self.invalidToken(kind: kind)
        return switch kind {
        case "empty-signature": Data([1]) + Data(token.dropLast("fixture-signature".count).utf8)
        case "malformed": Data([1]) + Data("a.b.c".utf8)
        case "json-wrapper": Data([1]) + Data("{\"access_token\":\"\(token)\"}".utf8)
        case "quoted-string": Data([1]) + Data("\"\(token)\"".utf8)
        case "wrong-encoding": Data([0]) + Data(token.utf8)
        case "oversized": Data([1]) + Data(repeating: 65, count: 16385)
        default: Data([1]) + Data(token.utf8)
        }
    }

    private static var claims: [String: Any] {
        ["typ": "access", "aud": "kimi.com", "exp": self.now.timeIntervalSince1970 + 3600]
    }

    private static func token(claims: [String: Any]? = nil, algorithm: String = "HS256") throws -> String {
        func encoded(_ object: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return try encoded([
            "alg": algorithm,
            "typ": "JWT",
        ]) + "." + encoded(claims ?? self.claims) + ".fixture-signature"
    }
}
