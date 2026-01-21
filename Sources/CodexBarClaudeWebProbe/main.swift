import CodexBarCore
import Foundation

@main
enum CodexBarClaudeWebProbe {
    private static let defaultEndpoints: [String] = [
        "https://claude.ai/api/organizations",
        "https://claude.ai/api/organizations/{orgId}/usage",
        "https://claude.ai/api/organizations/{orgId}/overage_spend_limit",
        "https://claude.ai/api/organizations/{orgId}/members",
        "https://claude.ai/api/organizations/{orgId}/me",
        "https://claude.ai/api/organizations/{orgId}/billing",
        "https://claude.ai/api/me",
        "https://claude.ai/api/user",
        "https://claude.ai/api/session",
        "https://claude.ai/api/account",
        "https://claude.ai/settings/billing",
        "https://claude.ai/settings/account",
        "https://claude.ai/settings/usage",
    ]

    static func main() async {
        let args = CommandLine.arguments.dropFirst()
        let endpoints = args.isEmpty ? Self.defaultEndpoints : Array(args)
        let includePreview = ProcessInfo.processInfo.environment["CLAUDE_WEB_PROBE_PREVIEW"] == "1"

        do {
            let results = try await ClaudeWebAPIFetcher.probeEndpoints(
                endpoints,
                browserDetection: BrowserDetection(cacheTTL: 0),
                includePreview: includePreview)
            for result in results {
                Self.printResult(result)
            }
        } catch {
            fputs("Probe failed: \(error.localizedDescription)\n", stderr)
            Darwin.exit(1)
        }
    }

    private static func printResult(_ result: ClaudeWebAPIFetcher.ProbeResult) {
        let status = result.statusCode.map(String.init) ?? "error"
        print("==> \(result.url)")
        print("status: \(status)")
        if let contentType = result.contentType { print("content-type: \(contentType)") }
        if !result.topLevelKeys.isEmpty {
            print("keys: \(result.topLevelKeys.joined(separator: ", "))")
        }
        if !result.emails.isEmpty {
            print("emails: \(result.emails.joined(separator: ", "))")
        }
        if !result.planHints.isEmpty {
            print("plan-hints: \(result.planHints.joined(separator: ", "))")
        }
        if !result.notableFields.isEmpty {
            print("fields: \(result.notableFields.joined(separator: ", "))")
        }
        if let preview = result.bodyPreview, !preview.isEmpty {
            print("preview: \(preview)")
        }
        print("")
    }
}
