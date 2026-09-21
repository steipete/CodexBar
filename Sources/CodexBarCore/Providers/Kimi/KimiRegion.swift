import Foundation

public enum KimiRegion: String, CaseIterable, Sendable {
    case china
    case international

    public var domain: String {
        self == .china ? "kimi.com" : "kimi.ai"
    }

    public var displayName: String {
        self == .china ? "China (kimi.com)" : "International (kimi.ai)"
    }

    public var apiBaseURL: URL {
        URL(string: "https://api.\(self.domain)")!
    }

    public var webBaseURL: URL {
        URL(string: "https://www.\(self.domain)")!
    }

    public var consoleURL: URL {
        self.webBaseURL.appendingPathComponent("code/console")
    }

    public var cookieDomains: [String] {
        ["www.\(self.domain)", self.domain]
    }
}
