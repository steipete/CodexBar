import CodexBarCore
import Foundation
import XCTest
@testable import CodexBar

@MainActor
final class AugmentProviderRuntimeTests: XCTestCase {
    func test_disabledStopDoesNotLogWithoutKeepalive() throws {
        CodexBarLog.bootstrapIfNeeded(.init(destination: .discard, level: .info, json: false))
        CodexBarLog.setLogLevel(.info)

        let suite = "AugmentProviderRuntimeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore())
        if let metadata = ProviderRegistry.shared.metadata[.augment] {
            settings.setProviderEnabled(provider: .augment, metadata: metadata, enabled: false)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        CodexBarLog.setFileLoggingEnabled(true)
        defer { CodexBarLog.setFileLoggingEnabled(false) }

        let logURL = CodexBarLog.fileLogURL
        let beforeMarker = "Augment stop idempotency before \(UUID().uuidString)"
        let afterMarker = "Augment stop idempotency after \(UUID().uuidString)"

        let runtime = AugmentProviderRuntime()
        let context = ProviderRuntimeContext(provider: .augment, settings: settings, store: store)

        store.augmentLogger.info(beforeMarker)
        _ = try Self.waitForLogContaining(beforeMarker, at: logURL)

        runtime.stop(context: context)
        runtime.stop(context: context)
        runtime.settingsDidChange(context: context)

        store.augmentLogger.info(afterMarker)
        let log = try Self.waitForLogContaining(afterMarker, at: logURL)
        let stopLogSlice = Self.logSlice(log, between: beforeMarker, and: afterMarker)

        XCTAssertFalse(
            stopLogSlice.contains("Augment keepalive stopped"),
            "Disabled stop calls should not emit stopped logs when no keepalive exists:\n\(stopLogSlice)")
    }

    private static func waitForLogContaining(
        _ marker: String,
        at url: URL,
        timeout: TimeInterval = 2) throws -> String
    {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = ""
        repeat {
            latest = try Self.readLog(at: url)
            if latest.contains(marker) {
                return latest
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        } while Date() < deadline

        XCTFail("Timed out waiting for log marker: \(marker)")
        return latest
    }

    private static func readLog(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        let data = try Data(contentsOf: url)
        return String(decoding: data, as: UTF8.self)
    }

    private static func logSlice(_ log: String, between beforeMarker: String, and afterMarker: String) -> String {
        guard let beforeRange = log.range(of: beforeMarker, options: .backwards),
              let afterRange = log.range(of: afterMarker, options: .backwards),
              beforeRange.upperBound <= afterRange.lowerBound else {
            return log
        }
        return String(log[beforeRange.upperBound..<afterRange.lowerBound])
    }
}
