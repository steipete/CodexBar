import Foundation
#if os(macOS)
import SweetCookieKit
#endif
import Testing
@testable import CodexBarCore

struct DeepSeekPlatformTokenImporterTests {
    @Test
    func `extracts plain user token`() {
        let token = "browser-user-token-1234567890"
        #expect(DeepSeekPlatformTokenImporter._extractUserTokenForTesting(token) == token)
    }

    @Test
    func `extracts JSON encoded user token`() {
        let token = "browser-user-token-abcdefghij"
        let value = "{\"userToken\":\"\(token)\"}"
        #expect(DeepSeekPlatformTokenImporter._extractUserTokenForTesting(value) == token)
    }

    @Test
    func `extracts DeepSeek value wrapped user token`() {
        let token = "browser-user-token-value-wrapped"
        let value = "{\"value\":\"\(token)\",\"expiresAt\":1234567890}"
        #expect(DeepSeekPlatformTokenImporter._extractUserTokenForTesting(value) == token)
    }

    @Test
    func `does not treat an unrecognized JSON object as a token`() {
        #expect(DeepSeekPlatformTokenImporter._extractUserTokenForTesting("{\"expiresAt\":1234567890}") == nil)
    }

    @Test
    func `rejects short or whitespace values`() {
        #expect(DeepSeekPlatformTokenImporter._extractUserTokenForTesting("short") == nil)
        #expect(DeepSeekPlatformTokenImporter._extractUserTokenForTesting("token with embedded spaces 12345") == nil)
    }

    #if os(macOS)
    @Test
    func `discovers a Chromium session without Chrome`() {
        let localStorage = BrowserLocalStorageAPI { _, browsers, _, _ in
            guard browsers.contains(where: { $0.rawValue == "chromium" }) else { return [] }
            return [.init(
                id: "chromium:Default",
                label: "Chromium Default",
                entries: [.init(key: "userToken", value: "synthetic-chromium-platform-token")])]
        }
        let tokens = DeepSeekPlatformTokenImporter.importTokens(
            browserDetection: BrowserDetection(homeDirectory: "/nonexistent/deepseek-test", cacheTTL: 0),
            localStorage: localStorage)
        #expect(tokens.map(\.id) == ["chromium:Default"])
    }

    @Test
    func `imports platform token through browser local storage host API`() {
        let localStorage = BrowserLocalStorageAPI { _, _, _, _ in
            [
                BrowserLocalStorageAPI.Profile(
                    id: "chrome:Profile 2",
                    label: "Chrome — Work",
                    entries: [
                        BrowserLocalStorageAPI.Entry(
                            key: "userToken",
                            value: "browser-user-token-through-host-api"),
                    ]),
            ]
        }

        let tokens = DeepSeekPlatformTokenImporter.importTokens(
            browserDetection: BrowserDetection(cacheTTL: 0),
            localStorage: localStorage)

        #expect(tokens.map(\.id) == ["chrome:Profile 2"])
        #expect(tokens.map(\.sourceLabel) == ["Chrome — Work"])
    }

    @Test
    func `imports Chromium and Helium sessions without Google Chrome installed`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("deepseek-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        for browser in [Browser.chromium, .helium] {
            let root = try #require(ChromiumProfileLocator.roots(for: [browser], homeDirectories: [home]).first)
            try Self.seedUserToken(in: root.url)
        }

        let tokens = DeepSeekPlatformTokenImporter.importTokens(
            browserDetection: BrowserDetection(homeDirectory: home.path, cacheTTL: 0),
            localStorage: Self.storageAPI(home: home))

