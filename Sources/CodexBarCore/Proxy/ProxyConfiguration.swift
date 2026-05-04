import Foundation

public struct ProxyConfiguration: Sendable {
    public let port: UInt16
    public let bindAddress: String
    public let isEnabled: Bool

    public static let `default` = ProxyConfiguration(
        port: 9876,
        bindAddress: "127.0.0.1",
        isEnabled: false)

    public init(port: UInt16, bindAddress: String, isEnabled: Bool) {
        self.port = port
        self.bindAddress = bindAddress
        self.isEnabled = isEnabled
    }
}

public struct ProxyTokenEntry: Sendable {
    public let provider: UsageProvider
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int
    public let model: String?
    public let timestamp: Date

    public init(
        provider: UsageProvider,
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int,
        model: String? = nil,
        timestamp: Date = Date())
    {
        self.provider = provider
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.model = model
        self.timestamp = timestamp
    }
}
