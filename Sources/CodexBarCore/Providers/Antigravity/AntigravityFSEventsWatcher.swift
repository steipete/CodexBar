import Foundation

/// Watches the Antigravity (Codeium) data directory for file-system changes and fires a
/// notification so the app can trigger an immediate usage refresh.
///
/// Typical location: `~/.codeium/` — where Antigravity stores session state and auth data.
public final class AntigravityFSEventsWatcher: @unchecked Sendable {
    public static let didChangeNotification = Notification.Name("AntigravityDirectoryDidChange")

    private let directoryURL: URL
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "com.codexbarrt.antigravity.fswatcher", qos: .utility)

    public init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            self.directoryURL = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(".codeium", isDirectory: true)
        }
    }

    deinit {
        self.stop()
    }

    /// Start watching. Safe to call multiple times — restarts if already running.
    public func start() {
        self.stop()

        let path = self.directoryURL.path
        guard FileManager.default.fileExists(atPath: path) else { return }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        self.fd = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .link],
            queue: self.queue)

        src.setEventHandler { [weak self] in
            self?.handleChange()
        }

        src.setCancelHandler { [fd] in
            close(fd)
        }

        self.source = src
        src.resume()
    }

    /// Stop watching and release the file descriptor.
    public func stop() {
        self.source?.cancel()
        self.source = nil
        self.fd = -1
    }

    private func handleChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
