import Dispatch
import Foundation

#if os(macOS)
import Security

enum ClaudeOAuthKeychainQueryTiming {
    static func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?, durationMs: Double) {
        var result: AnyObject?
        let startedAtNs = DispatchTime.now().uptimeNanoseconds
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startedAtNs) / 1_000_000.0
        return (status, result, durationMs)
    }

    static func backoffIfSlowNoUIQuery(_ durationMs: Double, _ service: String, _ log: CodexBarLogger) -> Bool {
        // Intentionally no longer treats "slow" no-UI Keychain queries as a denial. Some systems can have
        // non-deterministic timing characteristics that would make this backoff too aggressive and surprising.
        //
        // Keep this hook so call sites can cheaply log slow queries during debugging without changing behavior.
        guard ProviderInteractionContext.current == .background, durationMs > 1000 else { return false }
        log.debug(
            "Claude keychain no-UI query was slow",
            metadata: [
                "service": service,
                "duration_ms": String(format: "%.2f", durationMs),
            ])
        return false
    }
}
#endif
