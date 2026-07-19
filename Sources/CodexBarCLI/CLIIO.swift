#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

extension CodexBarCLI {
    static func writeStderr(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    static func printVersion() -> Never {
        if let version = currentVersion() {
            print("CodexBar \(version)")
        } else {
            print("CodexBar")
        }
        Self.platformExit(0)
    }

    static func printHelp(for command: String?) -> Never {
        let version = self.currentVersion() ?? "unknown"
        switch command {
        case "cards":
            print(Self.cardsHelp(version: version))
        case "usage":
            print(Self.usageHelp(version: version))
        case "cost":
            print(Self.costHelp(version: version))
        case "sessions", "focus":
            print(Self.sessionsHelp(version: version))
        case "serve":
            print(Self.serveHelp(version: version))
        case "config", "validate", "dump":
            print(Self.configHelp(version: version))
        case "hooks":
            print(Self.hooksHelp(version: version))
        case "cache", "clear":
            print(Self.cacheHelp(version: version))
        case "cookie", "refresh":
            print(Self.cookieHelp(version: version))
        case "diagnose":
            print(Self.diagnoseHelp(version: version))
        case "guard":
            print(Self.guardHelp(version: version))
        default:
            print(Self.rootHelp(version: version))
        }
        Self.platformExit(0)
    }

    static func currentVersion(
        bundle: Bundle = .main,
        executablePath: String? = CommandLine.arguments.first) -> String?
    {
        if let version = self.currentVersion(bundleVersion: nil, executablePath: executablePath) {
            return version
        }
        return self.currentVersion(
            bundleVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
            executablePath: nil)
    }

    static func currentVersion(bundleVersion: String?, executablePath: String?) -> String? {
        if let executablePath, !executablePath.isEmpty {
            let executableURL = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
            if let version = Self.adjacentVersionFileVersion(for: executableURL) {
                return version
            }
            if let version = Self.containingAppVersion(for: executableURL) {
                return version
            }
        }
        return Self.normalizedBundleVersion(bundleVersion)
    }

    static func containingAppVersion(for executableURL: URL) -> String? {
        var currentURL = executableURL.deletingLastPathComponent()
        let fileManager = FileManager.default

        while currentURL.path != currentURL.deletingLastPathComponent().path {
            if currentURL.pathExtension == "app" {
                let infoURL = currentURL
                    .appendingPathComponent("Contents")
                    .appendingPathComponent("Info.plist")
                guard let data = fileManager.contents(atPath: infoURL.path),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { return nil }
                return plist["CFBundleShortVersionString"] as? String
            }
            currentURL.deleteLastPathComponent()
        }

        return nil
    }

    static func adjacentVersionFileVersion(for executableURL: URL) -> String? {
        let versionURL = executableURL
            .deletingLastPathComponent()
            .appendingPathComponent("VERSION")
        guard let raw = try? String(contentsOf: versionURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("v"), trimmed.dropFirst().first?.isNumber == true {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    static func normalizedBundleVersion(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != "CodexBar"
        else { return nil }
        return trimmed
    }

    static func platformExit(_ code: Int32) -> Never {
        #if canImport(Darwin)
        Darwin.exit(code)
        #elseif canImport(Glibc)
        Glibc.exit(code)
        #elseif canImport(Musl)
        Musl.exit(code)
        #endif
    }
}
