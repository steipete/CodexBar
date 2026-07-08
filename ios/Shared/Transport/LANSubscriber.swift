import Foundation
import Network
import OSLog

/// Discovers a CodexBar Mac on the local network over Bonjour and receives snapshot envelopes.
///
/// iOS suspends networking when the app leaves the foreground, so this is the *fast path* used
/// while the app is active on the same Wi-Fi. Background/widget refresh relies on CloudKit.
public final class LANSubscriber: @unchecked Sendable {
    public typealias EnvelopeHandler = @Sendable (SyncEnvelope) -> Void

    private let log = Logger(subsystem: "com.steipete.codexbar.ios", category: "LANSubscriber")
    private let queue = DispatchQueue(label: "com.steipete.codexbar.ios.lan")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var buffer = Data()
    private var expectedLength: Int?
    private var onEnvelope: EnvelopeHandler?
    private var onStateChange: (@Sendable (Bool) -> Void)?

    public init() {}

    /// Starts browsing. `onEnvelope` is called for every decoded snapshot; `onConnectedChange`
    /// reports whether a Mac connection is currently established.
    public func start(
        onEnvelope: @escaping EnvelopeHandler,
        onConnectedChange: @escaping @Sendable (Bool) -> Void)
    {
        self.queue.async {
            self.onEnvelope = onEnvelope
            self.onStateChange = onConnectedChange
            self.startBrowsing()
        }
    }

    public func stop() {
        self.queue.async {
            self.browser?.cancel()
            self.browser = nil
            self.teardownConnection()
        }
    }

    // MARK: - Browsing

    private func startBrowsing() {
        self.browser?.cancel()
        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: LANSync.bonjourServiceType,
            domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case let .failed(error):
                self?.log.error("browser failed: \(error.localizedDescription, privacy: .public)")
                self?.scheduleBrowserRestart()
            case .cancelled:
                break
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleResults(results)
        }
        self.browser = browser
        browser.start(queue: self.queue)
    }

    private func scheduleBrowserRestart() {
        self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.onEnvelope != nil else { return }
            self.startBrowsing()
        }
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        // Already connected — keep the existing connection.
        guard self.connection == nil else { return }
        guard let result = results.first else {
            self.onStateChange?(false)
            return
        }
        self.connect(to: result.endpoint)
    }

    // MARK: - Connection

    private func connect(to endpoint: NWEndpoint) {
        self.teardownConnection()
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log.info("LAN connection ready")
                self.onStateChange?(true)
                self.receiveNext()
            case let .failed(error):
                self.log.error("LAN connection failed: \(error.localizedDescription, privacy: .public)")
                self.handleDisconnect()
            case .cancelled:
                self.handleDisconnect()
            default:
                break
            }
        }
        self.connection = connection
        self.buffer.removeAll(keepingCapacity: true)
        self.expectedLength = nil
        connection.start(queue: self.queue)
    }

    private func handleDisconnect() {
        self.teardownConnection()
        self.onStateChange?(false)
        // Re-browse to pick up the Mac again once it returns.
        self.scheduleBrowserRestart()
    }

    private func teardownConnection() {
        self.connection?.cancel()
        self.connection = nil
        self.buffer.removeAll(keepingCapacity: true)
        self.expectedLength = nil
    }

    private func receiveNext() {
        self.connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainBuffer()
            }
            if let error {
                self.log.error("receive error: \(error.localizedDescription, privacy: .public)")
                self.handleDisconnect()
                return
            }
            if isComplete {
                self.handleDisconnect()
                return
            }
            self.receiveNext()
        }
    }

    private func drainBuffer() {
        while true {
            if self.expectedLength == nil {
                guard self.buffer.count >= LANSync.lengthPrefixByteCount else { return }
                let prefix = self.buffer.prefix(LANSync.lengthPrefixByteCount)
                let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
                self.buffer.removeFirst(LANSync.lengthPrefixByteCount)
                guard length > 0, length <= LANSync.maxMessageByteCount else {
                    self.log.error("invalid frame length \(length); dropping connection")
                    self.handleDisconnect()
                    return
                }
                self.expectedLength = length
            }
            guard let length = self.expectedLength, self.buffer.count >= length else { return }
            let payload = self.buffer.prefix(length)
            self.buffer.removeFirst(length)
            self.expectedLength = nil
            self.decodeAndDeliver(Data(payload))
        }
    }

    private func decodeAndDeliver(_ payload: Data) {
        do {
            let envelope = try SyncEnvelope.decoded(from: payload)
            self.onEnvelope?(envelope)
        } catch {
            self.log.error("failed to decode envelope: \(error.localizedDescription, privacy: .public)")
        }
    }
}
