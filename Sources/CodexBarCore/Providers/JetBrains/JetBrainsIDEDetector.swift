import Foundation

public struct JetBrainsIDEInfo: Sendable, Equatable, Hashable {
    public let name: String
    public let version: String
    public let basePath: String
    public let quotaFilePath: String

    public init(name: String, version: String, basePath: String, quotaFilePath: String) {
        self.name = name
        self.version = version
        self.basePath = basePath
        self.quotaFilePath = quotaFilePath
    }

    public var displayName: String {
        "\(self.name) \(self.version)"
    }
}

public enum JetBrainsIDEDetector {
    private static let idePatterns: [(prefix: String, displayName: String)] = [
        ("IntelliJIdea", "IntelliJ IDEA"),
        ("PyCharm", "PyCharm"),
        ("WebStorm", "WebStorm"),
        ("GoLand", "GoLand"),
        ("CLion", "CLion"),
        ("DataGrip", "DataGrip"),
        ("RubyMine", "RubyMine"),
        ("Rider", "Rider"),
        ("PhpStorm", "PhpStorm"),
        ("AppCode", "AppCode"),
        ("Fleet", "Fleet"),
        ("AndroidStudio", "Android Studio"),
        ("RustRover", "RustRover"),
        ("Aqua", "Aqua"),
        ("DataSpell", "DataSpell"),
    ]

    private static let quotaFileName = "AIAssistantQuotaManager2.xml"

    public static func detectInstalledIDEs() -> [JetBrainsIDEInfo] {
        let basePaths = Self.jetBrainsConfigBasePaths()
        var detectedIDEs: [JetBrainsIDEInfo] = []

        let fileManager = FileManager.default
        for basePath in basePaths {
            guard fileManager.fileExists(atPath: basePath) else { continue }
            guard let contents = try? fileManager.contentsOfDirectory(atPath: basePath) else { continue }

            for dirname in contents {
                guard let ideInfo = Self.parseIDEDirectory(dirname: dirname, basePath: basePath) else { continue }
                if fileManager.fileExists(atPath: ideInfo.quotaFilePath) {
                    detectedIDEs.append(ideInfo)
                }
            }
        }

        return detectedIDEs.sorted { lhs, rhs in
            if lhs.name == rhs.name {
                return Self.compareVersions(lhs.version, rhs.version) > 0
            }
            return lhs.name < rhs.name
        }
    }

    public static func detectLatestIDE() -> JetBrainsIDEInfo? {
        let ides = Self.detectInstalledIDEs()
        guard !ides.isEmpty else { return nil }

        let fileManager = FileManager.default
        var latestIDE: JetBrainsIDEInfo?
        var latestModificationDate: Date?

        for ide in ides {
            guard let attrs = try? fileManager.attributesOfItem(atPath: ide.quotaFilePath),
                  let modDate = attrs[.modificationDate] as? Date
            else { continue }

            if latestModificationDate == nil || modDate > latestModificationDate! {
                latestModificationDate = modDate
                latestIDE = ide
            }
        }

        return latestIDE ?? ides.first
    }

    private static func jetBrainsConfigBasePaths() -> [String] {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        #if os(macOS)
        return [
            "\(homeDir)/Library/Application Support/JetBrains",
            "\(homeDir)/Library/Application Support/Google/AndroidStudio",
        ]
        #else
        return [
            "\(homeDir)/.config/JetBrains",
            "\(homeDir)/.local/share/JetBrains",
        ]
        #endif
    }

    private static func parseIDEDirectory(dirname: String, basePath: String) -> JetBrainsIDEInfo? {
        for (prefix, displayName) in Self.idePatterns {
            if dirname.hasPrefix(prefix) {
                let versionPart = String(dirname.dropFirst(prefix.count))
                let version = versionPart.isEmpty ? "Unknown" : versionPart
                let idePath = "\(basePath)/\(dirname)"
                let quotaFilePath = Self.quotaFilePath(for: idePath)
                return JetBrainsIDEInfo(
                    name: displayName,
                    version: version,
                    basePath: idePath,
                    quotaFilePath: quotaFilePath)
            }
        }
        return nil
    }

    private static func quotaFilePath(for ideBasePath: String) -> String {
        #if os(macOS)
        return "\(ideBasePath)/options/\(Self.quotaFileName)"
        #else
        return "\(ideBasePath)/options/\(Self.quotaFileName)"
        #endif
    }

    public static func quotaFilePath(for ideBasePath: String, isMacOS: Bool) -> String {
        if isMacOS {
            return "\(ideBasePath)/options/\(Self.quotaFileName)"
        } else {
            return "\(ideBasePath)/options/\(Self.quotaFileName)"
        }
    }

    private static func compareVersions(_ v1: String, _ v2: String) -> Int {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }

        let maxLen = max(parts1.count, parts2.count)
        for i in 0 ..< maxLen {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 != p2 {
                return p1 - p2
            }
        }
        return 0
    }
}
