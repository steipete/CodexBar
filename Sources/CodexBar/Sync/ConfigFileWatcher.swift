import CodexBarCore
import Foundation

final class ConfigFileWatcher: @unchecked Sendable {
    typealias ChangeHandler = @Sendable () -> Void

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.steipete.codexbar.config-file-watcher", qos: .utility)
    private let changeHandler: ChangeHandler
    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?
    private var observedHash: String?
    private var stopped = false

    init(fileURL: URL, changeHandler: @escaping ChangeHandler) {
        self.fileURL = fileURL
        self.changeHandler = changeHandler
        self.observedHash = (try? Data(contentsOf: fileURL)).map { CanonicalSyncJSON.hash(data: $0) }
    }

    func start() {
        self.queue.async { [weak self] in
            self?.arm()
        }
    }

    func stop() {
        self.lock.withLock {
            self.stopped = true
        }
        self.queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
        }
    }

    static func withAppWrite(_ data: Data, watcher: ConfigFileWatcher?, operation: () throws -> Void) rethrows {
        guard let watcher else { return try operation() }
        try watcher.lock.withLock {
            try operation()
            watcher.observedHash = CanonicalSyncJSON.hash(data: data)
        }
    }

    private func arm() {
        guard !self.lock.withLock({ self.stopped }) else { return }
        self.source?.cancel()
        self.source = nil

        let watchedURL = FileManager.default.fileExists(atPath: self.fileURL.path)
            ? self.fileURL
            : self.fileURL.deletingLastPathComponent()
        let descriptor = open(watchedURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            self.queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.arm() }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: self.queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            let flags = source?.data ?? []
            self.processChange()
            if flags.contains(.rename) || flags.contains(.delete) || watchedURL != self.fileURL {
                self.arm()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
        // Reconcile changes made before the new descriptor began observing.
        self.processChange()
    }

    private func processChange() {
        let changed = self.lock.withLock {
            guard !self.stopped, let data = try? Data(contentsOf: self.fileURL) else { return false }
            let hash = CanonicalSyncJSON.hash(data: data)
            defer { self.observedHash = hash }
            return self.observedHash != hash
        }
        if changed {
            self.changeHandler()
        }
    }
}
