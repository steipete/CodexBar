import Foundation

enum CodexCLIUserAgent {
    static let originator = "codex_cli_rs"

    static func make(cliVersion: String?) -> String {
        let platform = Self.platformName
        let osVersion = Self.operatingSystemVersionString
        let architecture = Self.architecture
        if let version = Self.normalizedCLIVersion(cliVersion) {
            return "codex_cli_rs/\(version) (\(platform) \(osVersion); \(architecture))"
        }
        return "codex_cli_rs (\(platform) \(osVersion); \(architecture))"
    }

    static func normalizedCLIVersion(_ versionString: String?) -> String? {
        guard let raw = versionString?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else {
            return nil
        }
        let parts = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts.count >= 2, parts[0].caseInsensitiveCompare("codex-cli") == .orderedSame {
            let version = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return version.isEmpty ? nil : version
        }
        let token = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
        return token.isEmpty ? nil : token
    }

    private static var platformName: String {
        #if os(macOS)
        "Mac OS"
        #elseif os(Linux)
        "Linux"
        #else
        "Darwin"
        #endif
    }

    private static var operatingSystemVersionString: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
