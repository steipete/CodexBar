import Foundation

@MainActor
public final class ProxyManager: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var activePort: UInt16 = 0
    @Published public private(set) var requestCount: Int = 0

    public let accumulator = TokenAccumulator()
    private var server: LocalProxyServer?
    private static let log = CodexBarLog.logger("proxy-manager")

    public init() {}

    public func start(port: UInt16 = 9876) {
        guard !self.isRunning else { return }

        let config = ProxyConfiguration(port: port, bindAddress: "127.0.0.1", isEnabled: true)
        let server = LocalProxyServer(configuration: config, accumulator: self.accumulator)

        do {
            try server.start()
            self.server = server
            self.isRunning = true
            self.activePort = port
            Self.log.info("Proxy started on port \(port)")
        } catch {
            Self.log.error("Failed to start proxy: \(error)")
        }
    }

    public func stop() {
        self.server?.stop()
        self.server = nil
        self.isRunning = false
        self.activePort = 0
        Self.log.info("Proxy stopped")
    }

    public func toggle(port: UInt16 = 9876) {
        if self.isRunning {
            self.stop()
        } else {
            self.start(port: port)
        }
    }

    public func snapshot(for provider: UsageProvider) -> ProxyTokenEntry? {
        self.accumulator.snapshot(for: provider)
    }

    public func allSnapshots() -> [ProxyTokenEntry] {
        self.accumulator.allSnapshots()
    }
}
