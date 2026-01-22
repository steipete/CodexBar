import CodexBarCore
import Foundation

enum CLIErrorKind: String, Encodable {
    case args
    case config
    case provider
    case runtime
}

struct ProviderErrorPayload: Encodable {
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

    static func makeCLIErrorPayload(
        message: String,
        code: ExitCode,
        kind: CLIErrorKind,
        pretty: Bool) -> String?
    {
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
            error: ProviderErrorPayload(code: code.rawValue, message: message, kind: kind))
        return self.encodeJSON([payload], pretty: pretty)
    }

    static func makeProviderErrorPayload(
        provider: UsageProvider,
        account: String?,
        source: String,
        status: ProviderStatusPayload?,
        error: Error,
        kind: CLIErrorKind = .provider) -> ProviderPayload
    {
        ProviderPayload(
            provider: provider,
            account: account,
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

    static func exit(
        code: ExitCode,
        message: String? = nil,
        output: CLIOutputPreferences? = nil,
        kind: CLIErrorKind = .runtime) -> Never
    {
        if code != .success {
            if let output, output.usesJSONOutput {
                let payload = self.makeCLIErrorPayload(
                    message: message ?? "Error",
                    code: code,
                    kind: kind,
                    pretty: output.pretty)
                if let payload {
                    print(payload)
                }
            } else if let message {
                self.writeStderr("\(message)\n")
            }
        }
        platformExit(code.rawValue)
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
            self.printJSON([payload], pretty: output.pretty)
        } else {
            self.writeStderr("Error: \(error.localizedDescription)\n")
        }
    }
}
