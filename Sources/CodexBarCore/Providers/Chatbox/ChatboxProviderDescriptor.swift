import Foundation

public enum ChatboxProviderDescriptor {
    static let diagnosticMessages = [
        "Chatbox AI license key is invalid. Update it in Settings.",
        "Chatbox AI denied access. Check your license.",
        "Chatbox AI is rate limiting requests. Try again later.",
        "Chatbox AI request failed. Try refreshing later.",
        "Chatbox AI returned an unrecognized response. Update CodexBar and try again.",
    ]

    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .chatbox,
        displayName: "Chatbox AI",
        sessionLabel: "Plan",
        weeklyLabel: "Top-up credits",
        dashboardURL: "https://chatboxai.app",
        color: .init(hex: 0x228BE6),
        confetti: [0x228BE6, 0xA9C2FF],
        noDataMessage: "No cost history data.",
        history: .unavailable,
        burnDownWidgetSelectable: false,
        environmentKey: "CHATBOX_LICENSE_KEY",
        menuBarMetrics: .init(supported: [.automatic, .primary, .secondary]),
        scriptSettings: { _ in
            let messages = Dictionary(uniqueKeysWithValues: Self.diagnosticMessages.map {
                ($0, UsageFormatter.localized($0))
            })
            let data = try? JSONEncoder().encode(messages)
            return ["MESSAGES": data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"]
        },
        apiKeyField: .init(
            id: "chatbox-license-key",
            title: "API key",
            subtitle: "Stored in the CodexBar config file."),
        showsAPIDetail: true,
        availability: .configuredKey)
}
