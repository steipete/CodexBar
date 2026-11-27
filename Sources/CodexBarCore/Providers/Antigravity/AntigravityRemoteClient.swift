import Foundation

enum AntigravityRemoteClient {
    static let clientMetadata = [
        "ideType": "ANTIGRAVITY",
        "platform": "PLATFORM_UNSPECIFIED",
        "pluginType": "GEMINI",
    ]

    /// Cloud Code requires the Hub client family for quota access; pin a shared compatibility identity.
    static let userAgent: String = {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "amd64"
        #endif
        #if os(Linux)
        let platform = "linux"
        #else
        let platform = "darwin"
        #endif
        return "antigravity/hub/2.9.1 \(platform)/\(architecture)"
    }()
}
