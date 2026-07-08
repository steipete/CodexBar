import CryptoKit
import Foundation
import Network
import OSLog

/// Discovers a *paired* CodexBar Mac on the local network and receives authenticated, encrypted
/// snapshot frames.
///
/// Security model:
/// - Only connects to Macs whose Bonjour TXT `id` matches a paired Mac (so a stranger's Mac on the
///   same Wi-Fi is ignored entirely).
/// - Opens the session by sending a random nonce; every snapshot frame is AES-GCM sealed with a key
///   derived from the shared pairing key, so only the paired Mac can produce readable frames and
///   nobody else on the network can decrypt them.
public final class LANSubscriber: @unchecked Sendable {
    public typealias EnvelopeHandler = @Sendable (SyncEnvelope) -> Void

    private let log = Logger(subsystem: "com.steipete.codexbar.ios", category: "LANSubscriber")
    private let queue = DispatchQueue(label: "com.steipete.codexbar.ios.lan")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var buffer = Data()
    private var expectedLength: Int?
    private var sessionKey: SymmetricKey?
    private var connectedMac: PairedMac?
    private var onEnvelope: EnvelopeHandler?
    private var onStateChange: (@Sendable (Bool) -> Void)?

    /// Snapshot of paired Macs, refreshed on start so filtering has current data.
    private var pairedMacs: [PairedMac] = []

    public init() {}

    public func start(
        pairedMacs: [PairedMac],
        onEnvelope: @escaping EnvelopeHandler,
        onConnectedChange: @escaping @Sendable (Bool) -> Void)
    {
        self.queue.async {
            self.onEnvelope = onEnvelope
            self.onStateChange = onConnectedChange
            self.pairedMacs = pairedMacs
            self.startBrowsing()
        }
    }

    /// The coordinator owns the paired list (Keychain is unavailable on unsigned builds), so it
    /// pushes updates here rather than the subscriber re-reading storage.
    public func setPairings(_ macs: [PairedMac]) {
        self.queue.async {
            self.pairedMacs = macs
            // Drop a connection to a Mac that is no longer paired.
            if let current = self.connectedMac, !self.pairedMacs.contains(where: { $0.deviceID == current.deviceID }) {
                self.teardownConnection()
            }
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
        guard !self.pairedMacs.isEmpty else {
            self.log.info("not browsing: no paired Macs")
            self.onStateChange?(false)
            return
        }
        self.log.info("browsing for \(self.pairedMacs.count) paired Mac(s)")
        self.browser?.cancel()
        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: LANSync.bonjourServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        browser.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                self?.log.error("browser failed: \(error.localizedDescription, privacy: .public)")
                self?.scheduleBrowserRestart()
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
        guard self.connection == nil else { return }
        self.log.info("browse results: \(results.count)")
        for result in results {
            self.log.info("  result endpoint=\(String(describing: result.endpoint), privacy: .public) id=\(self.deviceID(from: result) ?? "nil", privacy: .public)")
            guard let id = self.deviceID(from: result) else { continue }
            if let mac = self.pairedMacs.first(where: { $0.deviceID == id }) {
                self.log.info("found paired Mac \(mac.name, privacy: .public) → connecting")
                self.connect(to: result.endpoint, mac: mac)
                return
            }
            self.log.debug("ignoring unpaired Mac id=\(id, privacy: .public)")
        }
        self.onStateChange?(false)
    }

    /// The Mac advertises its device ID in the Bonjour instance name (`CodexBar-<id>`), which is
    /// always present in the endpoint — unlike the TXT record, which NWBrowser may not resolve. Falls
    /// back to the TXT `id` when available.
    private func deviceID(from result: NWBrowser.Result) -> String? {
        if case let .service(name, _, _, _) = result.endpoint {
            let prefix = "CodexBar-"
            if name.hasPrefix(prefix) { return String(name.dropFirst(prefix.count)) }
        }
        if case let .bonjour(txt) = result.metadata, let id = txt["id"] { return id }
        return nil
    }

    // MARK: - Connection

    private func connect(to endpoint: NWEndpoint, mac: PairedMac) {
        self.teardownConnection()
        self.connectedMac = mac
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStateChange?(true)
                self.sendHello(mac: mac)
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

    private func sendHello(mac: PairedMac) {
        guard let pairKey = mac.symmetricKey else { return }
        let nonce = SyncCrypto.randomNonce()
        self.sessionKey = SyncCrypto.sessionKey(pairKey: pairKey, nonce: nonce)
        guard let helloData = try? SyncFrame.encodeHello(SyncFrame.Hello(nonce: nonce)) else { return }
        self.connection?.send(content: LANSync.framed(helloData), completion: .contentProcessed { _ in })
    }

    private func handleDisconnect() {
        self.teardownConnection()
        self.onStateChange?(false)
        self.scheduleBrowserRestart()
    }

    private func teardownConnection() {
        self.connection?.cancel()
        self.connection = nil
        self.sessionKey = nil
        self.connectedMac = nil
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
            if error != nil { self.handleDisconnect(); return }
            if isComplete { self.handleDisconnect(); return }
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

    private func decodeAndDeliver(_ sealed: Data) {
        guard let sessionKey = self.sessionKey else { return }
        do {
            let clear = try SyncCrypto.open(sealed, key: sessionKey)
            let envelope = try SyncEnvelope.decoded(from: clear)
            self.onEnvelope?(envelope)
        } catch {
            self.log.error("failed to open/decode frame: \(error.localizedDescription, privacy: .public)")
        }
    }
}
