import AppKit
import CodexBarCore

/// Maps active application bundle identifiers to their corresponding UsageProvider.
/// Only providers with desktop apps can be detected; CLI-only and web-only providers return nil.
struct ActiveAppDetector {
    /// Maps bundle identifier prefixes to their corresponding provider.
    /// Order matters: more specific prefixes should come first.
    private static let bundleIdToProvider: [(prefix: String, provider: UsageProvider)] = [
        // Desktop AI apps
        ("com.openai.codex", .codex),
        ("com.anthropic.claude", .claude),
        ("com.cursor.sh", .cursor),
        ("com.opencodeos.opencode", .opencode),
        ("com.google.antigravity", .antigravity),
        ("com.augmentcode.augment", .augment),
        ("com.minimax.agent", .minimax),
        ("dev.warp.Warp-Stable", .warp),

        // VS Code (GitHub Copilot - must check before generic JetBrains)
        ("com.microsoft.VSCode", .copilot),

        // JetBrains IDEs with Copilot support
        ("com.jetbrains.", .copilot),

        // Local AI servers (ollama runs locally, so it may show as active window)
        ("com.ollama", .ollama),
    ]

    /// Detects the provider associated with the currently active frontmost application.
    /// - Returns: The provider for the active AI app, or nil if no relevant AI app is active.
    static func activeProvider() -> UsageProvider? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let bundleId = frontmostApp.bundleIdentifier
        else {
            return nil
        }

        return provider(for: bundleId)
    }

    /// Looks up the provider for a given bundle identifier.
    /// - Parameter bundleId: The application's bundle identifier.
    /// - Returns: The corresponding provider, or nil if no match found.
    static func provider(for bundleId: String) -> UsageProvider? {
        // Try exact match first for special cases
        for (prefix, provider) in Self.bundleIdToProvider {
            if bundleId == prefix {
                return provider
            }
        }

        // Then try prefix match (handles versioned bundle IDs like com.anthropic.claude-2)
        for (prefix, provider) in Self.bundleIdToProvider {
            if bundleId.hasPrefix(prefix) {
                return provider
            }
        }

        return nil
    }
}