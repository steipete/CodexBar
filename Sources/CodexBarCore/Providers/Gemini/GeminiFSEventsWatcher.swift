import Foundation

/// Watches `~/.gemini/` for file-system changes and fires a callback so the app can
/// trigger an immediate Gemini usage refresh instead of waiting for the next poll cycle.
///
/// Uses a `DispatchSourceFileSystemObject` on the directory fd, which requires no special
/// permissions and works on macOS 14+.
public final class GeminiFSEventsWatcher: @unchecked Sendable {
    public static let didChangeNotification = Notification.Name("GeminiDirectoryDidChange")

    private let directoryURL: URL
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "com.codexbarrt.gemini.fswatcher", qos: .utility)

    public init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            self.directoryURL = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini", isDirectory: true)
        }
    }

    deinit {
        self.stop()
    }

    /// Start watching. Safe to call multiple times — restarts if already running.
    public func start() {
        self.stop()

        // Create the directory if it doesn't exist so we can watch it.
        try? FileManager.default.createDirectory(
            at: self.directoryURL, withIntermediateDirectories: true)

        let path = self.directoryURL.path
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
