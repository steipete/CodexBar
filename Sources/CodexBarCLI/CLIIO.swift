import Foundation

extension CodexBarCLI {
    static func writeStderr(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    static func printVersion() -> Never {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            print("CodexBar \(version)")
        } else {
            print("CodexBar")
        }
        Self.platformExit(0)
    }

    static func printHelp(for command: String?) -> Never {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        switch command {
        case "usage":
            print(Self.usageHelp(version: version))
        case "cost":
            print(Self.costHelp(version: version))
        case "config", "validate", "dump":
            print(Self.configHelp(version: version))
        default:
            print(Self.rootHelp(version: version))
        }
        Self.platformExit(0)
    }

    static func platformExit(_ code: Int32) -> Never {
        #if canImport(Darwin)
        Darwin.exit(code)
        #else
        Glibc.exit(code)
        #endif
    }
}
