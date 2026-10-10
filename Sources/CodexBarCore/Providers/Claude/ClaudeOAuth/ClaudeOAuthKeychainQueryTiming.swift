import Dispatch
import Foundation

#if os(macOS)
import Security

enum ClaudeOAuthKeychainQueryTiming {
    #if DEBUG
    @TaskLocal static var copyMatchingOverride: (@Sendable ([String: Any]) -> (OSStatus, AnyObject?, Double))?
    #endif

    static func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?, durationMs: Double) {
        #if DEBUG
        if let copyMatchingOverride { return copyMatchingOverride(query) }
        #endif
        var result: AnyObject?
        let startedAtNs = DispatchTime.now().uptimeNanoseconds
        let status = KeychainSecurity.copyMatching(query as CFDictionary, &result)
        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startedAtNs) / 1_000_000.0
        return (status, result, durationMs)
    }

    static func logSlowNoUIQuery(_ durationMs: Double, _ service: String, _ log: CodexBarLogger) {
        // Intentionally no longer treats "slow" no-UI Keychain queries as a denial. Some systems can have
        // non-deterministic timing characteristics that would make this backoff too aggressive and surprising.
        guard ProviderInteractionContext.current == .background, durationMs > 1000 else { return }
        log.debug(
            "Claude keychain no-UI query was slow",
            metadata: [
                "service": service,
                "duration_ms": String(format: "%.2f", durationMs),
            ])
    }
}
#endif