        #expect(tokens.map(\.id) == ["chromium:Default", "helium:Default"])
        #expect(Set(ChromiumLocalStorageDiscovery.defaultBrowsers)
            .isSuperset(of: [Browser.chrome, .chromium, .helium]))
    }

    @Test
    func `a saved Chrome profile selection still wins after the browser allowlist widens`() async {
        let resolution = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: [
                Self.candidate(id: "chromium:Default", token: "chromium-token"),
                Self.candidate(id: "helium:Default", token: "helium-token"),
                Self.candidate(id: "chrome:Default", token: "chrome-token"),
            ],
            selectedProfileID: "chrome:Default",
            validate: { token in
                Self.summary(marker: token == "chrome-token" ? 3 : 1)
            })

        #expect(resolution.profiles.map(\.id) == ["chrome:Default"])
        #expect(resolution.selectedSummary?.todayTokens == 3)
        #expect(resolution.detailedUsageState == .available)
    }

    @Test
    func `a saved Chrome profile selection does not silently switch to another browser`() async {
        let resolution = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: [
                Self.candidate(id: "chromium:Default", token: "chromium-token"),
                Self.candidate(id: "helium:Default", token: "helium-token"),
            ],
            selectedProfileID: "chrome:Default",
            validate: { _ in Self.summary(marker: 1) })

        #expect(resolution.profiles.map(\.id).sorted() == ["chromium:Default", "helium:Default"])
        #expect(resolution.selectedSummary == nil)
        #expect(resolution.detailedUsageState == .profileSelectionRequired)
    }

    private static let fixtureToken = "synthetic-browser-user-token-1234567890"

    private static func storageAPI(home: URL) -> BrowserLocalStorageAPI {
        BrowserLocalStorageAPI { origin, browsers, detection, logger in
            let installed = browsers.browsersWithProfileData(using: detection)
            return ChromiumProfileLocator.roots(for: installed, homeDirectories: [home]).flatMap { root in
                BrowserLocalStorageAPI.loadProfiles(
                    origin: origin,
                    root: root.url,
                    browserID: root.browser.rawValue,
                    labelPrefix: root.labelPrefix,
                    logger: logger)
            }
        }
    }

    /// Writes a minimal Chromium leveldb log holding only the Platform `userToken` entry.
    private static func seedUserToken(in root: URL) throws {
        let levelDB = root.appendingPathComponent("Default/Local Storage/leveldb")
        try FileManager.default.createDirectory(at: levelDB, withIntermediateDirectories: true)
        let key = Data("_https://platform.deepseek.com\0userToken".utf8)
        var batch = Data(repeating: 0, count: 8)
        batch.append(contentsOf: [1, 0, 0, 0])
        batch.append(1)
        batch.append(UInt8(key.count))
        batch.append(key)
        let encoded = Data([1]) + Data(self.fixtureToken.utf8)
        batch.append(UInt8(encoded.count))
        batch.append(encoded)
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in Data([1]) + batch {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 1 ? 0x82F6_3B78 : 0)
            }
        }
        crc = ~crc
        var masked = (((crc >> 15) | (crc << 17)) &+ 0xA282_EAD8).littleEndian
        var record = Data()
        withUnsafeBytes(of: &masked) { record.append(contentsOf: $0) }
        var length = UInt16(batch.count).littleEndian
        withUnsafeBytes(of: &length) { record.append(contentsOf: $0) }
        record.append(1)
        record.append(batch)
        try record.write(to: levelDB.appendingPathComponent("000003.log"))
    }
    #endif

    @Test
    func `multiple profiles expose only server accepted sessions`() async {
        let candidates = [
            Self.candidate(id: "profile-1", token: "valid-1"),
            Self.candidate(id: "profile-2", token: "expired"),
            Self.candidate(id: "profile-3", token: "valid-3"),
        ]

        let resolution = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: candidates,
            selectedProfileID: nil,
            validate: { token in
                guard token != "expired" else { throw DeepSeekUsageError.invalidPlatformToken }
                return Self.summary(marker: token == "valid-1" ? 1 : 3)
            })

        #expect(resolution.profiles.map(\.id) == ["profile-1", "profile-3"])
        #expect(resolution.selectedSummary == nil)
        #expect(resolution.detailedUsageState == .profileSelectionRequired)
    }

    @Test
    func `single accepted profile is selected automatically`() async {
        let candidates = [
            Self.candidate(id: "profile-1", token: "expired-1"),
            Self.candidate(id: "profile-2", token: "valid-2"),
            Self.candidate(id: "profile-3", token: "expired-3"),
        ]

        let resolution = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: candidates,
            selectedProfileID: nil,
            validate: { token in
                guard token == "valid-2" else { throw DeepSeekUsageError.invalidPlatformToken }
                return Self.summary(marker: 2)
            })

        #expect(resolution.profiles.map(\.id) == ["profile-2"])
        #expect(resolution.selectedSummary?.todayTokens == 2)
        #expect(resolution.detailedUsageState == .available)
    }

    @Test
    func `selected profile preserves its detailed usage state`() async {
        let resolution = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: [Self.candidate(id: "profile-1", token: "valid-1")],
            selectedProfileID: nil,
            detailedUsageState: .notRequested,
            validate: { _ in Self.summary(marker: 1) })

        #expect(resolution.selectedSummary?.todayTokens == 1)
        #expect(resolution.detailedUsageState == .notRequested)
    }

    @Test
    func `explicit selection requirement does not auto select a single accepted profile`() async {
        let resolution = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: [Self.candidate(id: "profile-1", token: "valid-1")],
            selectedProfileID: nil,
            requiresExplicitSelection: true,
            validate: { _ in Self.summary(marker: 1) })

        #expect(resolution.profiles.map(\.id) == ["profile-1"])
        #expect(resolution.selectedSummary == nil)
        #expect(resolution.detailedUsageState == .profileSelectionRequired)
    }

    @Test
    func `stored selection chooses one of multiple accepted profiles`() async {
        let candidates = [
            Self.candidate(id: "profile-1", token: "valid-1"),
            Self.candidate(id: "profile-2", token: "valid-2"),
        ]
        let cache = DeepSeekPlatformValidationCache()
        _ = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: candidates,
            selectedProfileID: nil,
            cache: cache,
            validate: { token in
                Self.summary(marker: token == "valid-1" ? 1 : 2)
            })

        let resolution = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: candidates,
            selectedProfileID: "profile-2",
            cache: cache,
            validate: { token in
                Self.summary(marker: token == "valid-1" ? 1 : 2)
            })

        #expect(resolution.profiles.map(\.id) == ["profile-1", "profile-2"])
        #expect(resolution.selectedSummary?.todayTokens == 2)
        #expect(resolution.detailedUsageState == .available)
    }

    @Test
    func `stored selection does not wait for unrelated profile validation`() async {
        let releaseValidation = HeldRequestGate()
        defer { Task { await releaseValidation.open() } }
        let resolution = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: [
                Self.candidate(id: "profile-1", token: "selected"),
                Self.candidate(id: "profile-2", token: "unselected"),
            ],
            selectedProfileID: "profile-1",
            validate: { token in
                if token == "unselected" {
                    await releaseValidation.wait()
                }
                return Self.summary(marker: token == "selected" ? 1 : 2)
            })

        #expect(await releaseValidation.isOpen == false)
        #expect(resolution.profiles.map(\.id) == ["profile-1"])
        #expect(resolution.selectedSummary?.todayTokens == 1)
        #expect(resolution.detailedUsageState == .available)
    }

    @Test
    func `expired stored selection does not silently switch to another profile`() async {
        let candidates = [
            Self.candidate(id: "profile-1", token: "expired"),
            Self.candidate(id: "profile-2", token: "valid-2"),
        ]

        let resolution = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: candidates,
            selectedProfileID: "profile-1",
            validate: { token in
                guard token == "valid-2" else { throw DeepSeekUsageError.invalidPlatformToken }
                return Self.summary(marker: 2)
            })

        #expect(resolution.profiles.map(\.id) == ["profile-2"])
        #expect(resolution.selectedSummary == nil)
        #expect(resolution.detailedUsageState == .profileSelectionRequired)
    }

    @Test
    func `temporary validation failure is unavailable rather than signed out`() async {
        let resolution = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: [Self.candidate(id: "profile-1", token: "maybe-valid")],
            selectedProfileID: nil,
            validate: { _ in throw DeepSeekUsageError.networkError("offline") })

        #expect(resolution.profiles.isEmpty)
        #expect(resolution.selectedSummary == nil)
        #expect(resolution.detailedUsageState == .unavailable)
    }

    @Test
    func `temporary validation failure keeps a previously accepted profile`() async {
        let candidate = Self.candidate(id: "profile-1", token: "valid-1")
        let cache = DeepSeekPlatformValidationCache(validityTTL: 0)
        _ = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: [candidate],
            selectedProfileID: nil,
            cache: cache,
            validate: { _ in Self.summary(marker: 1) })

        let resolution = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: [candidate],
            selectedProfileID: nil,
            cache: cache,
            validate: { _ in throw DeepSeekUsageError.networkError("offline") })

        #expect(resolution.profiles.map(\.id) == ["profile-1"])
        #expect(resolution.selectedSummary == nil)
        #expect(resolution.detailedUsageState == .unavailable)
    }

    private static func candidate(id: String, token: String) -> DeepSeekPlatformTokenImporter.TokenInfo {
        DeepSeekPlatformTokenImporter.TokenInfo(id: id, token: token, sourceLabel: "Chrome \(id)")
    }

    private static func summary(marker: Int) -> DeepSeekUsageSummary {
        DeepSeekUsageSummary(
            todayTokens: marker,
            currentMonthTokens: marker,
            todayCost: nil,
            currentMonthCost: nil,
            requestCount: marker,
            currentMonthRequestCount: marker,
            topModel: nil,
            categoryBreakdown: [],
            daily: [],
            currency: "USD",
            updatedAt: Date(timeIntervalSince1970: 0))
    }
}
