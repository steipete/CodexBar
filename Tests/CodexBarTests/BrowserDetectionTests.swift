import Foundation
import os.lock
import Testing
@testable import CodexBarCore

#if os(macOS)
import SweetCookieKit

@Suite(.serialized)
struct BrowserDetectionTests {
    @Test(.disabled(
        if: ProcessInfo.processInfo.environment[BrowserCookieAccessGate.allowTestCookieAccessEnvironmentKey] == "1",
        "Default-home cookie access is explicitly enabled for this test run."))
    func `default home detection is suppressed before profile probes`() throws {
        let probeCount = OSAllocatedUnfairLock(initialState: 0)
        let defaultHome = try #require(BrowserCookieClient.defaultHomeDirectories().first)
        let detection = BrowserDetection(
            homeDirectory: defaultHome.path,
            cacheTTL: 0,
            fileExists: { _ in
                probeCount.withLock { $0 += 1 }
                return false
            },
            directoryContents: { _ in
                probeCount.withLock { $0 += 1 }
                return nil
            })

        _ = detection.isCookieSourceAvailable(.chrome)
        #expect(probeCount.withLock { $0 } == 0)
    }

    @Test(.disabled(
        if: ProcessInfo.processInfo.environment[BrowserCookieAccessGate.allowTestCookieAccessEnvironmentKey] == "1",
        "Default-home cookie access is explicitly enabled for this test run."))
    func `default client reports structured suppression before store discovery`() {
        let client = BrowserCookieClient()

        #expect(throws: BrowserCookieStoreAccessSuppressedError.self) {
            _ = try client.codexBarStores(for: .chrome)
        }
        #expect(throws: BrowserCookieStoreAccessSuppressedError.self) {
            _ = try client.codexBarRecords(
                matching: BrowserCookieQuery(domains: ["example.com"]),
                in: .safari)
        }
    }

    @Test
    func `cookie store decision allows production and explicit test opt in`() {
        let defaultHomes = BrowserCookieClient.defaultHomeDirectories()
        let testProcess = "swiftpm-testing-helper"

        #expect(BrowserCookieAccessGate.cookieStoreAccessDecision(
            homeDirectories: defaultHomes,
            processName: testProcess,
            environment: [:]) == .suppressed)
        #expect(BrowserCookieAccessGate.cookieStoreAccessDecision(
            homeDirectories: defaultHomes,
            processName: testProcess,
            environment: [BrowserCookieAccessGate.allowTestCookieAccessEnvironmentKey: "1"]) == .allowed)
        #expect(BrowserCookieAccessGate.cookieStoreAccessDecision(
            homeDirectories: defaultHomes,
            processName: "CodexBar",
            environment: [:]) == .allowed)
    }

    @Test(.disabled(
        if: ProcessInfo.processInfo.environment[BrowserCookieAccessGate.allowTestCookieAccessEnvironmentKey] == "1",
        "Default-home cookie access is explicitly enabled for this test run."))
    func `safari is installed but default cookie access is disabled during tests`() {
        #expect(BrowserDetection(cacheTTL: 0).isAppInstalled(.safari) == true)
        #expect(BrowserDetection(cacheTTL: 0).isCookieSourceAvailable(.safari) == false)
    }

    @Test(.disabled(
        if: ProcessInfo.processInfo.environment[BrowserCookieAccessGate.allowTestCookieAccessEnvironmentKey] == "1",
        "Default-home cookie access is explicitly enabled for this test run."))
    func `default cookie candidates exclude safari during tests`() {
        let detection = BrowserDetection(cacheTTL: 0)
        let browsers: [Browser] = [.safari, .chrome, .firefox]
        #expect(browsers.cookieImportCandidates(using: detection).contains(.safari) == false)
    }

    @Test
    func `explicit isolated home keeps safari cookie source available`() {
        let detection = BrowserDetection(homeDirectory: "/tmp/codexbar-browser-detection", cacheTTL: 0)
        #expect(detection.isCookieSourceAvailable(.safari))
    }

    @Test
    func `cookie client permits isolated chromium stores during tests`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = temp
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Network")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: profile.appendingPathComponent("Cookies").path, contents: Data())
        defer { try? FileManager.default.removeItem(at: temp) }

        let client = BrowserCookieClient(configuration: .init(homeDirectories: [temp]))
        let stores = try KeychainAccessGate.withTaskOverrideForTesting(false) {
            try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in .allowed } operation: {
                try client.codexBarStores(for: .chrome)
            }
        }
        #expect(stores.count == 1)
    }

    @Test
    func `filter preserves order`() {
        BrowserCookieAccessGate.resetForTesting()

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let firefoxProfile = temp
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Firefox")
            .appendingPathComponent("Profiles")
            .appendingPathComponent("abc.default-release")
        try? FileManager.default.createDirectory(at: firefoxProfile, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: firefoxProfile.appendingPathComponent("cookies.sqlite").path,
            contents: Data())

        let detection = BrowserDetection(homeDirectory: temp.path, cacheTTL: 0)
        let browsers: [Browser] = [.firefox, .safari, .chrome]
        // Chrome is filtered out deterministically because it lacks usable on-disk profile/cookie store data.
        #expect(browsers.cookieImportCandidates(using: detection) == [.firefox, .safari])
    }

    @Test
    func `chrome requires profile data`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let detection = BrowserDetection(homeDirectory: temp.path, cacheTTL: 0)
        #expect(detection.isCookieSourceAvailable(.chrome) == false)

        let profile = temp
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Google")
            .appendingPathComponent("Chrome")
            .appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let cookiesDir = profile.appendingPathComponent("Network")
        try FileManager.default.createDirectory(at: cookiesDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cookiesDir.appendingPathComponent("Cookies").path, contents: Data())

        #expect(detection.isCookieSourceAvailable(.chrome) == true)
    }

    @Test
    func `process filters chromium candidates despite false global keychain override`() throws {
        guard ProcessInfo.processInfo.environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1" else { return }
        KeychainAccessGate.resetOverrideForTesting()
        defer { KeychainAccessGate.resetOverrideForTesting() }

        KeychainAccessGate.isDisabled = false

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let profile = temp
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Google")
            .appendingPathComponent("Chrome")
            .appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let cookiesDir = profile.appendingPathComponent("Network")
        try FileManager.default.createDirectory(at: cookiesDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cookiesDir.appendingPathComponent("Cookies").path, contents: Data())

        let detection = BrowserDetection(homeDirectory: temp.path, cacheTTL: 0)
        let browsers: [Browser] = [.chrome, .safari]
        #expect(browsers.cookieImportCandidates(using: detection) == [.safari])
    }

    @Test
    func `keychain interaction suppresses chromium cookie source during cooldown`() {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }

        let start = Date(timeIntervalSince1970: 1000)
        var preflightCount = 0

        KeychainAccessGate.withTaskOverrideForTesting(false) {
            ProviderInteractionContext.$current.withValue(.userInitiated) {
                KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                    preflightCount += 1
                    return .interactionRequired
                } operation: {
                    #expect(BrowserCookieAccessGate.shouldAttempt(.chrome, now: start) == false)
                }

                KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                    preflightCount += 1
                    return .allowed
                } operation: {
                    #expect(BrowserCookieAccessGate.shouldAttempt(.chrome, now: start.addingTimeInterval(60)) == false)
                    #expect(
                        BrowserCookieAccessGate.shouldAttempt(
                            .chrome,
                            now: start.addingTimeInterval((60 * 60 * 6) + 1)) == true)
                }
            }
        }

        #expect(preflightCount == 2)
    }

    @Test
    func `background cookie import allows authorized chromium keychain sources`() {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }

        var preflightCount = 0

        KeychainAccessGate.withTaskOverrideForTesting(false) {
            KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                preflightCount += 1
                return .allowed
            } operation: {
                ProviderInteractionContext.$current.withValue(.background) {
                    #expect(BrowserCookieAccessGate.shouldAttempt(.chrome) == true)
                    #expect(BrowserCookieAccessGate.shouldAttempt(.safari) == true)
                }
            }
        }

        #expect(preflightCount == 1)
    }

    @Test
    func `background cookie import suppresses chromium keychain sources requiring interaction`() {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }

        var preflightCount = 0

        KeychainAccessGate.withTaskOverrideForTesting(false) {
            KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                preflightCount += 1
                return .interactionRequired
            } operation: {
                ProviderInteractionContext.$current.withValue(.background) {
                    #expect(BrowserCookieAccessGate.shouldAttempt(.chrome) == false)
                    #expect(BrowserCookieAccessGate.shouldAttempt(.safari) == true)
                }
            }
        }

        #expect(preflightCount == 1)
    }

    @Test
    func `dia requires profile data`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let detection = BrowserDetection(homeDirectory: temp.path, cacheTTL: 0)
        #expect(detection.isCookieSourceAvailable(.dia) == false)

        let profile = temp
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Dia")
            .appendingPathComponent("User Data")
            .appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let cookiesDir = profile.appendingPathComponent("Network")
        try FileManager.default.createDirectory(at: cookiesDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cookiesDir.appendingPathComponent("Cookies").path, contents: Data())

        #expect(detection.isCookieSourceAvailable(.dia) == true)
    }

    @Test
    func `firefox requires default profile dir`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let profiles = temp
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Firefox")
            .appendingPathComponent("Profiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)

        let detection = BrowserDetection(homeDirectory: temp.path, cacheTTL: 0)
        #expect(detection.isCookieSourceAvailable(.firefox) == false)

        let profile = profiles.appendingPathComponent("abc.default-release")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: profile.appendingPathComponent("cookies.sqlite").path, contents: Data())
        #expect(detection.isCookieSourceAvailable(.firefox) == true)
    }

    @Test
    func `zen accepts uppercase default profile dir`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let profiles = temp
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("zen")
            .appendingPathComponent("Profiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)

        let detection = BrowserDetection(homeDirectory: temp.path, cacheTTL: 0)
        #expect(detection.isCookieSourceAvailable(.zen) == false)

        let profile = profiles.appendingPathComponent("abc.Default (release)")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: profile.appendingPathComponent("cookies.sqlite").path, contents: Data())
        #expect(detection.isCookieSourceAvailable(.zen) == true)
    }
}

#else

struct BrowserDetectionTests {
    @Test
    func `non mac OS returns no browsers`() {
        #expect(BrowserDetection(cacheTTL: 0).isCookieSourceAvailable(Browser()) == false)
    }

    @Test
    func `non mac OS filter returns empty`() {
        let detection = BrowserDetection(cacheTTL: 0)
        let browsers = [Browser(), Browser()]
        #expect(browsers.cookieImportCandidates(using: detection).isEmpty == true)
    }
}

#endif
