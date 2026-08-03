import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

/// Argument validation must not depend on the config file.
///
/// `loadConfig` exits the process on a malformed config, so any command-only
/// validation performed after it can never report its own error. These decoders
/// therefore take no `CodexBarConfig`, which makes the ordering defect structurally
/// impossible rather than merely reordered.
struct CLIHooksWatchArgumentPrecedenceLinuxTests {
    private static func values(
        options: [String: [String]] = [:],
        flags: Set<String> = []) -> ParsedValues
    {
        ParsedValues(positional: [], options: options, flags: flags)
    }

    // MARK: - Interval

    @Test
    func `once mode is rejected because watch state must survive between polls`() {
        let parser = CommandParser(signature: CommandSignature.describe(HooksWatchOptions()))

        do {
            _ = try parser.parse(arguments: ["--once"])
            Issue.record("expected --once to be rejected")
        } catch {
            #expect(String(describing: error).contains("--once"))
        }
    }

    @Test
    func `interval below the floor is rejected without reading config`() {
        let result = CodexBarCLI.decodeHooksWatchInterval(from: Self.values(options: ["interval": ["5"]]))
        guard case let .failure(error) = result else {
            Issue.record("expected failure for an interval below the floor")
            return
        }
        #expect(error.message.contains("at least 60"))
    }

    @Test
    func `non numeric interval is rejected without reading config`() {
        let result = CodexBarCLI.decodeHooksWatchInterval(from: Self.values(options: ["interval": ["abc"]]))
        guard case let .failure(error) = result else {
            Issue.record("expected failure for a non-numeric interval")
            return
        }
        #expect(error.message.contains("Invalid --interval"))
    }

    @Test
    func `interval defaults when absent`() {
        let result = CodexBarCLI.decodeHooksWatchInterval(from: Self.values())
        guard case let .success(interval) = result else {
            Issue.record("expected the default interval")
            return
        }
        #expect(interval == CodexBarCLI.hooksWatchDefaultInterval)
    }

    @Test
    func `interval at the floor is accepted`() {
        let result = CodexBarCLI.decodeHooksWatchInterval(from: Self.values(options: ["interval": ["60"]]))
        guard case let .success(interval) = result else {
            Issue.record("expected the floor value to be accepted")
            return
        }
        #expect(interval == 60)
    }

    // MARK: - Providers

    @Test
    func `unknown provider name is rejected without reading config`() {
        let result = CodexBarCLI.decodeHooksWatchProviderNames(
            from: Self.values(options: ["provider": ["nosuchprovider"]]))
        guard case let .failure(error) = result else {
            Issue.record("expected failure for an unknown provider")
            return
        }
        #expect(error.message.contains("Unknown provider"))
    }

    @Test
    func `absent provider option defers to config`() {
        let result = CodexBarCLI.decodeHooksWatchProviderNames(from: Self.values())
        guard case let .success(providers) = result else {
            Issue.record("expected success when no --provider is given")
            return
        }
        // nil signals "fall back to the configured enabled providers".
        #expect(providers == nil)
    }

    @Test
    func `explicit providers resolve without consulting config`() {
        let result = CodexBarCLI.decodeHooksWatchProviderNames(
            from: Self.values(options: ["provider": ["codex", "codex"]]))
        guard case let .success(providers) = result else {
            Issue.record("expected success for a known provider")
            return
        }
        // Duplicates collapse, and no config was needed to get here.
        #expect(providers == [.codex])
    }

    // MARK: - Resolution against config

    @Test
    func `explicit providers win over the enabled set`() {
        let config = CodexBarConfig.makeDefault()
        let result = CodexBarCLI.hooksWatchProviders(explicit: [.codex], config: config)
        guard case let .success(providers) = result else {
            Issue.record("expected explicit providers to resolve")
            return
        }
        #expect(providers == [.codex])
    }

    @Test
    func `empty enabled set reports no providers`() {
        var config = CodexBarConfig.makeDefault()
        config.providers = config.providers.map { provider in
            var copy = provider
            copy.enabled = false
            return copy
        }
        let result = CodexBarCLI.hooksWatchProviders(explicit: nil, config: config)
        guard case let .failure(error) = result else {
            Issue.record("expected failure when nothing is enabled")
            return
        }
        #expect(error.message.contains("No providers are enabled"))
    }
}
