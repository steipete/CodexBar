import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func runCacheClear(_ values: ParsedValues) {
        let output = CLIOutputPreferences.from(values: values)
        let cookies = values.flags.contains("cookies")
        let cost = values.flags.contains("cost")
        let all = values.flags.contains("all")
        let rawProvider = values.options["provider"]?.last

        let clearCookies = cookies || all
        let clearCost = cost || all

        if !clearCookies, !clearCost {
            Self.exit(
                code: .failure,
                message: "Specify --cookies, --cost, or --all.",
                output: output,
                kind: .args)
        }
        if let error = Self.cacheClearProviderScopeError(rawProvider: rawProvider, clearCost: clearCost) {
            Self.exit(code: .failure, message: error, output: output, kind: .args)
        }

        var results: [CacheClearResult] = []

        if clearCookies {
            if let rawProvider {
                if let provider = ProviderDescriptorRegistry.cliNameMap[rawProvider.lowercased()] {
                    let cleared = CookieHeaderCache.clearAllScopes(provider: provider)
                    results.append(CacheClearResult(
                        cache: "cookies",
                        provider: provider.rawValue,
                        cleared: cleared))
                } else {
                    Self.exit(
                        code: .failure,
                        message: "Unknown provider: \(rawProvider)",
                        output: output,
                        kind: .args)
                }
            } else {
                let cleared = CookieHeaderCache.clearAll()
                results.append(CacheClearResult(cache: "cookies", provider: nil, cleared: cleared))
            }
        }

        if clearCost {
            let fm = FileManager.default
            let cacheDir = Self.costUsageCacheDirectory(fileManager: fm)
            var cleared = 0
            var costError: String?
            if fm.fileExists(atPath: cacheDir.path) {
                do {
                    try fm.removeItem(at: cacheDir)
                    cleared = 1
                } catch {
                    costError = error.localizedDescription
                }
            }
            results.append(CacheClearResult(cache: "cost", provider: nil, cleared: cleared, error: costError))
        }

        switch output.format {
        case .text:
            for result in results {
                let scope = result.provider ?? "all providers"
                if let error = result.error {
                    print("\(result.cache): failed to clear (\(scope)) - \(error)")
                } else if result.cleared > 0 {
                    print("\(result.cache): cleared (\(scope))")
                } else {
                    print("\(result.cache): nothing to clear (\(scope))")
                }
            }
        case .json:
            Self.printJSON(results, pretty: output.pretty)
        }

        let hasErrors = results.contains(where: { $0.error != nil })
        Self.exit(code: hasErrors ? .failure : .success, output: output, kind: .runtime)
    }

    static func cacheClearProviderScopeError(rawProvider: String?, clearCost: Bool) -> String? {
        guard rawProvider != nil, clearCost else { return nil }
        return "--provider only scopes cookie caches. Use --cookies --provider <name>, or omit --provider."
    }
}

struct CacheOptions: CommanderParsable {
    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level (trace|verbose|debug|info|warning|error|critical)")
    var logLevel: String?

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(name: .long("json"), help: "")
    var jsonShortcut: Bool = false

    @Flag(name: .long("json-only"), help: "Emit JSON only (suppress non-JSON output)")
    var jsonOnly: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false

    @Flag(name: .long("cookies"), help: "Clear browser cookie caches")
    var cookies: Bool = false

    @Flag(name: .long("cost"), help: "Clear cost usage caches")
    var cost: Bool = false

    @Flag(name: .long("all"), help: "Clear all caches")
    var all: Bool = false

    @Option(name: .long("provider"), help: "Clear cache for a specific provider only")
    var provider: String?
}

private struct CacheClearResult: Encodable {
    let cache: String
    let provider: String?
    let cleared: Int
    var error: String?
}

extension CodexBarCLI {
    /// Mirrors the cost usage cache directory used by the app (UsageStore.costUsageCacheDirectory).
    static func costUsageCacheDirectory(fileManager: FileManager = .default) -> URL {
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("cost-usage", isDirectory: true)
    }
}
