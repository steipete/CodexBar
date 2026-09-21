import CodexBarCore
import Foundation

final class ConfigFileWatcher: @unchecked Sendable {
    typealias ChangeHandler = @Sendable () -> Void

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.steipete.codexbar.config-file-watcher", qos: .utility)
    private let changeHandler: ChangeHandler
    private let beforeRegistrationForTesting: ChangeHandler?
    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?
    private var observedHash: String?
    private var stopped = false

    init(
        fileURL: URL,
        beforeRegistrationForTesting: ChangeHandler? = nil,
        changeHandler: @escaping ChangeHandler)
    {
        self.fileURL = fileURL
        self.changeHandler = changeHandler
        self.beforeRegistrationForTesting = beforeRegistrationForTesting
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

        self.beforeRegistrationForTesting?()

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: self.queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source, self.source === source else { return }
            let flags = source.data
            self.processChange()
            if flags.contains(.rename) || flags.contains(.delete)
                || self.needsRearm(descriptor: descriptor, watchedURL: watchedURL)
            {
                self.arm()
            }
        }
        source.setRegistrationHandler { [weak self, weak source] in
            guard let self, let source, self.source === source else { return }
            // Reconcile only after registration, then check for replacements made by the callback.
            self.processChange()
            if self.needsRearm(descriptor: descriptor, watchedURL: watchedURL) {
                self.arm()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    private func needsRearm(descriptor: Int32, watchedURL: URL) -> Bool {
        let currentURL = FileManager.default.fileExists(atPath: self.fileURL.path)
            ? self.fileURL
            : self.fileURL.deletingLastPathComponent()
        guard currentURL == watchedURL else { return true }
        var opened = stat()
        var current = stat()
        guard fstat(descriptor, &opened) == 0, stat(currentURL.path, &current) == 0 else { return true }
        return opened.st_dev != current.st_dev || opened.st_ino != current.st_ino
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
