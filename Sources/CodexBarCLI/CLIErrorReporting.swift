import CodexBarCore
import Foundation

enum CLIErrorKind: String, Encodable, Sendable {
    case args
    case config
    case provider
    case runtime
}

struct ProviderErrorPayload: Encodable, Sendable {
    let code: Int32
    let message: String
    let kind: CLIErrorKind?
}

extension CodexBarCLI {
    static func makeErrorPayload(_ error: Error, kind: CLIErrorKind? = nil) -> ProviderErrorPayload {
        ProviderErrorPayload(
            code: self.mapError(error).rawValue,
            message: error.localizedDescription,
            kind: kind)
    }

    static func makeErrorPayload(code: ExitCode, message: String, kind: CLIErrorKind? = nil) -> ProviderErrorPayload {
        ProviderErrorPayload(code: code.rawValue, message: message, kind: kind)
    }

    static func makeCLIErrorProviderPayload(message: String, code: ExitCode, kind: CLIErrorKind) -> ProviderPayload {
        ProviderPayload(
            providerID: "cli",
            account: nil,
            version: nil,
            source: "cli",
            status: nil,
            usage: nil,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: ProviderErrorPayload(code: code.rawValue, message: message, kind: kind))
    }

    static func makeCLIErrorPayload(
        message: String,
        code: ExitCode,
        kind: CLIErrorKind,
        pretty: Bool) -> String?
    {
        let payload = self.makeCLIErrorProviderPayload(message: message, code: code, kind: kind)
        return self.encodeJSON([payload], pretty: pretty)
    }

    static func makeProviderErrorPayload(
        provider: UsageProvider,
        account: String?,
        cacheAccountKey: String? = nil,
        source: String,
        status: ProviderStatusPayload?,
        error: Error,
        kind: CLIErrorKind = .provider) -> ProviderPayload
    {
        ProviderPayload(
            provider: provider,
            account: account,
            cacheAccountKey: cacheAccountKey,
            version: nil,
            source: source,
            status: status,
            usage: nil,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: self.makeErrorPayload(error, kind: kind))
    }

    static func encodeJSON(_ payload: some Encodable, pretty: Bool) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : []
        guard let data = try? encoder.encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func printJSON(_ payload: some Encodable, pretty: Bool) {
        if let output = self.encodeJSON(payload, pretty: pretty) {
            print(output)
        }
    }

    /// Renders as TOON when the caller requested `usage --format toon`, JSON otherwise. Error/exit
    /// paths must honor this too, or `--format toon` silently falls back to JSON on any early failure
    /// (invalid arguments, config load errors, provider errors).
    static func renderProviderPayloads(_ payloads: [ProviderPayload], output: CLIOutputPreferences) -> String {
        if output.toonRequested {
            return ToonFormatter.encode(payloads)
        }
        return self.encodeJSON(payloads, pretty: output.pretty) ?? ""
    }

    static func printProviderPayloads(_ payloads: [ProviderPayload], output: CLIOutputPreferences) {
        print(self.renderProviderPayloads(payloads, output: output))
    }

    static func exit(
        code: ExitCode,
        message: String? = nil,
        output: CLIOutputPreferences? = nil,
        kind: CLIErrorKind = .runtime) -> Never
    {
        if self.shouldPrintExitError(code: code, message: message) {
            if let output, output.usesJSONOutput {
                self.printProviderPayloads(
                    [self.makeCLIErrorProviderPayload(message: message ?? "", code: code, kind: kind)],
                    output: output)
            } else if let message {
                self.writeStderr("\(message)\n")
            }
        }
        platformExit(code.rawValue)
    }

    static func shouldPrintExitError(code: ExitCode, message: String?) -> Bool {
        code != .success && message != nil
    }

    static func printError(_ error: Error, output: CLIOutputPreferences, kind: CLIErrorKind = .runtime) {
        if output.usesJSONOutput {
            let payload = ProviderPayload(
                providerID: "cli",
                account: nil,
                version: nil,
                source: "cli",
                status: nil,
                usage: nil,
                credits: nil,
                antigravityPlanInfo: nil,
                openaiDashboard: nil,
                error: self.makeErrorPayload(error, kind: kind))
            self.printProviderPayloads([payload], output: output)
        } else {
            self.writeStderr("Error: \(error.localizedDescription)\n")
        }
    }
}
